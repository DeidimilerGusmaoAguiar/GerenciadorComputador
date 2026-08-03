# Docker e WSL2 sob pressão — anatomia, defesas e diagnóstico

Este guia destila o conhecimento de um incidente real: uma máquina de
desenvolvimento Windows (32 GB de RAM, 12 processadores lógicos) travada por
completo — cursor engasgando, janelas congelando — com o Gerenciador de Tarefas
apontando um único suspeito chamado `VmmemWSL`. A investigação, a correção e as
defesas viraram este texto e as ferramentas deste repositório. Os nomes de
projetos e caminhos pessoais foram trocados por equivalentes genéricos; os
números são as medições reais.

A tese do guia inteiro cabe numa frase: **no Docker sobre WSL2, o perigo nunca é
"o Docker" — é carga sem teto dentro de uma VM com teto, medida por ferramentas
que confundem silêncio com saúde.**

## 1. Onde o custo mora (arquitetura em 60 segundos)

- O Docker Desktop no Windows roda o motor dentro de **uma única VM utilitária
  do WSL2**. O processo `VmmemWSL` (ou `Vmmem`) que aparece no Gerenciador de
  Tarefas **é a VM inteira**: a soma de todos os containers, do kernel Linux e
  do page cache — o Gerenciador não enxerga dentro dela.
- O disco dos containers vive num arquivo **VHDX** no perfil do usuário
  (`%LOCALAPPDATA%\Docker\wsl\disk\docker_data.vhdx`). Ele cresce conforme o
  uso e, por padrão, **nunca devolve espaço sozinho** — apagar imagens libera
  espaço *dentro* do arquivo, não no `C:`.
- A RAM "do Docker" se esconde em três lugares: o que os containers alocam, o
  page cache do Linux (cresce com I/O e parece uso legítimo), e o **commit** no
  Windows — que pode ficar em 10 GB enquanto o "working set" exibido mostra 3.
- Sem configuração, a VM enxerga **todos os processadores lógicos** do host e
  até metade da RAM. Um surto dentro dela é um surto na máquina inteira.

## 2. Anatomia de um travamento (estudo de caso)

Linha do tempo do incidente, generalizada:

1. **13:03** — uma suíte de testes de integração começa. O projeto usa
   Testcontainers: cada fixture sobe **seu próprio SQL Server** efêmero. São
   ~24 fixtures, e o runner paraleliza pelo default do xUnit: **o número de
   núcleos do host** (12).
2. **13:08–13:18** — seis containers nascem no mesmo segundo; outros nove nos
   minutos seguintes. Além deles, a stack de desenvolvimento (bancos, cache,
   storage) já ocupava a VM — containers com `restart: unless-stopped` ficam de
   pé 24/7 sem ninguém lembrar.
3. **A aritmética não fecha**: 15 SQL Servers × (engine ~0,5 GB + buffer pool
   de até 1,5 GB) somados à stack residente, dentro de uma VM com teto de
   10 GB. A VM enche, começa a usar o swap — que é **outro arquivo VHDX no
   mesmo disco C:** — e o I/O explode (100–150 MB/s sustentados).
4. **O antivírus amplifica**: proteção em tempo real varrendo o tráfego do
   VHDX consome mais de um núcleo. O disco satura de vez.
5. **O daemon afoga**: `docker ps` para de responder. E aqui está a parte
   cruel — **o mecanismo de limpeza também depende do daemon**. O reaper do
   Testcontainers (ryuk) não consegue remover nada; o `Dispose` das fixtures
   não completa. Os 15 efêmeros ficam vivos por 2h20.
6. **O golpe de misericórdia é humano**: ver `VmmemWSL` alto no Gerenciador e
   aplicar o **modo de eficiência** nele. O EcoQoS estrangula a CPU da VM
   inteira — o daemon, já afogado, morre de vez para o mundo. E a "queda" de
   9 GB para 3 GB que o Gerenciador mostra é só o trim do working set: o
   commit continua lá, e o aparo ainda gera mais I/O.

Duas lições-mestras saem daí:

- **Leitura ausente não é recurso zerado.** Um `docker ps` que não responde
  não significa "nenhum container"; significa que a fonte morreu — e isso é o
  alarme máximo, não o silêncio da paz.
- **A limpeza automática morre junto com o daemon.** Todo desenho de higiene
  precisa de um caminho que funcione *de fora* da VM.

## 3. Defesas no host: o `.wslconfig`

Arquivo `%USERPROFILE%\.wslconfig`, aplicado apenas após `wsl --shutdown`:

```ini
[wsl2]
# Teto de RAM da VM. Sem ele, até ~50% da RAM física.
memory=10GB

# A defesa mais importante contra travamento TOTAL: a VM deixa de enxergar
# todos os processadores. Com 8 de 12, o Windows nunca fica sem 4 threads.
processors=8

# Swap da VM é um VHDX no C:. Limite baixo evita tempestade de I/O.
swap=4GB

[experimental]
# Devolve RAM ociosa da VM ao Windows gradualmente.
autoMemoryReclaim=gradual
# VHDs novos nascem esparsos: espaço liberado dentro volta ao host.
sparseVhd=true
```

