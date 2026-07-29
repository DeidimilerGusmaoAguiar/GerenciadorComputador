@AGENTS.md

# Adaptador para Claude Code

O import acima é a fonte canônica do projeto. Não replique suas regras neste
arquivo. Instruções abaixo são apenas integrações específicas do Claude Code.

## Configuração local do repositório

- `.claude/settings.json` adiciona prompts e bloqueios de segurança. Uma
  permissão técnica nunca substitui a aprovação explícita exigida por
  `AGENTS.md`.
- Não altere `~/.claude`, skills globais ou preferências pessoais para concluir
  uma tarefa deste repositório.
- Confirme o contexto carregado com `/context` quando houver dúvida.

## Subagentes disponíveis

| Agente | Uso | Modo esperado |
|---|---|---|
| `disk-investigator` | Mapear consumo de disco | somente leitura |
| `disk-cleaner` | Executar limpeza já aprovada | escrita com gating |
| `performance-analyst` | Diagnosticar CPU, RAM e I/O | somente leitura |
| `startup-auditor` | Auditar inicialização | escrita com gating |
| `bloatware-hunter` | Inventariar aplicativos removíveis | escrita com gating |
| `restore-guardian` | Criar checkpoint e orientar reversão | escrita controlada |

Todos os subagentes continuam sujeitos a `AGENTS.md`. `permissionMode`,
frontmatter ou configuração de ferramenta não ampliam o escopo autorizado pelo
usuário.
