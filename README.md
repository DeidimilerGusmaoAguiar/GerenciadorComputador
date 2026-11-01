# Gerenciador de Computador

Toolkit PowerShell para diagnosticar espaço em disco e pressão de recursos no
Windows com uma regra central: **inspecionar primeiro, alterar somente com
escopo e aprovação explícitos**.

O projeto combina scripts reutilizáveis com instruções portáveis para Codex
CLI, Claude Code, Gemini CLI e Grok Build. Os scripts podem ser usados sem uma
CLI de IA.

## O que dá para fazer

| Para | Use | Detalhes |
|---|---|---|
| Descobrir para onde foi o espaço em disco | mapas de disco e inventários | [Início rápido](#início-rápido) |
| Limpar `bin`/`obj`, pastas temporárias antigas e resíduo de teste no `%TEMP%` | manifesto, revisão e remoção revalidada | [Artefatos de build](#artefatos-de-build), [Varredura diária](#varredura-diária-do-temp) |
| Entender por que a máquina está lenta | painel Pulso, coleta de memória e de desempenho | [Painel](#painel-de-pressão-em-runtime), [Memória](#memória) |
| Medir o custo do Docker/WSL2 e do antivírus | relatórios de pressão do Docker e de cobertura das exclusões | [docs/DOCKER-WSL2.md](docs/DOCKER-WSL2.md) |
| Auditar inicialização, serviços e bloatware | agentes do Claude Code com aprovação por item | [Com o Claude Code](#primeiros-passos-com-o-claude-code) |
| Trocar de computador sem perder o que não está no Git | inventário de migração e conferência de runbook | [Troca de máquina](#troca-de-máquina) |
| Manter várias contas da mesma CLI de IA | perfis gerados, histórico comum, cor da aba por plano | [Várias contas](#várias-contas-da-mesma-cli-de-ia) |
| Ver plano, cota e saúde da máquina em toda sessão do Claude Code | barra de status e faixa de saúde | [docs/CLAUDE-CODE-MODS.md](docs/CLAUDE-CODE-MODS.md) |
| Pedir confirmação antes de comando perigoso, mesmo com permissões puladas | regras do `settings.json` e mod de guarda | [docs/CLAUDE-CODE-MODS.md](docs/CLAUDE-CODE-MODS.md#guarda-de-comandos-guarda-comandos) |
| Rodar build ou teste pesado um por vez, com teto de CPU e memória | runner com Job Object | [docs/TRABALHO-PESADO.md](docs/TRABALHO-PESADO.md) |
| Regravar a senha de domínio dos pools do IIS | regravação sem a senha passar por log ou arquivo | [IIS](#iis-senha-de-domínio-dos-app-pools) |

Nada disso altera o computador sem você pedir: cada script que muda algo roda
em simulação até receber `-Execute`.

## Primeiros passos com o Claude Code

```powershell
git clone <endereço deste repositório>
cd GerenciadorComputador
claude
```

Na primeira sessão, `/context` deve listar o `CLAUDE.md`, que importa as regras
de [AGENTS.md](AGENTS.md). A partir daí, peça em linguagem natural:

- "o disco está quase cheio, descubra para onde foi o espaço";
- "a máquina está lenta, o que está pesando agora?";
- "o que inicia com o Windows e pode sair?";
- "abra o painel de pressão".

O agente sempre inspeciona primeiro, apresenta o plano com risco e bytes
estimados e só altera depois do seu "pode" para aquela categoria. Num computador
que não está no mapa local (`local\maquinas.json`, que não vem no clone), ele
trabalha somente em leitura e pergunta antes da primeira alteração.

O repositório traz seis agentes, que o Claude Code chama sozinho ou quando você
os cita pelo nome:

| Agente | Faz | Altera o sistema? |
|---|---|---|
| `disk-investigator` | Mapeia maiores pastas, arquivos e caches | Não |
| `performance-analyst` | Diagnostica CPU, RAM, E/S, GPU e rede | Não |
| `disk-cleaner` | Executa uma limpeza já aprovada, com quarentena | Só com aprovação |
| `startup-auditor` | Audita inicialização, serviços e tarefas agendadas | Só com aprovação |
| `bloatware-hunter` | Inventaria aplicativos removíveis | Só com aprovação, por nome |
| `restore-guardian` | Cria e lista pontos de restauração | Só com aprovação |

E duas skills, somente leitura: `/custo-varredura` mostra o que o antivírus está
varrendo e quanto isso custa; `/pressao-docker` mede o Docker e a VM do WSL2.

`.claude\settings.json` libera os comandos de leitura e pede confirmação para
os que alteram o sistema (`Remove-Item`, `Stop-Process`, serviços, registro,
`wsl --shutdown`, `docker prune`). Essa camada é uma rede a mais: a regra que
vale é a aprovação explícita descrita em `AGENTS.md`.

## Princípios de segurança

- Operações destrutivas usam dry-run por padrão.
- Caminhos de usuário, projeto ou empresa nunca são embutidos no código.
- Limpezas recebem uma raiz declarada e rejeitam alvos fora dela.
- Reparse points e manifestos incompletos são recusados.
- Terminal, shells e CLIs são processos protegidos; não devem ser encerrados
  para viabilizar uma limpeza.
- Docker, WSL, serviços e registro exigem autorização nominal separada.
- Relatórios reais são dados locais sensíveis e não são versionados.

Leia também [SECURITY.md](SECURITY.md), [AGENTS.md](AGENTS.md), o
[guia das CLIs de IA](docs/AI-CLI.md) e o
[guia de diagnóstico de memória](docs/MEMORY.md). Para monitoramento contínuo,
consulte o [guia do painel Pulso](docs/PRESSURE-DASHBOARD.md). Para Docker e
WSL2 — anatomia de travamento, defesas e diagnóstico — veja
[docs/DOCKER-WSL2.md](docs/DOCKER-WSL2.md).

## Requisitos

- Windows 10 ou Windows 11.
- PowerShell 7 ou superior (`pwsh`).
- Algumas coletas ficam mais completas em uma sessão elevada.
- Docker Desktop, WSL e Hyper-V são opcionais.
- A criação de ponto de restauração exige privilégios administrativos.

## CLIs de IA

`AGENTS.md` é a fonte única das regras do projeto:

| Ferramenta | Arquivo carregado | Situação |
|---|---|---|
| Codex CLI | `AGENTS.md` | suporte nativo |
| Claude Code | `CLAUDE.md`, que importa `AGENTS.md` | suporte nativo |
| Gemini CLI | `GEMINI.md`, que importa `AGENTS.md` | suporte nativo |
| Grok Build | `AGENTS.md` | suporte nativo |

Abra qualquer uma delas na raiz do clone. Instalação, autenticação, modelo,
plugins e preferências globais ficam no perfil de cada colaborador e não são
pré-configurados pelo repositório. Veja [docs/AI-CLI.md](docs/AI-CLI.md) para
conferir o contexto carregado em cada ferramenta.

## Início rápido

Clone ou extraia o projeto e abra um PowerShell na raiz:

```powershell
pwsh -NoProfile -File .\scripts\collect-performance.ps1 `
  -SampleCount 4 `
  -SampleIntervalSeconds 1

pwsh -NoProfile -File .\scripts\collect-memory.ps1 `
  -SampleCount 2 `
  -SampleIntervalSeconds 1

pwsh -NoProfile -File .\scripts\start-pressure-dashboard.ps1

pwsh -NoProfile -File .\scripts\measure-root-folders.ps1
```

As saídas são gravadas em `reports\`. Essa pasta é ignorada pelo Git porque
pode conter nomes de usuário, SIDs, processos, aplicativos e caminhos locais.

## Painel de pressão em runtime

O **Pulso** monitora CPU, memória, disco, GPU e rede em uma interface local,
correlaciona a pressão com processos e explica a confiança de cada conclusão.
Ele diferencia medição, correlação e inferência; causa raiz por pilha continua
sendo uma investigação avançada com ETW/WPR/WPA ou ProcMon.

Para CLIs, ele reconstrói `Windows Terminal → shell → CLI → processos filhos`
e agrega CPU, Private Bytes, Working Set, E/S, GPU e quantidade de processos
por sessão. Assim, dezenas de runtimes `node` ou `python` aparecem sob a CLI que
os iniciou, com destaque separado para sessões em atenção, críticas ou fora do
Windows Terminal.

```powershell
pwsh -NoProfile -File .\scripts\start-pressure-dashboard.ps1
```

O servidor escuta somente em `127.0.0.1`, funciona offline e não expõe linhas
de comando, caminhos de executáveis ou endereços remotos. O modo padrão é
somente leitura. Um modo opt-in pode oferecer encerramento apenas para árvores
de CLI deterministicamente órfãs:

```powershell
pwsh -NoProfile -File .\scripts\start-pressure-dashboard.ps1 `
  -EnableProcessTermination
```

Sessões do Windows Terminal, CLIs com pai vivo e qualquer árvore que contenha
o próprio dashboard permanecem bloqueadas. O clique ainda exige confirmação e
o backend repete a identidade `PID + início + árvore` antes do primeiro
encerramento. Contadores GPU usam WDDM quando o driver oferece suporte;
sensores de temperatura e potência são capacidades opcionais, não dependências.

Uma única leitura JSON pode ser obtida sem iniciar o servidor:

```powershell
pwsh -NoProfile -File .\scripts\start-pressure-dashboard.ps1 -SnapshotOnly
```

O painel também se mede, se registra e sabe a hora de sair:

- **Custo próprio.** Reporta a CPU e a memória do próprio processo e quanto de
  cada intervalo gasta coletando. A CPU dos provedores WMI aparece à parte,
  nunca somada, porque atende todo o computador.
- **Histórico local.** Grava `reports\pressure-history\*.jsonl` em lote de um
  minuto, com retenção de 7 dias ou 50 MB. Desligue com `-NoHistory`; limpe com
  `.\scripts\remove-pressure-history.ps1`, que é dry-run por padrão.
- **Antimalware.** Lê estado, agenda e exclusões somente para leitura, e
  correlaciona varredura em curso com pressão de disco. Nenhuma política é
  alterada.
- **Ciclo de vida.** Encerra sozinho se o processo pai desaparecer ou após
  `-IdleTimeoutMinutes` sem requisição (padrão 15).
- **Cadência adaptativa.** Com a máquina saudável o intervalo sobe em degraus
  até `-MaxRefreshSeconds`; ao primeiro sinal de pressão volta ao mínimo.

Veja [docs/PRESSURE-DASHBOARD.md](docs/PRESSURE-DASHBOARD.md) para arquitetura,
fontes oficiais, limites e portabilidade.

## Memória

`collect-memory.ps1` observa por padrão uma janela de um minuto e correlaciona
memória disponível, commit real, paginação, pools do kernel, cache, processos e
eventos 2004. Ele agrega processos com o mesmo nome e também preserva a visão
por PID, o que ajuda com aplicações multiprocesso.

```powershell
pwsh -NoProfile -File .\scripts\collect-memory.ps1
```

O relatório diferencia Working Set (páginas residentes em RAM) de Private
Bytes (memória privada comprometida). Crescimento durante a janela aparece
como candidato, não como diagnóstico de vazamento. VMMap, RAMMap, WPR/WPA e
PoolMon são apenas detectados; o projeto não instala nem inicia essas
ferramentas. Veja [docs/MEMORY.md](docs/MEMORY.md) para métricas, limites e
investigação avançada.

## Artefatos de build

Primeiro gere um manifesto somente leitura:

```powershell
$manifest = & .\scripts\measure-repo-artifacts.ps1 `
  -Root 'C:\Repos\meu-projeto'
```

Depois valide o plano. Sem `-Execute`, nada é removido:

```powershell
& .\scripts\remove-build-artifacts.ps1 `
  -ManifestPath $manifest `
  -ExpectedRoot 'C:\Repos\meu-projeto'
```

Mesmo no modo de execução, é possível testar a integração padrão do
PowerShell:

```powershell
& .\scripts\remove-build-artifacts.ps1 `
  -ManifestPath $manifest `
  -ExpectedRoot 'C:\Repos\meu-projeto' `
  -Execute `
  -WhatIf
```

Use `-Execute` sem `-WhatIf` somente depois de revisar o manifesto, confirmar a
raiz, o número de diretórios e os bytes planejados.

## Diretórios temporários antigos

Para filhos diretos de uma raiz (pastas `.tmp-*` de agentes, resíduo de testes
no `%TEMP%`), gere primeiro um manifesto somente leitura. `-SkipSize` evita
medir quando há centenas de milhares de pastas:

```powershell
$manifest = & .\scripts\measure-stale-directories.ps1 `
  -Root 'C:\Repos\meu-projeto' -Include '^\.tmp-' -Exclude '^\.tmp-auth$' -MinAgeDays 7
```

O removedor confere tudo de novo na hora, não só o que o manifesto diz: nome
contra `include` e contra os bloqueios (`criteria.exclude`, `bloqueioRegex` e
`-BlockPattern`), idade mínima, arquivo `LEIA-ME-NAO-APAGAR.md`, reparse point
no alvo ou em qualquer subdiretório e processo vivo com o caminho na linha de
comando. Um item bloqueado é recusado mesmo se estiver no manifesto. Com
`-Execute`, ele aborta antes de apagar se houver build (`dotnet`, `MSBuild`,
`devenv`, `VBCSCompiler`) ou teste (`pytest`, `unittest`, mutantes) rodando.

```powershell
& .\scripts\remove-stale-directories.ps1 `
  -ManifestPath $manifest `
  -ExpectedRoot 'C:\Repos\meu-projeto'
```

Sem `-Execute`, nada é removido. O log JSONL em `reports\` registra o status de
cada alvo e o espaço livre antes e depois.

## Varredura diária do %TEMP%

Testes que criam pastas com `tempfile.mkdtemp` e as apagam com
`shutil.rmtree(..., ignore_errors=True)` deixam resíduo no Windows sempre que há
arquivo somente leitura dentro delas, como os objetos de um `git init`. Os testes
passam, a limpeza falha em silêncio e o `%TEMP%` acumula centenas de milhares de
pastas. A correção é na origem; a varredura é a rede de segurança para o que
escapar, inclusive processo morto por timeout.

`sweep-temp-residue.ps1` lê os grupos de nomes de `local\temp-sweeper.json`,
porque os prefixos variam de máquina para máquina. Copie
`docs\temp-sweeper.example.json`, troque `host` pelo nome da máquina e liste só
os prefixos cuja origem você conferiu. Para cada grupo, ele gera um manifesto
novo e o entrega ao removedor acima, que revalida cada pasta na hora:

- idade mínima de um dia; nomes aleatórios (`tmpXXXXXXXX`, 8.3) só saem se a
  última escrita for anterior ao último boot;
- sai sem remover se o gate de disco, RAM, commit ou Windows Terminal falhar, ou
  se houver build ou teste rodando, e tenta de novo na próxima execução;
- para se um processo protegido sumir no meio; duas instâncias não rodam juntas;
- uma pasta com `LEIA-ME-NAO-APAGAR.md` dentro nunca é removida.

```powershell
pwsh -NoProfile -File .\scripts\sweep-temp-residue.ps1            # simula
pwsh -NoProfile -File .\scripts\install-temp-sweeper.ps1          # mostra a tarefa
pwsh -NoProfile -File .\scripts\install-temp-sweeper.ps1 -Execute # instala
pwsh -NoProfile -File .\scripts\report-temp-sweeper.ps1           # eficiência
```

A tarefa roda na conta do usuário, sem elevação e sem abrir janela, todo dia às
03:00, e repete a cada 3 h até o fim do dia para cobrir abortos. Depois de uma
execução bem-sucedida, as seguintes do mesmo dia saem sem fazer nada.
`-Uninstall -Execute` remove a tarefa, exportando antes o XML dela.

Cada execução grava uma linha em `reports\temp-sweeper\historico.jsonl`. O
relatório mostra se a varredura completa, o motivo dos abortos e quantas pastas
nascem por dia em cada prefixo, comparando dois períodos. É essa taxa que diz se
a correção na origem funcionou.

## Ponto de restauração

O script apenas apresenta o plano por padrão:

```powershell
pwsh -NoProfile -File .\scripts\new-cleanup-checkpoint.ps1
```

A criação real exige uma sessão elevada, `-Execute` e confirmação interativa:

```powershell
pwsh -NoProfile -File .\scripts\new-cleanup-checkpoint.ps1 `
  -Reason 'pre-cleanup_builds' `
  -Execute
```

## Troca de máquina

O que está num remoto não precisa de backup; o que só existe naquela máquina
precisa, e essa parte é sempre maior do que parece.
`report-migration-inventory.ps1` varre as raízes atrás de repositórios e mede,
em cada um, os commits fora de qualquer remoto e os arquivos ignorados que
importam. A varredura é somente leitura, serializada e retomável:

```powershell
pwsh -NoProfile -File .\scripts\report-migration-inventory.ps1 -Raiz C:\Projetos
pwsh -NoProfile -File .\scripts\report-migration-inventory.ps1 -Retomar
```

Runbook de migração envelhece em dias. `Test-RunbookClaims.ps1` compara as
afirmações de um runbook (versões, distros, volumes, contagens) com a máquina
atual e lista o que divergiu, antes de alguém executar um passo baseado nelas.

As lições de uma migração real, com checklist, estão em
[docs/MIGRACAO-DE-MAQUINA.md](docs/MIGRACAO-DE-MAQUINA.md).

## Várias contas da mesma CLI de IA

Quem usa mais de uma conta da mesma CLI (pessoal e trabalho, por exemplo) separa
cada uma num diretório de estado próprio. `sync-cli-profiles.ps1` gera, a partir
de um mapa local, os comandos que escolhem a conta (`PlanoPessoal`,
`PlanoTrabalho`...), as rotas por pasta e as abas do Windows Terminal, igual nos
perfis do PowerShell 7 e do 5.1. Cada plano pode ter uma cor de aba: ao abrir a
CLI, a aba ganha a cor do plano no ar e, ao sair, volta à cor anterior.

Os scripts ao redor:

- `unify-plan-sessions.ps1` junta o histórico dos planos num armazém comum,
  para que `claude -r` e a memória do projeto enxerguem as sessões de todos,
  sem juntar as contas;
- `creditos-resumo.ps1` mostra lado a lado plano, crédito de API e crédito de
  nuvem;
- `nuvem-credito.ps1` lança sessão na nuvem com teto e registro por projeto;
- `set-statusline.ps1` grava em cada diretório de estado a barra de status com o plano e a
  cota ([docs/CLAUDE-CODE-MODS.md](docs/CLAUDE-CODE-MODS.md)).

É a parte mais específica do repositório e não é necessária para o resto.
Formato do mapa em [scripts/perfis-cli.example.json](scripts/perfis-cli.example.json);
explicação completa em [docs/AI-CLI.md](docs/AI-CLI.md#perfis-isolados-da-mesma-cli).

## IIS: senha de domínio dos app pools

Pool do IIS que roda com conta de domínio guarda a senha. Quando a senha muda, o
pool passa a falhar com o evento 5021 e HTTP 503, o que parece aplicação
quebrada. `Set-AppPoolIdentity.ps1` mostra quais pools usam conta de domínio e,
com `-Execute` num terminal elevado, pede a credencial e regrava a identidade sem
a senha passar por linha de comando, arquivo em claro ou log:

```powershell
pwsh -NoProfile -File .\scripts\Set-AppPoolIdentity.ps1             # mostra
pwsh -NoProfile -File .\scripts\Set-AppPoolIdentity.ps1 -Execute    # regrava
```

## Scripts públicos

| Script | Função | Altera o sistema? |
|---|---|---|
| `collect-apps.ps1` | Inventário de aplicativos | Não |
| `collect-memory.ps1` | Pressão de memória, paginação, pools, processos e eventos 2004 | Não |
| `collect-performance.ps1` | Snapshot de CPU, RAM, commit e processos | Não |
| `collect-startup.ps1` | Inventário de inicialização | Não |
| `disk-map.ps1` | Mapa direcionado de disco | Não |
| `full-disk-inventory.ps1` | Inventário de disco com limites de tempo | Não |
| `measure-folder-children.ps1` | Medição paralela de pastas declaradas | Não |
| `measure-repo-artifacts.ps1` | Manifesto de `bin`, `obj`, `.vs` e `TestResults` | Não |
| `measure-root-folders.ps1` | Medição das pastas de uma unidade | Não |
| `measure-stale-directories.ps1` | Manifesto de subdiretórios antigos de uma raiz | Não |
| `monitor-perf.ps1` | Monitoramento temporário de CPU e commit real | Não |
| `new-cleanup-checkpoint.ps1` | Dry-run ou ponto de restauração | Só com `-Execute` |
| `remove-build-artifacts.ps1` | Dry-run ou remoção validada de builds | Só com `-Execute` |
| `remove-stale-directories.ps1` | Dry-run ou remoção revalidada de subdiretórios antigos | Só com `-Execute` |
| `sweep-temp-residue.ps1` | Varredura do resíduo de teste no `%TEMP%`, por grupos locais | Só com `-Execute` |
| `install-temp-sweeper.ps1` | Mostra, instala ou remove a tarefa diária da varredura | Só com `-Execute` |
| `report-temp-sweeper.ps1` | Eficiência da varredura: abortos e pastas criadas por dia | Não |
| `start-pressure-dashboard.ps1` | Painel local de CPU, memória, disco, GPU, rede e processos | Não |
| `stop-pressure-cli-session.ps1` | Dry-run ou encerramento nominal de árvore órfã revalidada | Só com `-Execute` |
| `record-pressure.ps1` | Gravação desassistida do histórico de pressão, sem servidor nem navegador | Não |
| `report-exclusion-coverage.ps1` | Relatório local de cobertura das exclusões do antimalware | Não |
| `report-docker-pressure.ps1` | Pressão do Docker/WSL2: estado do motor (inclusive afogado), consumo por container, tetos e VHDX | Não |
| `report-testcontainers-leak.ps1` | Denúncia de containers de Testcontainers vazados e de motor Docker sem resposta | Não |
| `remove-pressure-history.ps1` | Dry-run ou aplicação da retenção do histórico do painel | Só com `-Execute` |
| `report-migration-inventory.ps1` | O que só existe nesta máquina: commits fora de remoto e arquivos ignorados | Não |
| `Test-RunbookClaims.ps1` | Confere as afirmações de um runbook contra a máquina atual | Não |
| `sync-cli-profiles.ps1` | Gera comandos, rotas e abas das CLIs de IA a partir de um mapa | Só com `-Execute` |
| `unify-plan-sessions.ps1` | Junta o histórico dos planos de IA num armazém comum | Só com `-Execute` |
| `creditos-resumo.ps1` | Plano, crédito de API e crédito de nuvem lado a lado | Não |
| `nuvem-credito.ps1` | Lança sessão na nuvem com teto e registro por projeto | Só com `-Execute` |
| `set-statusline.ps1` | Grava a barra de status (`statusline.py`) no `settings.json` de cada plano | Só com `-Execute` |
| `Invoke-TrabalhoPesado.ps1` | Roda um comando pesado por vez, com teto de CPU e memória | Não; roda o comando dado |
| `Set-AppPoolIdentity.ps1` | Regrava a identidade de domínio dos pools do IIS | Só com `-Execute` |

A compactação de VHDX do Docker não é automatizada: ela exige interromper
Docker/WSL e pode derrubar shells, containers e CLIs.

## Dados locais

Estes diretórios existem no workspace, mas seu conteúdo não entra no Git:

- `reports\`: inventários e logs da máquina;
- `quarantine\`: arquivos preservados antes de uma exclusão;
- `local\`: configuração e snapshots específicos do operador.

Em `local\` ficam dois arquivos que os agentes e o teste leem quando existem:

- `maquinas.json`, o mapa das máquinas: papel de cada uma, o que já foi feito
  nela e o que é proibido ali. Sem ele, todo computador é tratado como
  desconhecido e o agente trabalha somente em leitura até você liberar;
- `termos-proibidos.txt`, os nomes que nunca podem chegar a um commit público.

Nunca force a inclusão desses arquivos em um commit público.

## Validação

O teste local não altera o sistema:

```powershell
pwsh -NoProfile -File .\tests\Test-PublicSurface.ps1
pwsh -NoProfile -File .\tests\Test-PressureDashboard.ps1
```

Ele valida sintaxe PowerShell, arquivos obrigatórios, caminhos pessoais,
referências corporativas, adaptadores das quatro CLIs e gates dos scripts que
podem alterar o sistema. Nas mensagens dos commits que ainda não estão em
nenhum remoto, confere os mesmos termos locais, caminhos e credenciais. O
segundo teste valida as regras de pressão e executa uma única coleta integrada,
somente leitura.

O primeiro teste também roda antes de cada `git push`. O hook não vem no clone;
ative uma vez por clone:

```powershell
git config core.hooksPath .githooks
```

## Contribuição e licença

Consulte [CONTRIBUTING.md](CONTRIBUTING.md). O projeto é distribuído sob a
licença MIT; confirme a titularidade e a política da sua organização antes de
publicar contribuições produzidas em ambiente corporativo.
