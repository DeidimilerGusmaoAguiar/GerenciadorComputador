# Trabalhando com CLIs de IA

O repositório usa `AGENTS.md` como fonte única de instruções. Arquivos
específicos de fornecedor são adaptadores pequenos; mudanças de segurança,
arquitetura ou validação pertencem ao arquivo canônico.

## Compatibilidade

| CLI | Entrada no repositório | Carregamento |
|---|---|---|
| Codex CLI | `AGENTS.md` | nativo e automático |
| Claude Code | `CLAUDE.md` → `AGENTS.md` | import nativo com `@AGENTS.md` |
| Gemini CLI | `GEMINI.md` → `AGENTS.md` | import nativo com `@./AGENTS.md` |
| Grok Build | `AGENTS.md` | nativo e automático |

Não existe `GROK.md` porque o Grok Build reconhece `AGENTS.md` diretamente. Ele
também reconhece ativos do Claude Code; por isso os subagentes em
`.claude\agents\` continuam utilizáveis onde houver compatibilidade.

Referências oficiais:

- [Codex: AGENTS.md](https://learn.chatgpt.com/docs/agent-configuration/agents-md)
- [Claude Code: memória e imports](https://code.claude.com/docs/en/memory)
- [Gemini CLI: GEMINI.md e imports](https://geminicli.com/docs/cli/gemini-md/)
- [Grok Build: regras de projeto](https://docs.x.ai/build/features/project-rules)

## Início

Instale e autentique a CLI escolhida conforme a documentação do fornecedor.
Depois, abra um terminal na raiz do clone e inicie apenas uma das ferramentas:

```powershell
codex
claude
gemini
grok
```

Nenhuma chave, conta, modelo ou caminho do computador do mantenedor é
necessário para o repositório. Cada colaborador mantém autenticação e
preferências no próprio perfil.

## Conferência do contexto

- Codex e Grok leem `AGENTS.md` diretamente.
- No Claude Code, `/context` deve listar `CLAUDE.md`.
- No Gemini CLI, `/memory show` exibe o contexto importado; use
  `/memory reload` depois de mudanças.
- No Grok Build, `grok inspect` lista os arquivos de regras descobertos.

Se a ferramenta foi iniciada antes de um adaptador ser alterado, recarregue o
contexto ou abra uma sessão nova.

## Limites de portabilidade

- Skills, plugins e configurações globais instalados no perfil de uma pessoa
  não fazem parte do projeto.
- `.claude\agents\` e `.claude\settings.json` são ativos versionados do
  repositório; arquivos `*.local.*` permanecem privados.
- `reports\`, `quarantine\` e `local\` nunca devem ser enviados como contexto
  nem publicados.
- Não configure modelo padrão, provedor, credencial ou modo irrestrito no
  repositório. Essas escolhas pertencem ao usuário ou à política da organização.

## Perfis isolados da mesma CLI

Um computador pode manter várias contas da mesma ferramenta — pessoal,
corporativa, um escopo dedicado a um repositório. A separação é feita por
diretório de estado, apontado por variável de ambiente:

| CLI | Variável | Diretório padrão |
|---|---|---|
| Claude Code | `CLAUDE_CONFIG_DIR` | `%USERPROFILE%\.claude` |
| Codex CLI | `CODEX_HOME` | `%USERPROFILE%\.codex` |

O atalho que troca de perfil pertence ao perfil do shell de cada pessoa, não ao
repositório. Um exemplo mínimo, com nome sintético:

```powershell
function cli-perfil-b {
    $anterior = $env:CLAUDE_CONFIG_DIR
    try {
        $env:CLAUDE_CONFIG_DIR = "$env:USERPROFILE\.claude-perfil-b"
        claude @args
    } finally {
        $env:CLAUDE_CONFIG_DIR = $anterior
    }
}
```

Restaurar o valor anterior no `finally` evita que a sessão do terminal continue
apontando para o perfil trocado depois que a CLI sai.

### Quando o atalho é a pergunta errada

Um atalho por diretório de estado funciona enquanto os perfis forem poucos e
independentes. Ele começa a mentir quando duas perguntas diferentes se misturam
no mesmo nome:

- **qual conta paga a sessão** — pessoal, trabalho, um cliente;
- **o que a sessão enxerga** — as skills, hooks e agents instalados no perfil do
  usuário, ou um diretório dedicado e limpo.

São eixos independentes, e um nome só não carrega os dois sem virar
`cli-perfil-b-sem-skills-mas-com-a-outra-conta`. Pior: o nome do atalho não é
evidência de nada. A conta mora no diretório de estado, e um `/login` feito lá
dentro troca a conta sem trocar o atalho — o nome continua dizendo "pessoal"
enquanto a sessão consome outro plano.

A saída é separar as duas perguntas e dar cada uma a quem sabe respondê-la:

- **a pasta de trabalho decide o que a sessão enxerga.** Um repositório que
  depende das skills instaladas no perfil do usuário é declarado como zona sem
  blindagem; todo o resto do computador abre blindado.
- **o comando decide a conta.** `PlanoPessoal` e `PlanoTrabalho` escolhem o lado,
  nunca a blindagem. Digitados na mesma pasta, os dois respeitam o que aquela
  pasta determinou.
- **o comando padrão da CLI segue uma tabela de rotas.** Sem argumento nenhum,
  `claude` numa pasta declarada abre o lado daquela pasta; em qualquer outra,
  abre o lado padrão.

Com isso o conjunto de nomes para de crescer: dois lados, um comando de menu
(`Planos`) e um de diagnóstico (`PlanoAtual`) cobrem qualquer número de
diretórios de estado. E um erro fica impossível de esconder — `PlanoAtual`
imprime, para a pasta corrente, qual diretório de estado seria usado e qual conta
está gravada nele.

### Um login por conta, não por diretório

Separar blindagem exige diretórios de estado distintos — mas a credencial mora
dentro de cada diretório. A conta pessoal com dois escopos vira dois `/login`
para a mesma pessoa, e cada renovação de token só vale para um lado. Quatro
diretórios, quatro autenticações: o isolamento fica caro no uso diário.

A saída é tratar o login como propriedade da **conta**. Antes de subir, o
diretório com a credencial mais recente daquele lado abastece os irmãos que
estejam vazios ou atrasados. Um `/login` em qualquer lugar do lado passa a valer
para o lado inteiro, e a renovação se propaga sozinha no próximo uso.

Duas travas fazem disso uma defesa em vez de um risco:

- **a cópia nunca atravessa lados.** Pessoal e corporativo são contas
  diferentes, e o mapa diz qual e-mail pertence a cada lado.
- **só é fonte o diretório cuja conta gravada é a declarada para aquele lado.**
  Sem essa trava, um `/login` trocado dentro de um diretório espalharia a conta
  errada por todos os irmãos — que é exatamente o defeito que o arranjo existe
  para impedir. Diretório logado em outra conta não é tratado como atrasado: é
  denunciado em vermelho e não é tocado.

Só metadados são lidos — se há token e até quando. O valor nunca é lido para
variável, impresso nem registrado; o arquivo é copiado inteiro.

A credencial não viaja sozinha. A CLI decide se há login por dois campos do
`.claude.json` do diretório de estado, e só depois olha o token:

- **`oauthAccount`** — sem ele, a CLI ignora o token e pede login;
- **`hasCompletedOnboarding`** — sem ele, a CLI abre o assistente de primeira
  execução, que traz o passo de login no meio. Um diretório que só rodou a CLI
  em modo não interativo nunca ganha essa marca, mesmo com token válido e conta
  gravada.

Antes de subir, todo diretório do lado que tenha token recebe o que faltar
desses dois campos, vindo de um irmão logado na conta esperada — inclusive o
dono da credencial mais nova, que pode ser justamente o que nunca completou uma
sessão interativa.

Uma armadilha do diretório padrão: com `CLAUDE_CONFIG_DIR` apontando para
`~\.claude`, a CLI lê `~\.claude\.claude.json`; sem a variável, lê
`~\.claude.json`. São dois arquivos distintos, e o primeiro nasce virgem mesmo
quando o segundo já tem a conta e o onboarding feitos. Foi assim que, em
02/09/2026, a zona sem blindagem subiu com token válido no cabeçalho e caiu na
tela de login.

Isso também dá o teste de sanidade que faltava: como o mapa declara o e-mail
esperado de cada lado, qualquer sessão que suba com a conta errada é apontada no
cabeçalho, antes do primeiro prompt.

Duas defesas valem a pena junto com isso:

- **avisar quando o lado padrão for pessoal dentro de uma raiz de trabalho.** A
  regra continua literal, mas um repositório da empresa consumindo o plano
  pessoal para de acontecer em silêncio.
- **um piso de segurança fora do shell.** Um editor, um `.cmd` ou um atalho que
  chame a CLI direto não passa por função nenhuma e cai no diretório padrão.
  Definir a variável de estado como variável de usuário permanente, apontando
  para o perfil blindado, faz o piso ser o mais restrito em vez do mais aberto.

Duas consequências importam para o diagnóstico deste projeto:

- Cada perfil é um diretório de estado independente, e alguns passam de
  centenas de MB. Eles entram nos inventários de espaço, mas nunca são
  candidatos a limpeza automática.
- Para o antimalware, cada diretório é um alvo distinto. Excluir `.claude` não
  cobre `.claude-perfil-b`: irmão com prefixo comum não é caminho contido. Por
  isso `Get-PressureCliHomeCoverage` avalia um diretório por vez, em lugar de
  casar por substring, e cada perfil precisa da própria entrada em
  `ExclusionPath`. Perfis vazios também precisam, sob pena de a varredura
  encontrá-los já cheios no primeiro uso.

Perfis criados por lançadores fora do shell — um `.cmd` que monta a variável,
por exemplo — não aparecem em nenhuma lista de aliases. Prefira descobrir os
diretórios por convenção de nome ao montar um inventário.

O mapa de uma máquina específica é dado local: mantenha-o em `local\`, nunca
versionado.

### Mantendo os hosts sincronizados

Windows PowerShell 5.1 e PowerShell 7 leem arquivos de perfil diferentes
(`Documents\WindowsPowerShell\` e `Documents\PowerShell\`). Editar os dois à mão
faz um deles ficar para trás sem aviso — e quem descobre é você, ao abrir a aba
errada e não achar o atalho.

`scripts\sync-cli-profiles.ps1` trata um mapa como fonte única e escreve uma
região delimitada por marcadores em cada perfil de host:

```powershell
# maquina nova: descobre os perfis por convencao e propoe o mapa
pwsh -NoProfile -File .\scripts\sync-cli-profiles.ps1 -Bootstrap -SearchRoot C:\Repos

