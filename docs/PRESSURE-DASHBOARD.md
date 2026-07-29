# Painel local de pressão do computador

O **Pulso** é um painel local, somente leitura por padrão, para responder três
perguntas:

1. qual recurso está sob pressão agora;
2. qual sessão do Windows Terminal ou CLI concentra essa pressão;
3. o que é medição, correlação, inferência ou causa comprovada.

Ele funciona em qualquer Windows 10 ou Windows 11 compatível com PowerShell 7,
sem caminhos fixos, instalação de serviço, conta online ou dependência de uma
GPU específica.

## Início rápido

Na raiz do repositório:

```powershell
pwsh -NoProfile -File .\scripts\start-pressure-dashboard.ps1
```

O script abre `http://127.0.0.1:8765/` no navegador padrão. Para não abrir o
navegador automaticamente:

```powershell
pwsh -NoProfile -File .\scripts\start-pressure-dashboard.ps1 -NoBrowser
```

Use `Ctrl+C` no mesmo terminal para encerrar o servidor de forma graciosa. No
modo padrão, o painel nunca encerra outros processos.

Para habilitar o botão de encerramento estritamente para árvores de CLI
deterministicamente órfãs:

```powershell
pwsh -NoProfile -File .\scripts\start-pressure-dashboard.ps1 `
  -EnableProcessTermination
```

Esse switch apenas habilita a capacidade. Cada ação ainda exige confirmação
na interface e uma segunda validação no backend. Sessões do Terminal, CLIs com
pai vivo, serviços e árvores que contenham o próprio dashboard não recebem o
botão.

Para manter o servidor em segundo plano, sem ocupar uma aba:

```powershell
$shutdownToken = [guid]::NewGuid().ToString('N')
pwsh -NoProfile -File .\scripts\start-pressure-dashboard.ps1 `
  -Background `
  -NoBrowser `
  -ShutdownToken $shutdownToken
```

O comando retorna o PID exato do novo servidor. Encerre somente essa instância
pelo endpoint gracioso:

```powershell
Invoke-RestMethod `
  -Method Post `
  -Uri 'http://127.0.0.1:8765/api/shutdown' `
  -Headers @{ 'X-Pressure-Shutdown-Token' = $shutdownToken }
```

Para obter uma única leitura em JSON, sem iniciar o servidor:

```powershell
pwsh -NoProfile -File .\scripts\start-pressure-dashboard.ps1 -SnapshotOnly
```

## Ciclo de vida do servidor

O painel encerra sozinho em duas situações, para não sobreviver a quem o criou:

- **Processo pai ausente.** O PID e o horário de criação do pai são registrados
  na largada; se o par deixar de existir, o servidor sai em poucos segundos. O
  horário é o que impede confundir o pai original com um PID reciclado.
- **Ociosidade.** Sem nenhuma requisição por `-IdleTimeoutMinutes` (padrão 15),
  o servidor encerra. Use `0` para desligar a regra.

```powershell
pwsh -NoProfile -File .\scripts\start-pressure-dashboard.ps1 `
  -IdleTimeoutMinutes 30
```

No modo `-Background` o filho é destacado de propósito e recebe
`-NoParentWatch`: o processo que o lançou termina em seguida, e vigiar o pai
derrubaria o painel imediatamente. A regra de ociosidade continua valendo.

O encerramento é sempre o próprio servidor saindo do laço. Nenhum processo de
terceiros é encerrado por essa via.

## Histórico local

O painel grava um histórico compacto por padrão em
`reports\pressure-history\pressure_<AAAA-MM-DD>.jsonl`, uma linha por amostra,
mais uma linha de abertura e outra de encerramento por sessão.

- A escrita é **em lote**, uma vez por minuto, e não a cada amostra. Gravar de
  cinco em cinco segundos produziria E/S pequena e contínua — exatamente o
  padrão que este painel existe para diagnosticar.
