# Gerenciador de Computador

Toolkit PowerShell para diagnosticar espaço em disco e pressão de recursos no
Windows com uma regra central: **inspecionar primeiro, alterar somente com
escopo e aprovação explícitos**.

O projeto combina scripts reutilizáveis com instruções portáveis para Codex
CLI, Claude Code, Gemini CLI e Grok Build. Os scripts podem ser usados sem uma
CLI de IA.

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
consulte o [guia do painel Pulso](docs/PRESSURE-DASHBOARD.md).

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
| `monitor-perf.ps1` | Monitoramento temporário de CPU e commit real | Não |
| `new-cleanup-checkpoint.ps1` | Dry-run ou ponto de restauração | Só com `-Execute` |
| `remove-build-artifacts.ps1` | Dry-run ou remoção validada de builds | Só com `-Execute` |
| `start-pressure-dashboard.ps1` | Painel local de CPU, memória, disco, GPU, rede e processos | Não |
| `stop-pressure-cli-session.ps1` | Dry-run ou encerramento nominal de árvore órfã revalidada | Só com `-Execute` |
| `record-pressure.ps1` | Gravação desassistida do histórico de pressão, sem servidor nem navegador | Não |
| `remove-pressure-history.ps1` | Dry-run ou aplicação da retenção do histórico do painel | Só com `-Execute` |

A compactação de VHDX do Docker não é automatizada: ela exige interromper
Docker/WSL e pode derrubar shells, containers e CLIs.

## Dados locais

Estes diretórios existem no workspace, mas seu conteúdo não entra no Git:

- `reports\`: inventários e logs da máquina;
- `quarantine\`: arquivos preservados antes de uma exclusão;
- `local\`: scripts legados ou snapshots específicos do operador.

Nunca force a inclusão desses arquivos em um commit público.

## Validação

O teste local não altera o sistema:

```powershell
pwsh -NoProfile -File .\tests\Test-PublicSurface.ps1
pwsh -NoProfile -File .\tests\Test-PressureDashboard.ps1
```

Ele valida sintaxe PowerShell, arquivos obrigatórios, caminhos pessoais,
referências corporativas, adaptadores das quatro CLIs e gates dos scripts que
podem alterar o sistema. O segundo teste valida as regras de pressão e executa
uma única coleta integrada, somente leitura.

## Contribuição e licença

Consulte [CONTRIBUTING.md](CONTRIBUTING.md). O projeto é distribuído sob a
licença MIT; confirme a titularidade e a política da sua organização antes de
publicar contribuições produzidas em ambiente corporativo.
