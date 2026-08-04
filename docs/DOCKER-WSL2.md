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
   Testcontainers (ryuk) só age quando a conexão TCP com o runner cai, e mesmo
   então remove via daemon, com retries limitados
   ([oficial](https://github.com/testcontainers/moby-ryuk)) — contra um daemon
   mudo, ele desiste. O `Dispose` das fixtures não completa. E as fixtures que
   ainda esperavam banco não falharam rápido: o timeout default das wait
   strategies do Testcontainers .NET é **1 hora**
   ([oficial](https://dotnet.testcontainers.org/custom_configuration/)) — a
   suíte inteira ficou pendurada aguardando containers que nunca ficariam
   prontos. Os 15 efêmeros ficam vivos por 2h20.
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
# Devolve RAM ociosa da VM ao Windows. Com Docker, use dropCache (o default
# atual): o modo gradual tem conflitos documentados com o motor.
autoMemoryReclaim=dropCache
# sparseVhd devolveria espaço automaticamente, mas versões recentes do WSL o
# bloqueiam por risco de corrupção (a conversão exige --allow-unsafe): não
# use no disco do Docker — o caminho seguro é a compactação (cap. 7).
```

Defaults sem o arquivo, direto da documentação
([oficial](https://learn.microsoft.com/en-us/windows/wsl/wsl-config)): memória
até **50% da RAM**, **todos** os processadores lógicos, swap de 25% da RAM e
disco virtual de até 1 TB. As chaves valem só depois de a VM parar
(`wsl --shutdown`, ou ~8 s após fechar tudo), e a Microsoft hoje sugere editar
pela GUI "WSL Settings" para evitar erro de sintaxe e de seção.

**A pegadinha que custou um mês**: chaves da seção `[experimental]` colocadas
em `[wsl2]` são **ignoradas com um aviso** que só aparece ao rodar `wsl` no
terminal — coisa que ninguém faz no dia a dia. Na máquina do incidente, o
`autoMemoryReclaim` passou 30 dias declarado e inativo. **Teto declarado não é
teto vigente**: valide rodando `wsl --shutdown` e um comando `wsl` qualquer, e
confira se não há reclamação de "chave desconhecida".

**E a pegadinha dentro da correção**: o modo `gradual` do reclaim tem
conflitos documentados pela comunidade com Docker — quebrou o cgroup v1 do
Docker CE dentro do WSL
([comunidade](https://github.com/microsoft/WSL/issues/10497)) e, combinado com
o Resource Saver do Docker Desktop (ligado por padrão desde a 4.24), causa
travamento de comandos até o motor "acordar"
([comunidade](https://github.com/microsoft/WSL/issues/11066)). O consenso
atual, refletido no default oficial, é **`dropCache`** quando há Docker na
máquina. O Resource Saver, aliás, tem alcance limitado no WSL: como a VM é
compartilhada, ele só pausa o engine — não devolve memória; quem devolve é o
reclaim ([oficial](https://docs.docker.com/desktop/use-desktop/resource-saver/)).

### Onde o código deve morar

A fronteira entre o sistema de arquivos do Windows e o do Linux (9P/drvfs) é
cara: a recomendação **oficial** do Docker e da Microsoft é manter o código no
filesystem do Linux e montar de lá — evitando `/mnt/c`
([oficial](https://docs.docker.com/desktop/features/wsl/best-practices/),
[oficial](https://learn.microsoft.com/en-us/windows/wsl/filesystems)). Medições
da comunidade apontam I/O intenso (instalação de dependências, git, builds)
**10–20× mais lento** atravessando a fronteira, e eventos de arquivo (hot
reload) nem chegam ao container quando o código está do lado Windows. A nuance
honesta para quem desenvolve com toolchain Windows (IDE e SDK no host): o
código vai continuar no NTFS — aí o custo aparece no envio de contexto de
build e nos bind mounts, e as mitigações são `.dockerignore` agressivo, montar
apenas o necessário e preferir COPY/artefato a montar árvore de fonte inteira.

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

- **`cpus` e `mem_limit` em tudo que fica residente.** O default é **nenhum
  limite** ([oficial](https://docs.docker.com/engine/containers/resource_constraints/)),
  e sem limite um estouro vira OOM **no host** — o kernel mata processos da
  máquina para salvar RAM; com limite, o OOM kill fica confinado ao cgroup do
  container, que a restart policy ressuscita. `--cpus` só estrangula, nunca
  mata: seguro aplicar sempre. `pids_limit` contém fork bomb e vazamento de
  processos. No `docker stats`, "limite" igual à RAM da VM é a denúncia do
  container sem teto. (No Compose moderno a forma preferida é
  `deploy.resources.limits`; `mem_limit`/`cpus` de serviço funcionam e são a
  forma legada.)
- **`init: true` onde o processo principal não trata sinais.** Sem um init como
  PID 1, o kernel suprime a ação padrão de SIGTERM: `docker stop` espera o
  `stop_grace_period` (10 s por padrão — aumente para bancos e filas) e mata
  com SIGKILL. O init também **colhe zumbis** — e healthcheck cria processo
  novo a cada intervalo, então sem reaper os zumbis acumulam até esgotar PIDs
  ([oficial](https://docs.docker.com/reference/cli/docker/container/run/#init),
  [comunidade](https://github.com/moby/moby/issues/29238)).
- **Semântica das restart policies**, que vale decorar
  ([oficial](https://docs.docker.com/engine/containers/start-containers-automatically/)):
  com `unless-stopped`, container parado à mão **não volta** quando o daemon
  reinicia; com `always`, volta **mesmo parado à mão** após um reboot — a
  surpresa clássica. Em qualquer política, `docker start` (ou `compose start`)
  **reutiliza a configuração antiga**, sem os tetos novos: depois de mudar
  limites no compose, só `docker compose up -d` recria com eles. E a política
  só se arma depois de o container ficar de pé por ~10 s — crash imediato em
  loop não é protegido da mesma forma.
- **`name:` fixo no compose.** Sem ele, o nome do projeto vem do diretório —
  e execuções a partir de worktrees, clones paralelos ou diretórios de agentes
  criam **stacks e volumes duplicados** que ninguém derruba. Vimos volumes
  órfãos de cinco execuções diferentes do mesmo projeto. Se o fluxo usa
  worktrees de propósito, o teardown precisa do `docker compose down -v`.

### Logs: o vazamento de disco que vem de fábrica

O driver de log padrão é `json-file` e, **por default, nenhuma rotação é
feita** ([oficial](https://docs.docker.com/engine/logging/configure/)) — um
serviço tagarela enche o disco em silêncio, dentro do VHDX que já não devolve
espaço. A recomendação oficial é o driver **`local`** (rotaciona por padrão,
formato mais eficiente); se ficar no `json-file`, configure
`max-size`/`max-file` no `daemon.json` ou por serviço — lembrando que mudança
no daemon só vale para containers **novos**.

### Healthchecks custam

Cada checagem executa um processo novo dentro do container. Os defaults são
generosos demais (`timeout` de 30 s; `start_period` zero): prefira comando
barato e local (endpoint de saúde leve, nunca `curl` contra dependência
externa — incidente alheio vira `unhealthy` em cascata), `timeout` menor que
`interval`, e `start_period` folgado para apps de subida lenta
([oficial](https://docs.docker.com/reference/dockerfile/#healthcheck)). Em
máquina de desenvolvimento, dezenas de containers com healthcheck agressivo é
fork constante — aquece sem informar.

### Um compose, vários ambientes

O padrão oficial é `compose.yaml` (base) + `compose.override.yaml` (dev,
carregado automaticamente), e produção com arquivos explícitos
(`-f compose.yaml -f compose.prod.yaml`)
([oficial](https://docs.docker.com/compose/how-tos/multiple-compose-files/merge/)).
**Profiles** completam: serviços sem `profiles` são o núcleo que sempre sobe;
ferramentas opcionais ganham profile e só sobem sob demanda. Um arquivo com
variações controladas evita a deriva de composes paralelos por ambiente.

### Hardening leve que não custa performance

Consenso da comunidade (OWASP) para aplicar por padrão: `security_opt:
["no-new-privileges:true"]`, `cap_drop: [ALL]` com `cap_add` mínimo, usuário
não-root, e — onde o app permitir mapear os caminhos de escrita —
`read_only: true` com `tmpfs` para `/tmp`
([comunidade](https://cheatsheetseries.owasp.org/cheatsheets/Docker_Security_Cheat_Sheet.html)).
Nada disso pesa em runtime, e o conjunto transforma o container num ambiente
hostil para quem invadir.

## 5. Suítes de teste com Testcontainers

O padrão "um container real por fixture" é excelente para fidelidade e péssimo
para aritmética, porque o paralelismo default do xUnit é o número de núcleos:

- **Limite o paralelismo** com um `xunit.runner.json` no projeto de teste
  (`{"maxParallelThreads": 4}`) e **copie-o para o output** no `.csproj` — o
  xUnit só lê o arquivo ao lado do assembly. Quatro SQL Servers simultâneos
  cabem; doze não.
- **O contraponto oficial, dito com honestidade**: a recomendação do próprio
  Docker é **compartilhar um container por classe ou por suíte** (singleton),
  não um por fixture — "cada container custa RAM e CPU"
  ([oficial](https://www.docker.com/blog/testcontainers-best-practices/)); no
  xUnit v3 existe até `AssemblyFixture` para compartilhar na assembly inteira.
  Um-por-fixture compra **determinismo** (banco limpo, sem estado cruzado)
  pagando em recursos; o singleton compra recursos pagando em disciplina de
  isolamento. Os dois desenhos são legítimos — o que não é legítimo é
  um-por-fixture **com paralelismo default**, que foi a receita do incidente.
- **Cape o motor por dentro também**: SQL Server aceita
  `MSSQL_MEMORY_LIMIT_MB` como env — buffer pool contido sem cgroup.
- **Rotule o dono**: uma label com o PID do runner
  (ex.: `owner-pid = PID do testhost`) permite que a higiene automática da
  máquina prove "dono morto" e remova o efêmero órfão com segurança. Sem a
  label, um limpador conservador — corretamente — não toca em nada.
- **Entenda o reaper**: o ryuk é um container auxiliar que segura uma conexão
  TCP com o runner; enquanto ela vive, nada é removido. Quando a última
  conexão cai (fim normal **ou** morte do runner), ele espera ~10 s e remove
  tudo que casa com as labels da sessão — *se o daemon estiver respondendo*
  (contra daemon mudo, tenta 10 vezes e desiste)
  ([oficial](https://github.com/testcontainers/moby-ryuk)). A leitura certa
  dos efêmeros é sempre em par: **efêmeros + ryuk vivo = suíte em andamento;
  efêmeros + ryuk ausente = vazamento confirmado**; efêmero velho com ryuk
  vivo = suíte longa ou runner pendurado.
- **Não desligue o ryuk.** `TESTCONTAINERS_RYUK_DISABLED` existe para
  ambientes com limpeza própria (nós de CI efêmeros) — a doc pede para não
  usar fora disso ([oficial](https://dotnet.testcontainers.org/api/resource_reaper/)).
  Os motivos históricos para desligar no Windows (conexões instáveis, engines
  sem suporte) não valem mais no Docker Desktop + WSL2 atual.
- **Reuse é experimental e desliga o reaper.** `WithReuse(true)` acelera runs
  locais reaproveitando o container, mas o recurso reusado **fica fora da
  limpeza automática** e o estado sujo entre runs vira responsabilidade sua —
  a doc Java é explícita: não é para CI
  ([oficial](https://java.testcontainers.org/features/reuse/)). É mais um
  caminho legítimo de criar "órfão de propósito": se adotar, adote junto a
  higiene manual.
- **Acelere pelo caminho sancionado**: imagem **pinada por versão** (nunca
  `latest`, idealmente a mesma da produção), **wait strategies em vez de
  sleeps** — e reduza o timeout delas: o default do .NET é **1 hora**, que
  transforma daemon doente em suíte pendurada
  ([oficial](https://dotnet.testcontainers.org/custom_configuration/)) —,
  `tmpfs` para o diretório de dados do banco de teste (elimina fsync em
  disco), e migrações aplicadas uma vez por container compartilhado em vez de
  uma vez por teste.
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
- **O caminho moderno que a Microsoft prefere**: em vez de exclusões, **Dev
  Drive** (ReFS) com o *performance mode* do Defender — varredura assíncrona,
  que a própria doc descreve como proteção melhor do que exclusão de pasta,
  que bloqueia a varredura por completo
  ([oficial](https://learn.microsoft.com/en-us/windows/dev-drive/),
  [oficial](https://learn.microsoft.com/en-us/defender-endpoint/microsoft-defender-endpoint-antivirus-performance-mode)).
  Exclusões clássicas ficam como último recurso, para problema específico e
  medido — nunca padrões amplos. Mover os VHDX para Dev Drive é prática
  difundida na comunidade, mas não é recomendação formal para o cenário
  Docker Desktop.

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
5. **Para o futuro, com uma ressalva importante**: `sparseVhd=true` faria VHDs
   novos devolverem espaço automaticamente, mas versões recentes do WSL
   **bloqueiam o sparse por risco de corrupção** — a conversão exige
   `--allow-unsafe`, inaceitável no disco de dados do Docker. Quem ajuda de
   verdade é o Docker Desktop moderno: desde a 4.30 as instalações novas usam
   uma única distro, e desde a 4.34 o Desktop **compacta o disco virtual ao
   sair** quando estima 16 GB ou mais recuperáveis
   ([oficial](https://www.docker.com/blog/docker-desktop-4-34/)). A compactação
   manual segue valendo para instalações antigas e para quando o automático não
   dispara.

Sobre a rotina de limpeza contínua, o consenso validado: `docker system prune`
periódico **sem `-a` e sem `--volumes`** (volumes nunca entram em remoção
automática — a doc é explícita: "poderia destruir dados" — e é assim que deve
permanecer), com `--filter until=` para preservar o recente
([oficial](https://docs.docker.com/engine/manage-resources/pruning/)).
`image prune -a` é o passo agressivo e consciente, nunca o agendado.

## 8. Builds e imagens que não pesam

- **Multi-stage sempre**: o estágio final recebe apenas artefatos — menos
  tamanho, menos superfície
  ([oficial](https://docs.docker.com/build/building/best-practices/)).
- **A ordem das camadas É o cache**: uma camada alterada invalida **todas** as
  seguintes ([oficial](https://docs.docker.com/build/cache/)). Dependências e
  passos caros primeiro (copie os manifestos antes do código), o `COPY` do
  código por último.
- **Cache mounts do BuildKit** (`RUN --mount=type=cache,target=...`): o cache
  do gerenciador de pacotes sobrevive mesmo quando a camada invalida — só
  baixa o que mudou ([oficial](https://docs.docker.com/build/cache/optimize/)).
- **`.dockerignore` agressivo**: menos contexto enviado (dobra de importância
  com código no NTFS) e menos invalidação espúria.
- **O GC do cache de build é configurável — e é o meio-termo certo**: em vez
  de cache infinito (o incidente acumulou 6 GB parados) ou `builder prune -a`
  (que força rebuild total), dimensione
  `"builder": { "gc": { "defaultKeepStorage": "20GB" } }` no `daemon.json` ao
  seu disco ([oficial](https://docs.docker.com/build/cache/garbage-collection/)).
  Alívio manual pontual: `--filter until=168h` ou `--keep-storage`, preservando
  o cache dos projetos ativos.
- **Base image com os pés no chão** (ponto contestado, dito como é): a doc
  oficial sugere Alpine pelo tamanho; o consenso comunitário recente para
  runtimes glibc (Node/Python/.NET com binários nativos) é **Debian slim** —
  musl quebra módulos nativos e se comporta diferente sob carga. Distroless
  minimiza a superfície ao custo de debug sem shell. Escolha por compatível
  primeiro, pequeno depois.
- **Inspecione antes de otimizar no escuro**: `docker history` e a ferramenta
  `dive` ([comunidade](https://github.com/wagoodman/dive)) mostram onde os
  megabytes moram de verdade.

## 9. Diagnóstico que não mente

Regras que valem para qualquer ferramenta que observe o Docker:

- **Estados explícitos**: desligado / ocioso / ativo / **lento** / **afogado**.
  A sonda roda por etapas, do barato ao caro (`ps` → efêmeros → volumes →
  `stats`), e aproveita o parcial no estouro: **`ps` respondido com `stats`
  estourado = lento** (daemon suando — criação de containers, build, I/O);
  **nem o `ps` = afogado**. Os dois têm cara de alarme — nunca de lista vazia —
  mas pedem remédios diferentes: lento pede paciência e menos carga; afogado
  pede socorro.
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

## 10. Runbook: "a máquina travou e acho que é o Docker"

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

## 11. Checklist da máquina bem defendida

| Camada | Defesa | Sem ela |
|---|---|---|
| Host | `processors=` menor que o total | surto na VM trava o Windows inteiro |
| Host | `memory=` + `swap=` limitados | balão até metade da RAM + thrash de I/O |
| Host | `autoMemoryReclaim` **na seção certa** | RAM nunca volta; chave errada é ignorada em silêncio |
| Host | compactação do VHDX (auto do Desktop 4.34+ ou manual) | VHDX só cresce; sparse é bloqueado por risco no WSL atual |
| Stack | `cpus`/`mem_limit`/`pids_limit` em tudo residente | um container herda a VM inteira |
| Stack | `init: true` | `docker stop` vira SIGKILL |
| Stack | `name:` fixo no compose | worktrees criam stacks e volumes fantasmas |
| Suíte | `maxParallelThreads` limitado | paralelismo = nº de núcleos = aritmética impossível |
| Suíte | label de owner-PID nos efêmeros | higiene automática não pode provar abandono |
| Suíte | guard "stack de pé? docker mudo? não roda" | suíte + stack + daemon afogado = incidente |
| Antivírus | exclusão dos VHDX (decisão da segurança) ou Dev Drive + performance mode | I/O da VM pago em dobro |
| Diagnóstico | estados com afogado explícito + prazos + delta | silêncio lido como saúde |
| Host | reclaim em `dropCache` (não `gradual` com Docker) | conflitos documentados com o motor |
| Stack | logs com rotação (`local` ou `max-size`) | `json-file` cresce sem limite |
| Suíte | timeout das wait strategies reduzido (default .NET: 1 h) | daemon doente vira suíte pendurada |
| Builds | GC do cache dimensionado (`defaultKeepStorage`) | cache infinito ou rebuild total |
| Dev | código no FS certo + `.dockerignore` | fronteira 9P cobra 10–20× |

## 12. Referências

Curadoria de agosto/2026; links podem mudar de endereço, mas os títulos
permitem reencontrar.

**Oficiais — Docker**

- Dockerfile e imagens: <https://docs.docker.com/build/building/best-practices/>
- Cache de build: <https://docs.docker.com/build/cache/> e
  <https://docs.docker.com/build/cache/optimize/>
- Garbage collection do cache: <https://docs.docker.com/build/cache/garbage-collection/>
- Limites de recursos: <https://docs.docker.com/engine/containers/resource_constraints/>
- Logging: <https://docs.docker.com/engine/logging/configure/> e driver
  `local`: <https://docs.docker.com/engine/logging/drivers/local/>
- Restart policies: <https://docs.docker.com/engine/containers/start-containers-automatically/>
- Prune: <https://docs.docker.com/engine/manage-resources/pruning/>
- WSL2 best practices: <https://docs.docker.com/desktop/features/wsl/best-practices/>
- Resource Saver: <https://docs.docker.com/desktop/use-desktop/resource-saver/>
- Compose (merge e profiles):
  <https://docs.docker.com/compose/how-tos/multiple-compose-files/merge/> e
  <https://docs.docker.com/compose/how-tos/profiles/>
- Testcontainers best practices: <https://www.docker.com/blog/testcontainers-best-practices/>

**Oficiais — Microsoft**

- `.wslconfig`: <https://learn.microsoft.com/en-us/windows/wsl/wsl-config>
- Sistemas de arquivos no WSL: <https://learn.microsoft.com/en-us/windows/wsl/filesystems>
- Dev Drive: <https://learn.microsoft.com/en-us/windows/dev-drive/>
- Performance mode do Defender:
  <https://learn.microsoft.com/en-us/defender-endpoint/microsoft-defender-endpoint-antivirus-performance-mode>

**Oficiais — Testcontainers**

- Resource reaper (.NET): <https://dotnet.testcontainers.org/api/resource_reaper/>
- Mecânica do ryuk: <https://github.com/testcontainers/moby-ryuk>
- Reuse: <https://dotnet.testcontainers.org/api/resource_reuse/> e
  <https://java.testcontainers.org/features/reuse/>
- Configuração e timeouts (.NET): <https://dotnet.testcontainers.org/custom_configuration/>

**Comunidade (selecionadas por tração e validação)**

- `gradual` × Docker: <https://github.com/microsoft/WSL/issues/10497> e
  <https://github.com/microsoft/WSL/issues/11066>
- vmmem e memória (histórico): <https://github.com/microsoft/WSL/issues/4166>
- Zumbis por exec de healthcheck: <https://github.com/moby/moby/issues/29238>
- OWASP Docker Security Cheat Sheet:
  <https://cheatsheetseries.owasp.org/cheatsheets/Docker_Security_Cheat_Sheet.html>
- Análise de camadas de imagem: <https://github.com/wagoodman/dive>

---

*Origem: incidente de 03/08/2026, investigado e corrigido com as ferramentas
deste repositório. Os dados de exemplo são medições reais com identidades
genéricas; nenhum caminho pessoal ou nome de projeto interno aparece aqui.*