# revise rotulo, cor e alias no mapa, depois:
pwsh -NoProfile -File .\scripts\sync-cli-profiles.ps1              # dry-run
pwsh -NoProfile -File .\scripts\sync-cli-profiles.ps1 -Execute     # aplica
```

O mesmo mapa descreve as rotas por pasta, as zonas sem blindagem e as abas do
Windows Terminal. Aba que chama um comando aposentado não dá erro visível: ela
abre, o shell reclama de comando desconhecido, e quem descobre é você no pior
momento. Por isso as abas saem do mapa que gera os comandos, e não de uma edição
paralela do `settings.json`.

Garantias que o script mantém:

- dry-run é o padrão; `-Execute` faz backup datado antes de escrever, e recusa o
  resultado se o perfil gerado não passar no parser;
- só a região entre os marcadores é reescrita. Função escrita à mão continua
  onde está, e alias duplicado fora da região é apenas relatado — a decisão de
  remover é sua;
- bloco antigo declarado em `legacyRegions` é removido junto, para não sobrar
  definição duplicada do mesmo comando: duas definições não quebram o shell, mas
  escondem qual delas está no ar;
- no `settings.json` do Terminal, só perfis cujo GUID está em
  `terminal.managedGuids` são tocados. GUID declarado ali e ausente de
  `terminal.tabs` é uma aba aposentada, e some; qualquer outro perfil fica como
  está. Se o arquivo tiver comentário — o Terminal aceita, `ConvertFrom-Json`
  não — o script avisa e não mexe, em vez de apagar a anotação;
- o script em si nunca abre `.credentials.json`. O código gerado abre, quando o
  mapa pede: veja **Um login por conta** abaixo.
- a saída é ASCII puro, porque perfil sem BOM é lido como ANSI pelo 5.1;
- o alvo é sempre um perfil de host descoberto em runtime, nunca um caminho
  arbitrário;
- `-BlockOutPath` grava só o bloco gerado num arquivo à parte, para revisar ou
  testar antes de encostar em qualquer perfil.

Perfil novo é uma linha no mapa e uma nova execução. Para o antimalware nada
precisa ser declarado duas vezes: `scripts\report-exclusion-coverage.ps1`
descobre os diretórios pela mesma convenção de nome, então um perfil recém-criado
já aparece no relatório de cobertura como exposto.

`scripts\perfis-cli.example.json` mostra o formato do mapa com dados sintéticos.

### Por que um mapa, e não leitura direta

A descoberta por convenção acha o diretório de estado, e é assim que
`-Bootstrap` funciona. Ela não consegue derivar três coisas:

- **o nome do atalho** — `.claude-perfil-b` daria `cc-perfil-b`, mas quem usa pode
  querer `cc-b`, e um rótulo curto para exibir no prompt não está escrito em lugar
  nenhum no nome da pasta;
- **a intenção** — parte dos diretórios não deve virar atalho. Perfil acionado
  por um `.cmd`, escopo abandonado e diretório de outra ferramenta continuam
  existindo no disco;
- **a estabilidade** — se o conjunto fosse recalculado a cada execução, seu
  perfil mudaria sozinho quando um diretório aparecesse, e um atalho
  desapareceria quando um repositório não estivesse clonado.

Ler o próprio perfil do shell também não serve como fonte: são dois arquivos que
podem discordar, e é justamente essa discordância que se quer eliminar. Qual dos
dois seria a verdade?

Então a divisão é: descoberta avisa, mapa decide. `-Report` compara o mapa com o
disco e lista o que ainda não tem decisão, sem gerar nada:

```powershell
pwsh -NoProfile -File .\scripts\sync-cli-profiles.ps1 -Report
```

As raízes observadas saem do próprio mapa — quem declarou um perfil numa pasta
quer que ela continue sob observação. Um diretório novo aparece como pendência
com o alias que ele *teria*; entra em `profiles` para virar atalho, ou em
`ignore` para registrar que a ausência de atalho é deliberada. O relatório também
avisa quando um perfil declarado deixou de existir no disco.

## Adicionando outra CLI

1. Prefira suporte nativo a `AGENTS.md`.
2. Se a CLI exigir outro nome, crie um adaptador que importe `AGENTS.md`.
3. Não copie o contrato completo.
4. Atualize `tests\Test-PublicSurface.ps1` e esta tabela.
