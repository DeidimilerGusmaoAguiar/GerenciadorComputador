// Uma leitura do coletor/coletar.ps1. null = a leitura falhou, nunca zero.
export type Leitura = {
  v: 1
  em: number
  commitPct: number | null
  ramLivreGB: number | null
  disco: string
  discoLivreGB: number | null
  terminalPrivGB: number | null
  terminalWsGB: number | null
}

// velha: a ultima leitura tem mais de dois minutos (o coletor esta falhando).
export type Saude = { leitura: Leitura; velha: boolean }

declare module 'claude-code' {
  interface PluginState {
    'saude-maquina': { saude: Saude | null }
  }
}
