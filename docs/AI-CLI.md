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

## Adicionando outra CLI

1. Prefira suporte nativo a `AGENTS.md`.
2. Se a CLI exigir outro nome, crie um adaptador que importe `AGENTS.md`.
3. Não copie o contrato completo.
4. Atualize `tests\Test-PublicSurface.ps1` e esta tabela.