**A pegadinha que custou um mês**: chaves da seção `[experimental]` colocadas
em `[wsl2]` são **ignoradas com um aviso** que só aparece ao rodar `wsl` no
terminal — coisa que ninguém faz no dia a dia. Nesta máquina, o
`autoMemoryReclaim` passou 30 dias declarado e inativo. **Teto declarado não é
teto vigente**: valide rodando `wsl --shutdown` e um comando `wsl` qualquer, e
confira se não há reclamação de "chave desconhecida".

Saiba também: o Docker Desktop **religa a VM sozinho** segundos após um
`wsl --shutdown`. Derrubar a VM sem parar o Docker é enxugar gelo — útil para
aplicar o `.wslconfig`, inútil como "solução".

## 4. Defesas por container: o compose

```yaml
services:
  banco:
    image: exemplo/banco:1.0
    restart: unless-stopped
    init: true          # PID 1 de verdade: SIGTERM chega ao processo
    cpus: "1.5"
    mem_limit: 1536m
    pids_limit: 400
```

- **`cpus` e `mem_limit` em tudo que fica residente.** Container sem teto herda
  o teto da VM inteira — e no `docker stats`, o "limite" exibido igual à RAM da
  VM é exatamente essa denúncia.
- **`init: true` onde o processo principal não trata sinais.** Sem um init como
  PID 1, o kernel suprime a ação padrão de SIGTERM: `docker stop` espera o
  grace period (10 s por padrão) e mata com SIGKILL. Bancos merecem morte
  digna.
- **Semântica do `unless-stopped`**, que vale decorar: container parado à mão
  **não volta** quando o daemon reinicia — mas `docker start` (ou `compose
  start`) **reutiliza a configuração antiga**, sem os tetos novos. Depois de
  mudar limites no compose, só `docker compose up -d` recria com eles.
- **`name:` fixo no compose.** Sem ele, o nome do projeto vem do diretório —
  e execuções a partir de worktrees, clones paralelos ou diretórios de agentes
  criam **stacks e volumes duplicados** que ninguém derruba. Vimos volumes
  órfãos de cinco execuções diferentes do mesmo projeto. Se o fluxo usa
  worktrees de propósito, o teardown precisa do `docker compose down -v`.

## 5. Suítes de teste com Testcontainers

O padrão "um container real por fixture" é excelente para fidelidade e péssimo
para aritmética, porque o paralelismo default do xUnit é o número de núcleos:

- **Limite o paralelismo** com um `xunit.runner.json` no projeto de teste
  (`{"maxParallelThreads": 4}`) e **copie-o para o output** no `.csproj` — o
  xUnit só lê o arquivo ao lado do assembly. Quatro SQL Servers simultâneos
  cabem; doze não.
- **Cape o motor por dentro também**: SQL Server aceita
  `MSSQL_MEMORY_LIMIT_MB` como env — buffer pool contido sem cgroup.
- **Rotule o dono**: uma label com o PID do runner
  (ex.: `owner-pid = PID do testhost`) permite que a higiene automática da
  máquina prove "dono morto" e remova o efêmero órfão com segurança. Sem a
  label, um limpador conservador — corretamente — não toca em nada.
- **Entenda o reaper**: o ryuk vive enquanto a sessão de teste vive, e limpa
  quando ela termina — *se o daemon estiver respondendo*. A leitura certa dos
  efêmeros é sempre em par: **efêmeros + ryuk vivo = suíte em andamento;
  efêmeros + ryuk ausente = vazamento confirmado**; efêmero velho com ryuk
  vivo = suíte longa ou runner pendurado.
- **Não rode a suíte plena com a stack de desenvolvimento de pé.** Um guard
  falha-rápido antes do `dotnet test` (no script de teste do projeto e/ou num
  target MSBuild `BeforeTargets="VSTest"`) transforma a regra em mecânica. E
  guard bom **bloqueia também quando o docker não responde** — empilhar testes
  num daemon afogado foi o mecanismo do desastre.

## 6. Antivírus e Docker

- O VHDX é um sistema de arquivos ext4 opaco: a varredura em tempo real do
  arquivo-contêiner paga I/O e CPU **sem inspecionar conteúdo útil**. Em
  máquina gerenciada, a exclusão dos VHDX do Docker/WSL é um pedido à área de
  segurança — leve números medidos, não opinião.
- Exclusão de **caminho** cobre os arquivos daquele diretório; exclusão de
  **processo** cobre o que aquele processo abre. São alcances diferentes e não
  se substituem.
- Meça antes de pedir: o custo por processo/diretório sai da contabilidade do
  próprio motor antimalware (nesta máquina, o painel e a skill
  `custo-varredura` fazem essa leitura).

## 7. O VHDX que só cresce

Espaço "liberado" dentro do Docker não volta ao `C:` sozinho. A sequência
correta de recuperação, na ordem:

