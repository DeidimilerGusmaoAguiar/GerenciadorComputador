import { expect, test } from 'claude-code/testing'

const TEMP = 'C:\\Users\\Fulano\\AppData\\Local\\Temp'
const OPCOES = { options: { pastasTrabalho: 'C:\\Repos;C:\\Projetos', pastasFora: 'C:\\Repos\\outro-com-guarda' } }

type On = Parameters<Parameters<typeof test>[2]>[1]
type Caso = [tool: 'Bash' | 'PowerShell', comando: string, esperado: 'allow' | 'ask' | 'deny']

const CASOS: Caso[] = [
  ['PowerShell', 'Get-Process | Sort-Object CPU', 'allow'],
  ['PowerShell', 'Stop-Process -Id 1234', 'ask'],
  ['PowerShell', 'kill 1234', 'ask'],
  ['PowerShell', 'Get-Process pwsh | spps', 'ask'],
  ['Bash', 'taskkill //F //PID 1234', 'ask'],
  ['Bash', 'wsl.exe -d Ubuntu --shutdown', 'ask'],
  ['PowerShell', 'wsl --shutdown', 'ask'],
  ['Bash', 'docker desktop stop', 'ask'],
  ['PowerShell', 'Restart-Computer -Force', 'ask'],
  ['PowerShell', 'Stop-Computer', 'ask'],
  ['Bash', 'shutdown /r /t 0', 'ask'],
  ['Bash', 'format D: /q', 'deny'],
  ['Bash', 'echo select disk 1 > s.txt; diskpart /s s.txt; echo clean', 'deny'],
  ['Bash', 'cipher /w:C:\\', 'deny'],
  ['PowerShell', 'vssadmin delete shadows /for=C: /all /quiet', 'deny'],
  ['PowerShell', 'Format-Table -AutoSize', 'allow'],
  ['PowerShell', "Remove-Item -Recurse -Force -LiteralPath 'C:\\Projetos\\X\\bin'", 'allow'],
  ['PowerShell', "Remove-Item -Recurse -LiteralPath 'C:\\Windows\\Temp\\x'", 'ask'],
  ['PowerShell', 'Remove-Item -Recurse -LiteralPath $alvo', 'allow'],
  ['PowerShell', 'Remove-Item -Recurse $env:TEMP\\gate-1', 'allow'],
  ['PowerShell', `Remove-Item -Recurse "${TEMP}\\claude\\x"`, 'allow'],
  ['PowerShell', 'Remove-Item -Recurse ~\\Downloads\\x', 'ask'],
  ['PowerShell', 'Remove-Item C:\\Users\\Fulano\\x.txt', 'allow'],
  ['PowerShell', 'Remove-Item -Recurse .\\reports\\velho', 'allow'],
  ['PowerShell', 'Remove-Item -Recurse ..\\..\\..\\Users', 'ask'],
  ['Bash', 'rm -rf -- "$d" 2>/dev/null', 'allow'],
  ['Bash', 'rm -rf /c/Repos/x/.tmp-quadros > /dev/null', 'allow'],
  ['Bash', 'rm -r /tmp/quadros-etapa2.abc', 'allow'],
  ['Bash', 'rm -rf /c/Users/Fulano/.cache', 'ask'],
  ['Bash', 'sudo rm -r /var/log/quadros', 'ask'],
  ['Bash', 'cmd //c rd /s /q C:\\Dados', 'ask'],
  ['Bash', 'rm -f /c/Windows/x.log', 'allow'],
]

function motor(on: On, pasta: string, raiz = pasta) {
  on('tool.check', () => ({ decision: 'allow' }))
  on('session.cwd', () => ({ value: pasta }))
  on('session.root', () => ({ value: raiz }))
  on('env.get', (_, e) => ({ value: e.name === 'TEMP' ? TEMP : undefined }))
}

test('cada comando recebe o veredito esperado numa pasta de trabalho', OPCOES, async ($, on) => {
  motor(on, 'C:\\Projetos\\GerenciadorComputador')
  for (const [tool, command, esperado] of CASOS) {
    const v = await $.tool.check({ tool, input: { command } })
    expect(`${tool}: ${command} -> ${v.decision}`).toBe(`${tool}: ${command} -> ${esperado}`)
  }
})

test('o motivo diz o que foi pego e quem pegou', OPCOES, async ($, on) => {
  motor(on, 'C:\\Projetos\\GerenciadorComputador')
  const v = await $.tool.check({ tool: 'PowerShell', input: { command: 'Stop-Process -Name notepad' } })
  expect(v.reason).toMatch(/^guarda-comandos: Stop-Process/)
})

test('numa pasta fora da guarda, ela nao atua', OPCOES, async ($, on) => {
  motor(on, 'C:\\Repos\\outro-com-guarda\\sub')
  const v = await $.tool.check({ tool: 'PowerShell', input: { command: 'Stop-Process -Id 1' } })
  expect(v.decision).toBe('allow')
})

test('vizinho com nome parecido nao herda a exclusao', OPCOES, async ($, on) => {
  motor(on, 'C:\\Repos\\outro-com-guarda-antigo')
  const v = await $.tool.check({ tool: 'Bash', input: { command: 'taskkill //PID 1' } })
  expect(v.decision).toBe('ask')
})

test('sem opcoes, so a pasta do projeto e o TEMP sao de trabalho', async ($, on) => {
  motor(on, 'C:\\Projetos\\A', 'C:\\Projetos\\A')
  const dentro = await $.tool.check({ tool: 'PowerShell', input: { command: 'Remove-Item -Recurse C:\\Projetos\\A\\bin' } })
  const vizinho = await $.tool.check({ tool: 'PowerShell', input: { command: 'Remove-Item -Recurse C:\\Projetos\\B\\bin' } })
  expect(dentro.decision).toBe('allow')
  expect(vizinho.decision).toBe('ask')
})

test('sessao que saiu do projeto: apagar relativo fora das pastas de trabalho pergunta', OPCOES, async ($, on) => {
  motor(on, 'C:\\Filhos', 'C:\\Projetos\\X')
  const v = await $.tool.check({ tool: 'PowerShell', input: { command: 'Remove-Item -Recurse .\\fotos' } })
  expect(v.decision).toBe('ask')
})

test('a guarda nunca afrouxa uma recusa do motor', OPCOES, async ($, on) => {
  on('tool.check', () => ({ decision: 'deny', reason: 'regra deny do settings' }))
  on('session.cwd', () => ({ value: 'C:\\Projetos\\X' }))
  on('session.root', () => ({ value: 'C:\\Projetos\\X' }))
  on('env.get', () => ({ value: undefined }))
  const v = await $.tool.check({ tool: 'PowerShell', input: { command: 'Get-Date' } })
  expect(v.decision).toBe('deny')
  expect(v.reason).toBe('regra deny do settings')
})

test('outras ferramentas passam sem julgamento', OPCOES, async ($, on) => {
  motor(on, 'C:\\Projetos\\X')
  const v = await $.tool.check({ tool: 'Read', input: { file_path: 'C:\\Windows\\x' } })
  expect(v.decision).toBe('allow')
})
