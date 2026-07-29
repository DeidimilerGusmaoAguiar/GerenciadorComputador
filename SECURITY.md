# Segurança

Este projeto inspeciona um computador Windows e contém scripts capazes de
remover arquivos ou alterar a configuração do System Restore quando
explicitamente habilitados. Trate mudanças nesses fluxos como código de alto
impacto.

## Relatando uma vulnerabilidade

Não abra uma issue pública com credenciais, relatórios da máquina, caminhos de
usuário ou comandos de startup. Quando o repositório estiver hospedado no
GitHub, use um **Private Vulnerability Report** ou contate os mantenedores por
um canal privado definido no perfil do projeto.

Inclua uma reprodução mínima com dados sintéticos. Nunca anexe conteúdo real
de `reports\` ou `quarantine\`.

## Regras para scripts mutáveis

Um script que altera o sistema deve:

1. operar em dry-run por padrão;
2. exigir um switch explícito como `-Execute`;
3. implementar `SupportsShouldProcess` e respeitar `-WhatIf`;
4. validar caminhos absolutos e recusar reparse points;
5. limitar a operação a uma raiz declarada;
6. registrar o plano e o resultado sem capturar segredos;
7. preservar Windows Terminal, shells e CLIs como Codex, Claude, Gemini, Grok
   e OpenCode, além de Docker e WSL, salvo aprovação nominal para a árvore
   exata no executor dedicado;
8. interromper no primeiro sinal de degradação ou perda de PID protegido.

Não aceite mudanças que desativem Defender, Windows Update, System Restore,
SmartScreen ou outras proteções por padrão.

### Exceção nominal para CLI órfã

O único encerramento de processo permitido no código público fica em
`scripts\stop-pressure-cli-session.ps1`. Ele deve continuar:

- desativado no servidor por padrão;
- limitado a CLI fora do Terminal e sem pai vivo validado;
- protegido por confirmação, `PID + horário de início`, quantidade e
  impressão da árvore;
- impedido de atingir o PID ou a linhagem do próprio dashboard;
- protegido por `SupportsShouldProcess`, `-Execute` e IDs explícitos;
- recusado quando a composição mudar ou o host entrar em emergência.

Não mova `Stop-Process` para o servidor HTTP nem aceite nome, wildcard ou
árvore recalculada depois da aprovação como substituto da identidade exata.

## Privacidade

Relatórios podem conter:

- nomes de usuário e computador;
- SIDs e caminhos completos;
- aplicativos instalados e comandos de startup;
- nomes de processos, containers e projetos;
- endereços IP e caminhos UNC.

Por isso, `reports\`, `quarantine\` e `local\` são ignorados pelo Git. Exemplos
versionados devem usar somente dados sintéticos.
