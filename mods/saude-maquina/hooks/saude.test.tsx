import { expect, test } from 'claude-code/testing'

const FAIXA = {
  plugin: 'saude-maquina',
  component: 'AbovePrompt',
  props: {
    hasSurvey: false,
    isWorking: false,
    maxRows: 10,
    bodyColumns: 120,
    scroll: { offset: 0, bodyRows: 10 },
    view: {},
  },
} as const

const NORMAL = {
  v: 1, em: 1_000, commitPct: 50.2, ramLivreGB: 11.86, disco: 'C:', discoLivreGB: 476.8,
  terminalPrivGB: 0.32, terminalWsGB: 0.07,
}

function semear(on: Parameters<Parameters<typeof test>[1]>[1], saude: unknown) {
  on('state.get', () => ({ value: { value: saude, version: 1 } }))
}

// A primeira coleta roda solta, para nao atrasar a abertura da sessao: monta a faixa ate a
// leitura aparecer, com o motor desenhando por baixo enquanto ela nao chega.
function motorDesenha(on: Parameters<Parameters<typeof test>[1]>[1]) {
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>motor</Text>
  })
}

async function commitDesenhado($: Parameters<Parameters<typeof test>[1]>[0]): Promise<string | undefined> {
  for (let i = 0; i < 100; i++) {
    const ui = await $.ui.mount({ ...FAIXA, surface: 'terminal' })
    const texto = (await ui.find({ type: 'Text', text: /^commit/ }))?.text
    await ui.unmount()
    if (texto) return texto
  }
  return undefined
}

test('leitura normal: uma linha esmaecida com os quatro numeros', async ($, on) => {
  semear(on, { leitura: NORMAL, velha: false })
  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ ...FAIXA, surface })
    expect((await ui.find({ type: 'Text', text: /^commit/ }))?.text).toBe('commit 50%')
    expect((await ui.find({ type: 'Text', text: /^RAM/ }))?.text).toBe('RAM 11,9 GB')
    expect((await ui.find({ type: 'Text', text: /livres/ }))?.text).toBe('C: 477 GB livres')
    expect((await ui.find({ type: 'Text', text: /^Terminal/ }))?.text).toBe('Terminal 0,3 GB')
    expect((await ui.find({ type: 'Text', text: /^maquina/ }))?.props.dimColor).toBe(true)
    await ui.unmount()
  }
})

test('acima dos limites do AGENTS.md: vermelho e rotulo de alerta', async ($, on) => {
  semear(on, {
    leitura: { ...NORMAL, commitPct: 83, ramLivreGB: 5.1, discoLivreGB: 4.2, terminalWsGB: 2.5 },
    velha: false,
  })
  const ui = await $.ui.mount({ ...FAIXA, surface: 'terminal' })
  expect((await ui.find({ type: 'Text', text: /^commit/ }))?.props.color).toBe('error')
  expect((await ui.find({ type: 'Text', text: /^RAM/ }))?.props.color).toBe('warning')
  expect((await ui.find({ type: 'Text', text: /livres/ }))?.props.color).toBe('error')
  expect((await ui.find({ type: 'Text', text: /^Terminal/ }))?.props.color).toBe('error')
  expect((await ui.find({ type: 'Text', text: /^maquina/ }))?.text).toBe('maquina no limite do AGENTS.md · ')
  await ui.unmount()
})

test('leitura que falhou mostra "?" e nunca alarma', async ($, on) => {
  semear(on, {
    leitura: { ...NORMAL, commitPct: null, ramLivreGB: null, discoLivreGB: null, terminalPrivGB: null, terminalWsGB: null },
    velha: true,
  })
  const ui = await $.ui.mount({ ...FAIXA, surface: 'terminal' })
  const commit = await ui.find({ type: 'Text', text: /^commit/ })
  expect(commit?.text).toBe('commit ?')
  expect(commit?.props.color).toBeUndefined()
  expect((await ui.find({ type: 'Text', text: /^RAM/ }))?.text).toBe('RAM ?')
  expect((await ui.find({ type: 'Text', text: /parada/ }))?.props.color).toBe('warning')
  await ui.unmount()
})

test('sem leitura ainda, a faixa fica com o motor', async ($, on) => {
  semear(on, null)
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>motor</Text>
  })
  const ui = await $.ui.mount({ ...FAIXA, surface: 'terminal' })
  expect((await ui.find({ type: 'Text', text: /motor/ }))?.text).toBe('motor')
  await ui.unmount()
})

test('na abertura da sessao, cache vencido: roda o coletor e desenha o que ele mediu', async ($, on) => {
  const rodou: string[][] = []
  on('env.get', (_, e) => ({ value: e.name === 'OS' ? 'Windows_NT' : e.name === 'TEMP' ? 'C:\\T' : undefined }))
  on('fs.read', () => ({ value: JSON.stringify({ ...NORMAL, em: 0 }) }))
  on('clock.now', () => ({ value: 100_000 }))
  on('clock.every', () => ({ deny: 'sem intervalo no teste' }))
  on('process.run', (_, e) => {
    rodou.push([...e.argv])
    return { value: { exitCode: 0, stdout: JSON.stringify({ ...NORMAL, em: 99_000, commitPct: 81 }), stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  motorDesenha(on)

  await $.session.start({ cwd: 'C:\\Projetos\\X', surface: 'terminal', isInteractive: true })
  expect(await commitDesenhado($)).toBe('commit 81%')
  expect(rodou.length).toBe(1)
  expect(rodou[0]?.slice(-2)).toEqual(['-Cache', 'C:\\T\\gerenciador-saude-maquina.json'])
})

test('cache ainda valido: nao roda o coletor', async ($, on) => {
  let rodou = 0
  on('env.get', (_, e) => ({ value: e.name === 'OS' ? 'Windows_NT' : e.name === 'TEMP' ? 'C:\\T' : undefined }))
  on('fs.read', () => ({ value: JSON.stringify({ ...NORMAL, em: 90_000 }) }))
  on('clock.now', () => ({ value: 100_000 }))
  on('clock.every', () => ({ deny: 'sem intervalo no teste' }))
  on('process.run', () => {
    rodou++
    return { value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  motorDesenha(on)

  await $.session.start({ cwd: 'C:\\Projetos\\X', surface: 'terminal', isInteractive: true })
  expect(await commitDesenhado($)).toBe('commit 50%')
  expect(rodou).toBe(0)
})
