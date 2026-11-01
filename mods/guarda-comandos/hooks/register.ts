import type { Register } from 'claude-code'

// Guarda das ferramentas Bash e PowerShell. Roda em tool.check, depois das
// regras do settings.json e dos hooks PreToolUse: so endurece o veredito. Um
// "ask" de plugin vai para a pessoa mesmo com --dangerously-skip-permissions;
// onde ninguem pode responder (subagente em segundo plano, claude -p) a CLI
// recusa a chamada.
//
// E cinto de seguranca para comando digitado, nao fronteira: um script que
// encerra processo por dentro passa sem ser visto, e caminho em variavel nao e
// julgado.

// As pastas desta maquina vem das opcoes do mod (userConfig), gravadas no
// settings.json em pluginConfigs: pastasTrabalho, onde apagar recursivo nao
// pergunta, e pastasFora, repositorios com guarda propria onde este mod nao atua.
// A pasta do projeto da sessao e o %TEMP% contam sempre como pastas de trabalho.

type Julgamento = { decision: 'ask' | 'deny'; reason: string }

// AGENTS.md, seguranca para mudancas no host, item 8: nunca.
const PROIBIDOS: [RegExp, string][] = [
  [/\bformat(\.com)?\s+[a-z]:/i, 'format de volume'],
  [/\bcipher(\.exe)?\s+\/w\b/i, 'cipher /w'],
  [/\bvssadmin(\.exe)?\s+delete\s+shadows\b[^\n]*\/all\b/i, 'vssadmin delete shadows /all'],
]

