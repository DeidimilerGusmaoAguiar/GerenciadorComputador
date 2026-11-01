# Claude Code: barra de status, faixa de saúde e guarda de comandos

Três peças para quem roda várias sessões do Claude Code na mesma máquina Windows.
Cada uma é opcional. Nenhuma altera o host: elas mostram, ou pedem confirmação.

| Peça | O que faz | Onde vale |
|---|---|---|
| Barra de status (`scripts/statusline.py`) | Plano, nome da sessão, modelo, pasta, contexto e cota de 5 h e 7 dias | Toda sessão de um diretório de estado configurado, menos a de projeto com barra própria |
| Faixa de saúde (`mods/saude-maquina`) | Commit, RAM disponível, disco do sistema e memória do Windows Terminal, acima do prompt | Toda sessão que carregar o mod |
| Guarda de comandos (`mods/guarda-comandos`) | Pergunta antes de encerrar processo, desligar WSL/Docker/máquina ou apagar recursivo fora das pastas de trabalho; recusa os comandos proibidos do `AGENTS.md` | Toda sessão que carregar o mod, menos nas pastas marcadas como fora |

## Barra de status

`scripts/statusline.py` lê o JSON que a CLI entrega e escreve uma linha:

```text
DEV BLINDADO · limpeza · Opus 5.5 · GerenciadorComputador · ctx 42% · 5h 73% ate 15:20 · 7d 36% ate 05/11 01h
```

Contexto e cota ficam amarelos a partir de 70% e vermelhos a partir de 90%. É Python,
não PowerShell, por custo: a CLI roda o comando a cada atualização da conversa, em cada
sessão. Numa máquina com cinco sessões, `pwsh -NoProfile` custou ~280 ms por chamada e
`python` ~47 ms.

`scripts/set-statusline.ps1` grava a barra no `settings.json` de cada diretório de estado
do mapa de perfis (`local\perfis-cli.json`), com o rótulo e a cor de cada plano. Sem
`-Execute`, só mostra o atual e o novo. Com `-Execute`, guarda o anterior como
`settings.json.antes-statusline-<data>` e grava por troca atômica.

```powershell
pwsh -NoProfile -File .\scripts\set-statusline.ps1
pwsh -NoProfile -File .\scripts\set-statusline.ps1 -Execute
```

Um projeto com `statusLine` no próprio `.claude/settings.json` continua com a dele, porque a
configuração do projeto vence a do usuário.

## Mods

Um mod é um plugin de hooks em TypeScript que roda dentro do Claude Code. Os dois daqui
vivem em `mods/` e se testam sem sessão:

```powershell
claude plugin validate .\mods\guarda-comandos
claude plugin test .\mods\guarda-comandos
claude plugin test .\mods\saude-maquina
```

Para carregar:

- **Uma sessão de teste:** `claude --plugin-dir .\mods\guarda-comandos --plugin-dir .\mods\saude-maquina`.
- **Todas as sessões:** a variável `CLAUDE_CODE_PLUGIN_DIRS`, com as pastas separadas por
  `;`, no ambiente do processo ou no bloco `env` do `settings.json` do usuário (nunca no do
  projeto).

Leve aos poucos: primeiro uma aba de teste, depois uma sessão de trabalho, e só então todas.
Um mod não roda em sandbox, e uma guarda com defeito atinge todas as sessões que a carregam.

### Faixa de saúde (`saude-maquina`)

Uma linha acima do prompt:

```text
maquina · commit 72% · RAM 11,9 GB · C: 477 GB livres · Terminal 0,3 GB
```

Fica vermelha nos limites que barram uma limpeza no `AGENTS.md`, e o rótulo passa a ser
"maquina no limite do AGENTS.md":
- menos de 5 GB livres;
- menos de 4 GB de RAM disponível;
- commit acima de 80%;
- Windows Terminal acima de 4 GB privados ou de 2 GB de working set.

Fica amarela perto deles: 15 GB, 6 GB, 65% de commit, 3 GB ou 1,5 GB.

O coletor (`mods/saude-maquina/coletor/coletar.ps1`) usa as mesmas fontes do painel de
pressão e grava a leitura em `%TEMP%\gerenciador-saude-maquina.json`. A leitura vale 30
segundos para todas as sessões: a que encontra o cache vencido mede de novo (~0,5 s de CPU).
Uma leitura que falha aparece como `?` e nunca acende alarme. Se o coletor parar, a faixa
avisa "leitura parada".

### Guarda de comandos (`guarda-comandos`)

Ela age nas ferramentas Bash e PowerShell, depois das regras do `settings.json` e dos hooks
`PreToolUse`. Só endurece o veredito, nunca o afrouxa.

| Comando | Decisão |
|---|---|
| `Stop-Process` (e `kill`/`spps` no PowerShell), `taskkill`, `wsl --shutdown`, `docker desktop stop`, `Restart-Computer`, `Stop-Computer`, `shutdown /…` | pergunta |
| `Remove-Item -Recurse`, `rm -r`, `rd /s` com alvo literal fora das pastas de trabalho, ou na pasta do usuário | pergunta |
| `format X:`, `diskpart … clean`, `cipher /w`, `vssadmin delete shadows /all` | recusa |

A pergunta de um mod chega à pessoa mesmo com `--dangerously-skip-permissions`. Onde
ninguém pode responder, como num subagente em segundo plano ou num `claude -p`, a CLI recusa
a chamada.

Opções, gravadas no `settings.json` em `pluginConfigs`:

```json
"pluginConfigs": {
  "guarda-comandos": {
    "options": {
      "pastasTrabalho": "C:/Repos;C:/Projetos",
      "pastasFora": "C:/Repos/um-repo-com-guarda-propria"
    }
  }
}
```

- `pastasTrabalho`: apagar recursivo dentro delas não pergunta. A pasta do projeto da
  sessão e o `%TEMP%` contam sempre.
- `pastasFora`: uma sessão aberta dentro delas fica sem a guarda. Serve para um repositório
  que já tem a própria.

Limites: é cinto de segurança para comando digitado, não fronteira. Um script que encerra
processo por dentro passa sem ser visto, e caminho em variável não é julgado. Texto que só
menciona um comando, num `grep` ou num `echo`, também pode provocar a pergunta.

### Regras nativas, sem mod

O `.claude/settings.json` deste repositório já pede confirmação (`ask`) e recusa (`deny`) os
mesmos comandos nas duas ferramentas. Num teste com `claude -p --dangerously-skip-permissions`,
a regra `ask` barrou um `Stop-Process`: as regras nativas valem mesmo com as permissões
puladas. O mod existe para levar a guarda a pastas sem essas regras, deixando de fora quem
tem guarda própria, o que uma regra no nível do usuário não consegue fazer.

### Modo `auto` não substitui a guarda

Num teste com `claude -p --permission-mode auto`, o classificador deixou passar um
`Stop-Process`. O `Remove-Item -Recurse` na raiz do disco foi barrado pela proteção própria
da ferramenta, não pelo classificador.