1. **Limpar dentro** (com critérios e aprovação): containers mortos
   identificados por label/origem, `docker builder prune`, volumes órfãos
   (`dangling`). Cuidado com o que "parece órfão": a imagem pinada da suíte de
   testes e o ryuk voltam a ser usados — removê-los é re-download, não ganho.
2. **`fstrim` dentro da VM** (`wsl -d docker-desktop -e fstrim -av`): zera os
   blocos livres para a compactação enxergá-los.
3. **Parar o Docker de verdade** (Quit/`docker desktop stop` — fechar a janela
   não encerra nada) e `wsl --shutdown`.
4. **Compactar**: `diskpart` → `select vdisk` → `attach vdisk readonly` →
   `compact vdisk` → `detach vdisk` (requer elevação). No incidente: 48 GB →
   23,6 GB, 24 GB devolvidos ao `C:`.
5. **Para o futuro**: `sparseVhd=true` faz VHDs novos devolverem espaço
   automaticamente.

## 8. Diagnóstico que não mente

Regras que valem para qualquer ferramenta que observe o Docker:

- **Estados explícitos**: desligado / ocioso / ativo / **afogado**. O afogado
  existe como estado de primeira classe, com cara de alarme — nunca como lista
  vazia.
- **Toda chamada de CLI com prazo**, executada de forma abortável (processo
  filho que pode ser morto). Um `docker.exe` pendurado num daemon afogado não
  responde a cancelamento educado — e é justamente nesse momento que o painel
  de diagnóstico precisa continuar vivo.
- **Backoff quando afoga**: pagar o prazo inteiro a cada ciclo de coleta é
  transformar o diagnóstico em carga.
- **CPU por delta, nunca por leitura instantânea**: duas amostras espaçadas do
  contador bruto. A primeira leitura "não tem valor ainda" — e mostrar isso é
  mais honesto que mostrar zero.
- **Com o Docker desligado, custo zero**: detectar processos antes de chamar
  qualquer CLI.

Nesta máquina, essas regras estão implementadas no painel Pulso (área
Diagnóstico, card "O que o Docker está custando", com sinal nos Insights e
campos `dk*` no histórico) e nos scripts `report-docker-pressure.ps1` e
`report-testcontainers-leak.ps1` — todos somente leitura.

## 9. Runbook: "a máquina travou e acho que é o Docker"

1. **Meça antes de matar** (`report-docker-pressure.ps1` ou o painel). Se o
   motor responde, o próprio relatório aponta quem come o quê.
2. **Se está afogado**: não empilhe nada novo (nem "só um docker ps"). O
   caminho de socorro é `wsl --shutdown` — ciente de que o Docker Desktop
   religa a VM e os containers de `restart` voltam; o alívio real vem de parar
   a carga (graciosamente) quando o motor responder de novo.
3. **Nunca** aplique modo de eficiência no `Vmmem`: estrangula o daemon e piora
   exatamente o que parece aliviar.
4. **Pare por categoria, com aprovação**: `docker stop -t 30` nos containers da
   carga (bancos desligam limpos), não `kill` na VM com trabalho em andamento —
   exceto quando a VM já está inacessível, que foi o caso do incidente.
5. **Depois do alívio, feche o ciclo**: quem subiu aquilo? Volta sozinho no
   próximo boot? O vazamento tem dono morto? As respostas viram defesa
   permanente (tetos, guard, label, `name:` fixo) — senão o episódio se repete
   com outro nome.

## 10. Checklist da máquina bem defendida

| Camada | Defesa | Sem ela |
|---|---|---|
| Host | `processors=` menor que o total | surto na VM trava o Windows inteiro |
| Host | `memory=` + `swap=` limitados | balão até metade da RAM + thrash de I/O |
| Host | `autoMemoryReclaim` **na seção certa** | RAM nunca volta; chave errada é ignorada em silêncio |
| Host | `sparseVhd=true` | VHDX só cresce |
| Stack | `cpus`/`mem_limit`/`pids_limit` em tudo residente | um container herda a VM inteira |
| Stack | `init: true` | `docker stop` vira SIGKILL |
| Stack | `name:` fixo no compose | worktrees criam stacks e volumes fantasmas |
| Suíte | `maxParallelThreads` limitado | paralelismo = nº de núcleos = aritmética impossível |
| Suíte | label de owner-PID nos efêmeros | higiene automática não pode provar abandono |
| Suíte | guard "stack de pé? docker mudo? não roda" | suíte + stack + daemon afogado = incidente |
| Antivírus | exclusão dos VHDX (decisão da segurança) | I/O da VM pago em dobro |
| Diagnóstico | estados com afogado explícito + prazos + delta | silêncio lido como saúde |

---

*Origem: incidente de 03/08/2026, investigado e corrigido com as ferramentas
deste repositório. Os dados de exemplo são medições reais com identidades
genéricas; nenhum caminho pessoal ou nome de projeto interno aparece aqui.*