- O nome do arquivo carrega a identidade do coletor — `_painel` ou `_gravador`.
  Dois coletores no mesmo arquivo diário disputariam o handle, e a amostra
  perdida não voltaria. Se ainda assim houver disputa, a escrita é desviada para
  um arquivo com sufixo de PID em vez de ser descartada, e o desvio fica
  registrado no estado do escritor.
- O conteúdo é numérico, mais nome de processo. Linha de comando, caminho de
  executável e endereço remoto não entram, como no restante do painel.
- Retenção padrão de 7 dias ou 50 MB, o que vier primeiro.

```powershell
pwsh -NoProfile -File .\scripts\start-pressure-dashboard.ps1 `
  -HistoryRetentionDays 14 -HistoryMaxMB 100

pwsh -NoProfile -File .\scripts\start-pressure-dashboard.ps1 -NoHistory
```

### Gravação desassistida

O painel coleta **sob demanda**: uma amostra por requisição a `/api/snapshot`.
Isso é adequado para observação ao vivo e inadequado para capturar um episódio
que começa em horário conhecido, porque a coleta passa a depender de uma aba
aberta no navegador. Aba fechada ou congelada pelo navegador significa nenhuma
amostra, mesmo com o servidor no ar.

Para captura desassistida existe um gravador dedicado, que coleta por conta
própria, sem abrir porta e sem servir interface:

```powershell
pwsh -NoProfile -File .\scripts\record-pressure.ps1 -Minutes 120
```

Ele usa a mesma cadência adaptativa, o mesmo formato de histórico e a mesma
vigília do processo pai. Termina por duração, por `Ctrl+C` ou quando quem o
iniciou desaparece. Não encerra nenhum processo.

Quem apaga é um script separado, com dry-run por padrão:

```powershell
pwsh -NoProfile -File .\scripts\remove-pressure-history.ps1
pwsh -NoProfile -File .\scripts\remove-pressure-history.ps1 -Execute
```

O núcleo do painel apenas calcula o plano de retenção
(`Get-PressureHistoryExpired`); a remoção fica concentrada no único arquivo que
carrega `SupportsShouldProcess`, `-Execute` e validação de contenção.

## Cadência adaptativa

Com a máquina em nível SAUDÁVEL, o intervalo de coleta sobe em degraus do
mínimo até `-MaxRefreshSeconds` (padrão 30 s). Ao primeiro sinal de pressão,
volta ao mínimo de uma vez. Subir devagar e descer de uma vez preserva o início
do episódio, que é a parte que interessa, e corta o custo do painel no resto do
tempo.

```powershell
pwsh -NoProfile -File .\scripts\start-pressure-dashboard.ps1 -FixedCadence
```

## Arquitetura

```text
CIM/WMI nativo do Windows
          │
          ▼
pressure-core.ps1
  ├─ normalização e cache
  ├─ atribuição por PID
  ├─ árvore Terminal → shell → CLI → filhos
  ├─ classificação protegida/gerenciada/órfã
  ├─ regras de pressão
  └─ explicações + confiança
          │
          ▼
HttpListener em 127.0.0.1
  └─ ação opt-in com token efêmero
          │
          ▼
HTML/CSS/JS offline no navegador
          │ confirmação explícita
          ▼
stop-pressure-cli-session.ps1
  └─ revalidação + ShouldProcess + PIDs exatos
