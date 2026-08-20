# Contribuindo

Contribuições são bem-vindas, especialmente melhorias de diagnóstico,
portabilidade e segurança.

## Antes de enviar

1. Não inclua relatórios reais, exports de registro ou arquivos em quarentena.
2. Remova nomes de usuário, empresa, projeto, host, compartilhamento e caminho
   local do código e dos testes.
3. Use `$PSScriptRoot`, parâmetros ou variáveis de ambiente para localizar
   recursos.
4. Mantenha toda coleta somente leitura separada das ações mutáveis.
5. Execute:

```powershell
pwsh -NoProfile -File .\tests\Test-PublicSurface.ps1
```

6. Ative o hook de `pre-push` uma vez por clone, para que essa conferência
   rode sozinha antes de cada push. Hook não viaja no clone:

```powershell
git config core.hooksPath .githooks
```

A conferência inclui nomes de máquina e termos internos lidos de `local\`,
que o Git ignora — a lista de termos proibidos não pode ela mesma ser
publicada. Sem esses arquivos a suíte confere apenas o host atual, e informa
em `LocalTermSources` de onde tirou a lista.

## Scripts que alteram o sistema

Novos scripts mutáveis devem ter:

- `[CmdletBinding(SupportsShouldProcess)]`;
- dry-run por padrão;
- `-Execute` explícito;
- suporte funcional a `-WhatIf`;
- validação da raiz e dos alvos;
- rejeição de reparse points;
- logs locais ignorados pelo Git;
- documentação `.SYNOPSIS`, `.DESCRIPTION` e `.EXAMPLE`.

Não use `Stop-Process`, `taskkill`, `wsl --shutdown`, prune genérico do Docker
ou parada de serviço para facilitar uma limpeza. Se uma operação realmente
depender disso, ela deve apenas apresentar o plano e exigir autorização
nominal do operador.

## Instruções para agentes de IA

Edite regras compartilhadas somente em `AGENTS.md`. `CLAUDE.md` e `GEMINI.md`
são adaptadores curtos e devem continuar importando a fonte canônica. O Grok
Build e o Codex leem `AGENTS.md` diretamente.

Não adicione ao repositório chaves de API, modelo padrão, conta, caminho de
perfil ou dependência de uma skill instalada globalmente.

## Commits e pull requests

- Faça mudanças pequenas e revisáveis.
- Explique risco, reversibilidade e comportamento de dry-run.
- Inclua testes com dados sintéticos.
- Não force a inclusão de arquivos ignorados.

## Licenciamento

Ao contribuir, você concorda que sua contribuição será disponibilizada sob a
licença MIT do projeto. Confirme antes que você possui autorização para
publicar código produzido em ambiente corporativo.
