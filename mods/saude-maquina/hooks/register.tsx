import { atom, read, update } from 'claude-code'
import type { Register } from 'claude-code'

import type { Leitura, Saude } from '../types'

// Vermelho = os limites do AGENTS.md que barram uma limpeza. Amarelo = perto deles
// (o 65% de commit e o nivel 1 do painel de pressao).
const VERMELHO = { commitPct: 80, ramLivreGB: 4, discoLivreGB: 5, terminalPrivGB: 4, terminalWsGB: 2 }
const AMARELO = { commitPct: 65, ramLivreGB: 6, discoLivreGB: 15, terminalPrivGB: 3, terminalWsGB: 1.5 }

// Uma leitura vale 30 s para todas as sessoes: a que achar o cache vencido mede de novo.
const VALIDADE_MS = 30_000
const VELHA_MS = 120_000
const CACHE = 'gerenciador-saude-maquina.json'

const saude = atom({ plugin: 'saude-maquina', key: 'saude' } as const, null)

type Cor = 'error' | 'warning' | undefined

function acima(valor: number | null, amarelo: number, vermelho: number): Cor {
  if (valor === null) return undefined
  return valor > vermelho ? 'error' : valor >= amarelo ? 'warning' : undefined
}

function abaixo(valor: number | null, amarelo: number, vermelho: number): Cor {
  if (valor === null) return undefined
  return valor < vermelho ? 'error' : valor < amarelo ? 'warning' : undefined
}

function pior(a: Cor, b: Cor): Cor {
  return a === 'error' || b === 'error' ? 'error' : a ?? b
}

function gb(valor: number | null, casas: number): string {
  return valor === null ? '?' : `${valor.toFixed(casas).replace('.', ',')} GB`
}

function numero(v: unknown): number | null {
  return typeof v === 'number' && Number.isFinite(v) ? v : null
}

function interpretar(texto: string): Leitura | null {
  try {
    const d = JSON.parse(texto.trim().split(/\r?\n/).pop() ?? '') as Record<string, unknown>
    if (d.v !== 1 || typeof d.em !== 'number') return null
    return {
      v: 1,
      em: d.em,
      commitPct: numero(d.commitPct),
      ramLivreGB: numero(d.ramLivreGB),
      disco: typeof d.disco === 'string' && /^[A-Za-z]:$/.test(d.disco) ? d.disco : '?',
      discoLivreGB: numero(d.discoLivreGB),
      terminalPrivGB: numero(d.terminalPrivGB),
      terminalWsGB: numero(d.terminalWsGB),
    }
  } catch {
    return null
  }
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const iniciada = await next(e)
    if ((await $.env.get('OS')) !== 'Windows_NT') return iniciada
    const temp = await $.env.get('TEMP')
    if (!temp) return iniciada
    const cache = `${temp.replace(/[\\/]+$/, '')}\\${CACHE}`
    const coletor = `${$.plugin.root}\\coletor\\coletar.ps1`

    const atualizar = async () => {
      let leitura: Leitura | null = null
      try {
        leitura = interpretar(await $.fs.read(cache))
      } catch {
        leitura = null
      }
      if (leitura === null || (await $.clock.now()) - leitura.em > VALIDADE_MS) {
        try {
          const r = await $.process.run(
            ['pwsh.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', coletor, '-Cache', cache],
            { timeoutMs: 20_000 },
          )
          if (r.exitCode === 0) leitura = interpretar(r.stdout) ?? leitura
        } catch {
          // coletor nao rodou: fica a leitura anterior, marcada como velha adiante
        }
      }
      if (leitura === null) return
      const velha = (await $.clock.now()) - leitura.em > VELHA_MS
      const nova: Saude = { leitura, velha }
      await update($, saude, () => nova)
    }

    void atualizar().catch(() => undefined)
    $.clock.every(VALIDADE_MS, () => {
      void atualizar().catch(() => undefined)
    })
    return iniciada
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.props.hasSurvey) return next(e)
    const atual = await read($, saude)
    if (atual === null) return next(e)
    const l = atual.leitura
    const { Box, Text } = $.ui.resolve(e)

    const commit = acima(l.commitPct, AMARELO.commitPct, VERMELHO.commitPct)
    const ram = abaixo(l.ramLivreGB, AMARELO.ramLivreGB, VERMELHO.ramLivreGB)
    const disco = abaixo(l.discoLivreGB, AMARELO.discoLivreGB, VERMELHO.discoLivreGB)
    const terminal = pior(
      acima(l.terminalPrivGB, AMARELO.terminalPrivGB, VERMELHO.terminalPrivGB),
      acima(l.terminalWsGB, AMARELO.terminalWsGB, VERMELHO.terminalWsGB),
    )
    const geral = [commit, ram, disco, terminal].reduce<Cor>(pior, undefined)
    const rotulo = geral === 'error' ? 'maquina no limite do AGENTS.md' : 'maquina'

    return (
      <Box>
        <Text color={geral} dimColor={geral === undefined}>{rotulo} · </Text>
        <Text color={commit} dimColor={commit === undefined}>
          commit {l.commitPct === null ? '?' : `${Math.round(l.commitPct)}%`}
        </Text>
        <Text dimColor> · </Text>
        <Text color={ram} dimColor={ram === undefined}>RAM {gb(l.ramLivreGB, 1)}</Text>
        <Text dimColor> · </Text>
        <Text color={disco} dimColor={disco === undefined}>
          {l.disco} {gb(l.discoLivreGB, 0)} livres
        </Text>
        <Text dimColor> · </Text>
        <Text color={terminal} dimColor={terminal === undefined}>Terminal {gb(l.terminalPrivGB, 1)}</Text>
        {atual.velha ? <Text color="warning"> · leitura parada</Text> : null}
      </Box>
    )
  })
}