```

O navegador solicita uma amostra, espera a resposta e só então aguarda o
intervalo configurado antes da próxima. Assim, coletas não se acumulam quando o
host está lento. O backend também reutiliza a última amostra por esse intervalo,
impedindo que várias abas disparem coletas WMI iguais em sequência. Metadados
que mudam com menor frequência possuem um cache separado.

O servidor:

- aceita apenas rotas conhecidas;
- escuta explicitamente em `127.0.0.1`, nunca em `*` ou `+`;
- não configura firewall, URL ACL, serviço ou inicialização automática;
- não usa bibliotecas, fontes ou chamadas de rede externas;
- aplica CSP e cabeçalhos defensivos;
- mantém ações de encerramento desativadas por padrão;
- quando há opt-in, aceita somente a rota nominal com token aleatório por
  instância e não oferece prioridade, limpeza ou outros ajustes do host.

## Fontes das métricas

| Recurso | Fonte nativa | Como é interpretado |
|---|---|---|
| CPU total | `Win32_PerfFormattedData_PerfOS_Processor` | Percentual da capacidade total |
| CPU por processo | `Win32_PerfFormattedData_PerfProc_Process` | Normalizado pelo número de processadores lógicos |
| Memória | `Win32_PerfFormattedData_PerfOS_Memory` | RAM disponível, commit e paginação |
| Memória por processo | `PrivateBytes` e `WorkingSet` | Commit privado e páginas residentes são exibidos separadamente |
| Disco | Classes `PerfDisk` formatada e raw | Tempo ativo, fila, throughput e latência calculada entre amostras |
| Espaço livre | `Win32_LogicalDisk` | Menor espaço livre entre volumes locais |
| GPU | `GPUPerformanceCounters_GPUEngine` | Maior utilização entre engines WDDM |
| Memória GPU | `GPUProcessMemory` e `GPUAdapterMemory` | Dedicada, compartilhada e comprometida quando disponíveis |
| Rede | `Tcpip_NetworkInterface` | Throughput agregado e razão contra a velocidade nominal |
| Conexões | `MSFT_NetTCPConnection` | Contagem de conexões estabelecidas por PID, atualizada em ritmo menor |
| Contexto | `Win32_Process` e `Win32_Service` | Processo pai, horário de criação, sessão, categoria segura e serviços hospedados |
| Antimalware | `MSFT_MpComputerStatus` e `MSFT_MpPreference` | Varredura em andamento, agenda, `ScanOnlyIfIdle` e exclusões, relidos a cada 60 s |
| Custo próprio | Linhas já coletadas de `PerfProc_Process` | CPU do painel, CPU dos provedores WMI e fração do intervalo gasta coletando |

Os nomes das classes CIM são estáveis e não dependem do idioma em que o
Windows foi instalado. A primeira leitura de latência de disco aparece como
“aquecendo”, pois contadores de média exigem duas amostras.

### Semântica de GPU

Somar todas as engines de uma GPU seria enganoso: engines diferentes podem
compartilhar os mesmos núcleos. O Pulso usa a engine mais ocupada, a mesma
decisão de agregação documentada para o Gerenciador de Tarefas. Isso também
permite distinguir 3D, Compute, Video Decode, Video Encode e outras engines.

Os contadores exigem um driver WDDM 2.x. Se não estiverem presentes, a GPU
aparece como indisponível e o restante do painel continua funcionando.

Memória GPU compartilhada pode estar mapeada em mais de um processo. Por isso,
somar a visão por PID pode superar o total físico. Processos como `dwm.exe` e
`csrss.exe` também podem representar superfícies criadas em nome de outros
aplicativos.

### Antimalware

A leitura é estritamente somente leitura. O painel nunca altera agenda,
exclusão ou qualquer política de antimalware: em máquina gerenciada isso é
decisão da organização, e privilégio local não equivale a autorização.

Varredura em andamento é **inferida** por um início de varredura completa
posterior ao término registrado, que é como o Windows expõe esse estado. Não há
API que devolva "está varrendo agora" de forma direta.

O painel também compara as exclusões declaradas com os caminhos típicos de um
toolchain moderno — runtime Node, binários globais e cache do npm, e diretórios
de estado das CLIs de IA. A ausência desses caminhos não é apresentada como
erro: é uma lacuna informada, cuja correção envolve troca real de risco e
decisão de quem administra a máquina.

A comparação leva em conta os dois tipos de exclusão, porque eles têm alcances
diferentes:

- **Exclusão de caminho** cobre os arquivos daquele diretório, independentemente
  de qual processo os abre.
- **Exclusão de processo** cobre os arquivos **abertos por** aquele processo, e
  não apenas o executável dele.

A distinção muda o resultado na prática. `npm` e `npx` são JavaScript executado
dentro do `node.exe`, então uma exclusão de processo para `node.exe` já cobre o
cache do npm sem precisar de exclusão de caminho. O mesmo não vale para o estado
das CLIs de IA: `claude.exe` e `codex.exe` são binários próprios, então o que
eles escrevem continua sendo varrido mesmo com `node.exe` excluído.

Tratar as duas formas como equivalentes produziria lacuna falsa num caso e
cobertura imaginária no outro.

#### Contenção de caminho, não substring

A comparação de caminhos usa contenção real: uma exclusão cobre um diretório
quando é o próprio diretório ou um ancestral dele. Comparar por substring
produziria erro grave e silencioso — `.claude` apareceria como cobertura de
`.claude-pessoal`, que na prática continuaria sendo varrido.

O curinga `*` vale por um único segmento e nunca atravessa barra, então
`C:\Users\*\AppData\Roaming\npm` cobre o diretório de um perfil e não um
subdiretório mais fundo. Padrão com variável de ambiente que não existe no
sistema não cobre nada, e o painel o trata assim em vez de assumir intenção.

#### Perfis isolados da mesma CLI

Um mesmo computador costuma ter vários diretórios de estado da mesma CLI, um
por conta ou por projeto, escolhidos por variável de ambiente na hora de
iniciar. Verificar apenas o diretório padrão daria falsa sensação de cobertura.

O painel descobre os candidatos por convenção de nome nas raízes configuradas,
mais os valores atuais de `CLAUDE_CONFIG_DIR` e `CODEX_HOME`, e avalia cada um
separadamente. A varredura é de um nível só e não percorre o conteúdo dos
diretórios: contar arquivos ali somaria E/S justamente no caminho que o painel
aponta como problema.

Na interface e no snapshot aparecem apenas o nome da pasta e o resultado da
cobertura. O caminho completo revelaria o perfil do usuário, e o painel não
expõe caminho.

Quando o caminho completo é justamente o que se precisa — para abrir um chamado,
por exemplo — existe um relatório local dedicado:

```powershell
pwsh -NoProfile -File .\scripts\report-exclusion-coverage.ps1 -ExtraRoots 'C:\Repos'
```

Ele mede volume por diretório, cruza com as exclusões, monta o bloco pronto para
colar no chamado e grava em `reports\`, fora do controle de versão. É somente
leitura: nenhuma configuração de antimalware é alterada, porque em máquina
gerenciada essa decisão é da organização.

### Custo do próprio painel

Uma ferramenta de medição que não aparece na própria medição é ponto cego. O
painel reporta a CPU do seu processo, a memória privada, a duração da coleta,
a média e o pico acumulados, e a fração do intervalo gasta coletando.

A CPU dos provedores WMI é exibida **separadamente e nunca somada** ao custo
próprio: `WmiPrvSE` atende todos os clientes do computador, e atribuir esse
total ao painel seria um palpite disfarçado de medição.

Nada disso custa consulta adicional: a tabela de processos já é coletada de
qualquer forma, e o painel apenas lê as linhas que dizem respeito a ele.

### Temperatura, potência e ventoinhas

Não existe uma API nativa única que entregue esses sensores com comportamento
uniforme em Intel, AMD, NVIDIA, todos os SSDs e todas as placas-mãe. O MVP não
finge essa portabilidade.

Uma evolução poderá usar adaptadores opcionais:

- LibreHardwareMonitor para sensores de vários fabricantes;
- NVML em GPUs NVIDIA;
- APIs equivalentes dos outros fabricantes;
- PresentMon para telemetria de aplicações gráficas.

Esses adaptadores devem ser detectados, nunca instalados automaticamente.

## Como o painel responde “por quê”

Há quatro níveis distintos:

| Nível | Exemplo | Confiança |
|---|---|---|
| Medição | “PID 123 usou 18% da CPU total” | alta |
| Correlação | “a latência de disco subiu enquanto esse PID liderava E/S” | média |
| Inferência contextual | “é um runtime de build iniciado por uma CLI” | média |
| Causa comprovada | “esta pilha chamou este arquivo e bloqueou neste driver” | exige trace |

O painel chega aos três primeiros níveis com baixo impacto. Causa comprovada
normalmente exige ETW/WPR/WPA, ProcMon, GPUView ou outra captura dedicada.
Essas ferramentas podem gerar arquivos grandes, exigir elevação ou alterar o
perfil de instrumentação; portanto, não são iniciadas em runtime pelo MVP.

As explicações usam somente:

- nome e PID;
- nome e PID do processo pai;
- categoria derivada localmente;
- nomes de serviços hospedados;
- métricas observadas.

Linhas de comando completas, caminhos de executáveis, endereços remotos,
tokens, cookies e variáveis de ambiente não são enviados ao navegador.

## Como as CLIs do Windows Terminal são atribuídas

Olhar apenas para `WindowsTerminal.exe` é insuficiente. O host gráfico pode
usar pouca memória enquanto shells, CLIs, MCPs e runtimes descendentes mantêm
vários gigabytes de commit privado. O Pulso reconstrói essa responsabilidade
em quatro passos:

1. monta o grafo `PID → PID pai` com `Win32_Process`;
2. rejeita um vínculo quando o suposto pai foi criado depois do filho, evitando
   atribuição a um PID reutilizado;
3. encontra o ancestral `WindowsTerminal.exe`, o primeiro shell abaixo dele e
   a CLI reconhecida mais próxima;
4. soma todos os descendentes da sessão, incluindo `node`, `python`, builds,
   testes e servidores MCP.

Cada cartão de sessão mostra:

- `WindowsTerminal PID → shell PID → CLI PID`;
- CPU agregada da árvore, normalizada pela capacidade total da máquina;
- Private Bytes somado, que representa o commit privado atribuível;
- Working Set somado apenas como referência, pois páginas compartilhadas podem
  aparecer em mais de um processo;
- E/S agregada, quantidade de processos e os cinco PIDs de maior impacto;
- nível, motivo, confiança de atribuição e confiança de causa.

CLIs sem ancestral Windows Terminal também aparecem, marcadas como “fora do
Terminal”. A atribuição por árvore tem confiança alta quando toda a cadeia está
viva. Ela demonstra quem é responsável pelos processos, mas não prova qual
arquivo, extensão, prompt ou chamada interna causou a atividade.

Linhas de comando são analisadas somente em memória para reconhecer assinaturas
seguras de pacotes como `@openai/codex`, `@anthropic-ai/claude-code` e
`@google/gemini-cli`. O valor bruto nunca integra a resposta JSON.

## Detecção e encerramento determinísticos

O polling apenas detecta e classifica; ele nunca encerra automaticamente. Para
cada raiz de CLI, o backend aplica a mesma ordem de decisão:

1. se há ancestral `WindowsTerminal.exe`, a sessão é **protegida**;
2. se a árvore contém o PID do servidor do dashboard ou qualquer processo da
   linhagem que o mantém vivo, ela é **protegida pelo painel**;
3. se o pai original ainda existe e foi criado antes da CLI, ela é
   **gerenciada** — por exemplo, `ChatGPT.exe → codex.exe` — e pode ser
   recriada pelo gerenciador;
4. somente quando o pai não existe mais, ou seu PID foi reutilizado por um
   processo mais novo, a raiz é **órfã confirmada**;
5. serviços, identidades sem horário de criação e árvores acima de 512 PIDs
   exigem revisão manual.

Uma candidata recebe uma impressão SHA-256 calculada sobre a lista ordenada de
`PID | nome | PID pai | horário de criação`. Ao abrir a confirmação, a interface
mostra CLI, PID raiz, início, quantidade de processos, Private Bytes e Working
Set observados. O envio exige:

- opt-in `-EnableProcessTermination` no servidor;
- checkbox e clique de confirmação;
- token criptograficamente aleatório, mantido apenas na instância local;
- PID raiz, horário inicial, quantidade e impressão vistos pelo usuário.

Antes do primeiro `Stop-Process`, o executor faz uma nova captura CIM e recusa
a ação inteira se qualquer identidade, vínculo, quantidade ou impressão mudou.
Ele também recalcula a própria linhagem por `$PID`; assim, mesmo uma interface
desatualizada ou manipulada não consegue apontar para o servidor do dashboard.
O executor usa `SupportsShouldProcess`, funciona em dry-run sem `-Execute` e
encerra somente IDs explícitos — nunca nome, wildcard ou árvore inferida depois
da aprovação.

O botão não aparece para processos apenas “fora do Terminal” quando há um pai
vivo. Isso evita o caso em que um aplicativo gerenciador relança imediatamente
seu helper e impede que “idade” ou “consumo” sejam confundidos com abandono.

## Classificação de pressão

O estado geral é o pior estado entre os recursos, com desempate pelo maior
score. Um pico e uma condição sustentada são tratados de forma diferente.

| Recurso | Atenção | Crítico ou emergência |
|---|---|---|
| CPU | pico a partir de 85% | 85% ou mais por três ciclos |
| Memória | menos de 4 GB disponíveis ou commit a partir de 80% | menos de 1,5 GB ou commit a partir de 92%; emergência abaixo de 750 MB ou 97% |
| Disco | latência a partir de 25 ms, 90% ativo ou menos de 5 GB livres | latência alta repetida ou menos de 2 GB; emergência abaixo de 500 MB |
| GPU | pico a partir de 85% | 85% ou mais por três ciclos |
| Rede | interface a partir de 80% do link nominal | 80% ou mais por três ciclos |

As árvores de terminal e CLI têm limites próprios para tornar o risco visível
mesmo quando o consumo está pulverizado entre muitos runtimes:

| Escopo | Observar | Atenção | Crítico | Emergência |
|---|---:|---:|---:|---:|
| Todas as árvores do Windows Terminal | 2 GB privados | 4 GB | 8 GB | 12 GB |
| Uma sessão de shell/CLI | 1 GB privado | 2 GB | 4 GB | pressão de memória do host em emergência |

CPU, GPU, E/S e quantidade de processos também podem elevar uma sessão. E/S
por PID inclui arquivo, rede e dispositivo; por isso só vira evidência crítica
de disco quando coincide com pressão de disco medida no host.

Para disco, a documentação da Microsoft recomenda investigar latência alta por
uma janela de um minuto ou mais. Três ciclos no painel elevam a prioridade para
não esconder degradação, mas a explicação continua pedindo confirmação por uma
janela maior.

Os limites de memória e espaço seguem os gates conservadores do `AGENTS.md`.
Eles são sinais de saúde, não autorização automática para limpar, encerrar ou
reconfigurar o computador. A única ação possível requer o opt-in e a aprovação
nominal descritos acima; em nível de emergência, o executor recusa novas
alterações.

## Limitações deliberadas

- E/S por processo inclui arquivo, dispositivo e outras operações; não é
  rotulada como “bytes físicos de disco”.
- O Windows expõe conexões TCP por PID, mas throughput por PID requer ETW ou
  outra fonte. O painel não distribui o total por palpite.
- Um navegador é multiprocesso; o PID sozinho não identifica a aba ou extensão.
- Crescimento de memória em uma janela curta não comprova vazamento.
- Uma amostra saudável não exclui picos anteriores.
- Processos terminam e PIDs são reutilizados; o horário de criação evita
  vínculos impossíveis, mas metadados ainda são atualizados periodicamente.
- Alguns contadores ou metadados exigem privilégios adicionais. Ausência vira
  capacidade indisponível, não falha total.
- O histórico é local, tem retenção declarada e nunca é versionado; `reports\`
  é ignorado pelo Git e o conteúdo revela o que roda nesta máquina.
- Varredura de antimalware em andamento é inferida por horários de início e
  término, não observada diretamente.
- Lacuna de exclusão é um apontamento, não uma recomendação: excluir caminhos
  que executam código de terceiros reduz cobertura real do antivírus.
- A correlação entre E/S do antimalware e fila de disco é observacional. O
  painel apresenta a coincidência e declara a confiança; não afirma causa.

## Pesquisa de referência

As decisões foram baseadas principalmente em documentação oficial e projetos
primários:

- [Troubleshoot performance problems in Windows](https://learn.microsoft.com/en-us/troubleshoot/windows-server/performance/troubleshoot-performance-problems-in-windows):
  contadores essenciais e faixas de latência.
- [Accessing WMI preinstalled performance classes](https://learn.microsoft.com/en-us/windows/win32/wmisdk/accessing-wmi-preinstalled-performance-classes):
  classes raw e formatadas.
- [Win32_Process](https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-process):
  PID pai, horário de criação, sessão e linha de comando usada apenas para
  inferência local.
- [Windows Terminal FAQ](https://learn.microsoft.com/en-us/windows/terminal/faq):
  diferença entre o host de terminal e os shells/aplicativos de linha de
  comando executados dentro dele.
- [Win32 network interface performance class](https://learn.microsoft.com/en-us/previous-versions/aa394293%28v%3Dvs.85%29):
  bytes, velocidade nominal e erros por interface.
- [GPUs in the Task Manager](https://devblogs.microsoft.com/directx/gpus-in-the-task-manager/):
  WDDM, VidSch/VidMm, engine mais ocupada e ressalvas de memória por processo.
- [WPR/WPA troubleshooting](https://learn.microsoft.com/en-us/troubleshoot/windows-server/support-tools/support-tools-xperf-wpa-wpr):
  traces ETW, CPU por pilha, esperas e vazamentos.
- [Process Monitor](https://learn.microsoft.com/en-us/sysinternals/downloads/procmon):
  atividade de arquivos, Registro e processos com pilhas.
- [Process Explorer](https://learn.microsoft.com/en-us/sysinternals/downloads/process-explorer):
  árvore de processos, handles e DLLs.
- [GPUView](https://learn.microsoft.com/en-us/windows-hardware/drivers/display/using-gpuview):
  análise profunda de CPU/GPU a partir de ETL.
- [System Informer](https://github.com/winsiderss/systeminformer):
  referência de UI portátil e atribuição de recursos.
- [LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor):
  sensores de hardware multi-fabricante como integração opcional.
- [NVML](https://docs.nvidia.com/deploy/nvml-api/nvml-api-reference.html):
  métricas específicas NVIDIA, incluindo temperatura, potência e utilização.
- [PresentMon](https://github.com/GameTechDev/PresentMon):
  frames, ETW e telemetria gráfica avançada.

## Próximas evoluções possíveis

1. Adaptador opcional de sensores térmicos e potência.
2. Investigação ETW acionada manualmente, com plano de bytes e aprovação.
3. Histórico e tendência separados por árvore de Terminal/CLI.
4. Visualização do histórico gravado dentro do próprio painel, hoje disponível
   apenas como arquivo JSONL.
5. Adaptadores de coleta para Linux e macOS mantendo a mesma API do painel.

O quinto item só é necessário se “qualquer computador” significar também outros
sistemas operacionais. O MVP atual é portátil entre computadores Windows, que
é o alvo canônico deste repositório.

O histórico local com retenção declarada e os alertas correlacionados ao
antimalware saíram desta lista porque foram entregues; veja “Histórico local” e
“Antimalware”.
