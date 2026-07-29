# Gerenciador de Computador — instruções para agentes

Este é o contrato canônico para qualquer agente de IA que trabalhe neste
repositório. Adaptadores de ferramentas devem importar este arquivo, não copiar
suas regras.

## Objetivo

Manter um toolkit PowerShell para diagnosticar espaço em disco e pressão de
recursos no Windows sem deixar a máquina, o terminal ou as ferramentas de
desenvolvimento indisponíveis.

O fluxo para qualquer mudança no computador é:

1. inspecionar;
2. apresentar plano, escopo, risco e bytes estimados;
3. obter aprovação explícita para a categoria exata;
4. executar somente essa categoria;
5. verificar o resultado e a saúde dos processos protegidos.

Editar arquivos deste repositório quando o usuário pediu uma implementação é
uma mudança de código normal. Os gates de aprovação abaixo se aplicam a
alterações no host, dados do usuário, serviços, aplicativos, Docker, WSL,
registro e artefatos fora do repositório.

## Comunicação e limites

- Responda em português, de forma direta.
- Mostre primeiro o que pretende fazer e o espaço esperado.
- Não inicialize Git, crie commits, publique, faça push ou altere remotos sem
  pedido explícito.
- Não instale, atualize ou reconfigure CLIs, plugins, skills ou arquivos globais
  em `~/.codex`, `~/.claude`, `~/.gemini`, `~/.grok` ou equivalentes sem pedido
  explícito.
- Não dependa de skills, agentes, credenciais ou caminhos existentes apenas na
  máquina do mantenedor.
- Nunca grave tokens, chaves, cookies, variáveis secretas ou inventários reais
  no repositório.

## Plataforma e portabilidade

- Alvo: Windows 10 ou Windows 11.
- Shell preferido: PowerShell 7+ (`pwsh`).
- Descubra a raiz em runtime por `$PSScriptRoot`; não presuma letra de unidade,
  nome de usuário ou diretório fixo.
- Docker Desktop, WSL, Hyper-V e privilégios administrativos são opcionais.
  Detecte a capacidade antes de usá-la.