// AGENTS.md, gate critico de Terminal e CLIs: so com autorizacao nominal.
const PERGUNTAR: [RegExp, string][] = [
  [/\bStop-Process\b/i, 'Stop-Process encerra processo'],
  [/\btaskkill(\.exe)?\b/i, 'taskkill encerra processo'],
  [/\bwsl(\.exe)?\b[^\n;|&]*\s--shutdown\b/i, 'wsl --shutdown derruba o WSL e o Docker'],
  [/\bdocker(\.exe)?\s+desktop\s+stop\b/i, 'docker desktop stop derruba o Docker'],
  [/\bRestart-Computer\b/i, 'Restart-Computer reinicia a maquina'],
  [/\bStop-Computer\b/i, 'Stop-Computer desliga a maquina'],
  [/\bshutdown(\.exe)?\s+[/-]/i, 'shutdown desliga ou reinicia a maquina'],
]
// Apelidos de Stop-Process no PowerShell.
const PERGUNTAR_PS: [RegExp, string][] = [
  [/(^|[\s;|&({])(spps|kill)(\s|$)/i, 'kill/spps e Stop-Process: encerra processo'],
]

function normalizar(caminho: string): string | null {
  let s = caminho.trim()
  const posix = /^\/([a-zA-Z])(\/|$)(.*)$/.exec(s)
  if (posix) s = `${posix[1]}:\\${posix[3]}`
  s = s.replace(/\//g, '\\')
  if (!/^[a-zA-Z]:(\\|$)/.test(s)) return null
  const partes: string[] = []
  for (const parte of s.slice(2).split('\\')) {
    if (!parte || parte === '.') continue
    if (parte === '..') partes.pop()
    else partes.push(parte)
  }
  return `${s.slice(0, 2)}\\${partes.join('\\')}`.toLowerCase()
}

function dentro(caminho: string, raiz: string): boolean {
  const r = raiz.replace(/\\+$/, '')
  return caminho === r || caminho.startsWith(`${r}\\`)
}

function tokens(trecho: string): string[] {
  const saida: string[] = []
  for (const m of trecho.matchAll(/"([^"]*)"|'([^']*)'|(\S+)/g)) saida.push(m[1] ?? m[2] ?? m[3] ?? '')
  return saida
}

const APAGA_PS = /(^|[\s;|&({])(Remove-Item|ri|rd|rmdir|del|erase|rm)\s/i
const RECURSO_PS = /\s-r(e(c(u(r(s(e)?)?)?)?)?)?(\s|:|$)/i
const APAGA_CMD = /(^|[\s;|&(])(rd|rmdir)\s+[^\n]*\/s\b/i
const APAGA_SH = /(^|[\s;|&(])rm\s+(-[a-zA-Z]*[rR][a-zA-Z]*|--recursive)(\s|$)/
const CASA = /^(~|\$HOME\b|\$env:(USERPROFILE|HOMEPATH|HOMEDRIVE)\b|%(USERPROFILE|HOMEPATH)%)/i
const TEMPORARIO = /^(\$env:(TEMP|TMP)\b|%(TEMP|TMP)%|\$\{?(TEMP|TMP|TMPDIR)\}?\b|\/tmp(\/|$))/i
const COMANDO = /^(&|Remove-Item|ri|rd|rmdir|del|erase|rm|cmd(\.exe)?|\/c)$/i

// Apagar recursivo: pergunta quando um alvo LITERAL cai fora das raizes e do
// %TEMP%, ou e a pasta do usuario. Alvo relativo vale a partir da pasta da sessao.
function apagaFora(trecho: string, pasta: string, raizes: string[]): string | null {
  const recursivo =
    (APAGA_PS.test(trecho) && RECURSO_PS.test(trecho)) || APAGA_CMD.test(trecho) || APAGA_SH.test(trecho)
  if (!recursivo) return null
  for (const t of tokens(trecho)) {
    if (!t || t.startsWith('-') || COMANDO.test(t) || /^\/[a-z]$/i.test(t)) continue
    if (/^\d?[<>]/.test(t) || /^(\/dev\/null|nul|\$null)$/i.test(t)) continue // redirecionamento
    if (TEMPORARIO.test(t)) continue
    if (CASA.test(t)) return t
    if (/[$%`]/.test(t)) continue // variavel: nao da para julgar pelo texto
    const absoluto = normalizar(t) ?? (/^[\\/]/.test(t) ? null : normalizar(`${pasta}\\${t}`))
    if (absoluto === null) return t // caminho POSIX fora de /c/... ou /tmp, como /var/log
    if (!raizes.some(r => dentro(absoluto, r))) return t
  }
  return null
}

function lista(valor: unknown): string[] {
  if (typeof valor !== 'string') return []
  return valor
    .split(';')
    .map(p => normalizar(p))
    .filter((p): p is string => p !== null)
}

export function julgar(tool: string, comando: string, pasta: string, raizes: string[]): Julgamento | null {
  for (const [re, porque] of PROIBIDOS) if (re.test(comando)) return { decision: 'deny', reason: `${porque}: proibido pelo AGENTS.md` }
  if (/\bdiskpart\b/i.test(comando) && /\bclean\b/i.test(comando)) {
    return { decision: 'deny', reason: 'diskpart clean: proibido pelo AGENTS.md' }
  }
  const lista = tool === 'PowerShell' ? [...PERGUNTAR, ...PERGUNTAR_PS] : PERGUNTAR
  for (const [re, porque] of lista) if (re.test(comando)) return { decision: 'ask', reason: `${porque}. Autoriza?` }
  const base = normalizar(pasta) ?? pasta.toLowerCase()
  for (const trecho of comando.split(/\r?\n|;|&&|\|\||\|/)) {
    const alvo = apagaFora(trecho, base, raizes)
    if (alvo !== null) {
      return { decision: 'ask', reason: `apagar recursivo fora das pastas de trabalho (${alvo.slice(0, 120)}). Autoriza?` }
    }
  }
  return null
}

export const register: Register = (on, options) => {
  const fora = lista(options.pastasFora)
  const trabalho = lista(options.pastasTrabalho)
  for (const tool of ['Bash', 'PowerShell'] as const) {
    on('tool.check', { tool }, async ($, e, next) => {
      const veredito = await next(e)
      if (veredito.decision === 'deny') return veredito
      const comando = (e.input as { command?: unknown } | null)?.command
      if (typeof comando !== 'string') return veredito
      const pasta = await $.session.cwd()
      const pastaNorm = normalizar(pasta)
      if (pastaNorm && fora.some(f => dentro(pastaNorm, f))) return veredito
      const raizes = [...trabalho, ...lista(await $.session.root()), ...lista(await $.env.get('TEMP'))]
      const julgamento = julgar(e.tool, comando, pasta, raizes)
      if (!julgamento) return veredito
      return { decision: julgamento.decision, reason: `${$.plugin.name}: ${julgamento.reason}` }
    }).catch(() => ({ decision: 'ask', reason: 'guarda-comandos falhou ao julgar esta chamada. Autoriza?' }))
  }
}