- Use caminhos relativos ao repositório na documentação e nos testes.
- `reports\`, `quarantine\` e `local\` contêm dados locais ignorados pelo Git.

## Gate crítico de Terminal e CLIs

Antes de qualquer alteração no host:

1. registre PID, nome e consumo de memória de `WindowsTerminal`, `OpenConsole`,
   shells ativos e CLIs;
2. trate como protegidos `powershell`, `pwsh`, `cmd`, `bash`, `wsl`, `codex`,
   `claude`, `gemini`, `grok`, `opencode` e processos que os hospedam;
3. interrompa o lote se um PID protegido desaparecer ou se o sistema degradar.

Regras absolutas:

- Nunca use `Stop-Process`, `taskkill`, reinício do Terminal, encerramento do
  Docker Desktop ou `wsl --shutdown` sem autorização nominal para exatamente
  esses processos ou serviços.
- Nunca encerre uma CLI para liberar arquivo, memória, VHDX ou espaço em disco.
- Processo oculto, destacado ou reiniciado não preserva abas nem sessões do
  Terminal.
- Não inicie limpeza se houver menos de 5 GB livres, menos de 4 GB de RAM
  disponível, commit acima de 80%, ou Windows Terminal acima de 4 GB privados
  ou 2 GB de working set.

## Segurança para mudanças no host

1. Dry-run é o padrão. Execução real exige aprovação explícita na mesma sessão,
   com raiz, categoria, quantidade de itens e bytes declarados.
2. A aprovação de uma categoria não autoriza a próxima. Configuração de
   permissões de uma CLI também não equivale à aprovação do usuário.
3. Antes de mudança não trivial em serviço, inicialização, registro, DISM ou
   desinstalação em lote, crie um ponto de restauração e confirme que ele existe.
4. Para arquivos do usuário ou de origem ambígua, prefira mover para
   `quarantine\<timestamp>\` com manifesto e retenção padrão de sete dias.
5. Nunca apague manualmente conteúdo de `Windows\System32`,
   `Windows\SysWOW64`, `Windows\WinSxS`, `Windows\servicing\Packages`,
   `ProgramData\Microsoft\Crypto` ou o registro vivo.
6. Exporte a chave antes de escrever no registro. Registre o estado anterior
   antes de alterar serviços ou tarefas agendadas.
7. Nunca desative System Restore, Defender, SmartScreen, Tamper Protection ou
   Windows Update; não altere BCD, partições, MBR/GPT ou page file sem uma
   solicitação específica e análise de risco.
8. Nunca use `format`, `diskpart clean`, `cipher /w` ou
   `vssadmin delete shadows /all`.
9. `Remove-Item -Recurse` exige caminho absoluto, normalizado, validado e
   contido na raiz aprovada. Não use `-Force` para contornar uma validação.
10. WinSxS só pode ser reduzido por DISM. `/ResetBase` exige aviso específico
    sobre a perda da capacidade de desinstalar atualizações antigas.
11. Compactação de VHDX não é automatizada: parar Docker/WSL pode derrubar
    containers, shells e CLIs.

## Padrões de código PowerShell

- Scripts novos usam PowerShell 7+, `Set-StrictMode -Version Latest` e
  `$ErrorActionPreference = 'Stop'`, salvo motivo documentado.
- Operações mutáveis usam `[CmdletBinding(SupportsShouldProcess)]`, um switch
  `-Execute`, dry-run padrão e `$PSCmdlet.ShouldProcess`.
- Parâmetros de caminho usam `-LiteralPath`, normalização por
  `[IO.Path]::GetFullPath()` e validação de contenção.
- Recuse reparse points e manifestos incompletos em rotinas de remoção.
- Não use `Win32_Product` quando uma alternativa de inventário existir.
- Não capture saída que possa conter segredos em logs públicos.
- Preserve mudanças do usuário e não reformate arquivos fora do escopo.

## Estrutura

```text
<repo>\
├── AGENTS.md                  # contrato canônico, Codex e Grok
├── CLAUDE.md                  # adaptador Claude Code
├── GEMINI.md                  # adaptador Gemini CLI
├── .claude\                   # settings e subagentes Claude compatíveis
├── docs\                      # documentação pública
├── scripts\                   # scripts PowerShell reutilizáveis
├── tests\                     # validações somente leitura
├── reports\                   # saída local ignorada
├── quarantine\                # staging local ignorado
└── local\                     # material específico da máquina, ignorado
```

## Fluxos recomendados

Diagnóstico:

1. inventário de volume e maiores diretórios;
2. snapshot de CPU, RAM, commit e I/O;
3. inventário de inicialização e aplicativos;
4. síntese priorizada por espaço recuperável, risco e reversibilidade.

Limpeza:

1. checkpoint quando aplicável;
2. manifesto somente leitura;
3. aprovação granular;
4. execução por categoria com log;
5. nova medição e conferência dos PIDs protegidos.

## Relatórios e dados locais

Relatórios formais ficam em `reports\<tipo>_<YYYY-MM-DD_HHmm>.md` e incluem
resumo, achados, comandos executados e reversão. Eles podem revelar usuário,
SID, processos, aplicativos e infraestrutura; nunca os versione. Exemplos
públicos devem usar dados sintéticos.

Diretórios de estado das CLIs, como `.codex`, `.claude`, `.gemini` e `.grok`,
podem ser medidos em inventários, mas nunca são candidatos a limpeza
automática.

## Validação e definição de pronto

Execute sempre o teste público após alterar código, configuração ou
documentação de agentes:

```powershell
pwsh -NoProfile -File .\tests\Test-PublicSurface.ps1
```

Uma tarefa está pronta quando:

- a sintaxe PowerShell e as configurações passam;
- o comportamento destrutivo continua opt-in e reversível;
- não há caminho pessoal, referência corporativa ou credencial;
- Codex, Claude, Gemini e Grok recebem a mesma regra canônica;
- a documentação descreve qualquer mudança observável.
