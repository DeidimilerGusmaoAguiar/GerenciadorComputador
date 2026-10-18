<#
.SYNOPSIS
Mostra, instala ou remove a tarefa agendada que roda sweep-temp-residue.ps1.

.DESCRIPTION
Sem -Execute, mostra a tarefa que seria registrada e o estado atual, sem mudar
nada. Com -Execute, registra na conta do usuario atual, sem elevacao: diaria no
horario de -At, repetindo a cada -RepeatHours ate o fim do dia para cobrir
execucoes que abortaram por teste ou build rodando. A propria varredura sai sem
fazer nada se ja houve uma execucao bem-sucedida nas ultimas 20 h. A tarefa
roda assim que possivel se a maquina estava desligada no horario, com
prioridade baixa e limite de duas horas. A acao passa por conhost --headless
para nao abrir janela nem aba do Windows Terminal.

Instalar a tarefa e a aprovacao permanente do dono para os grupos de
local\temp-sweeper.json, e so para eles. Ampliar os grupos ou tirar exclusoes
exige nova aprovacao.

Antes de substituir ou remover uma tarefa existente, exporta o XML dela para
reports\temp-sweeper\.

.EXAMPLE
pwsh -NoProfile -File .\scripts\install-temp-sweeper.ps1

.EXAMPLE
pwsh -NoProfile -File .\scripts\install-temp-sweeper.ps1 -Execute

.EXAMPLE
pwsh -NoProfile -File .\scripts\install-temp-sweeper.ps1 -Uninstall -Execute
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [switch]$Execute,

    [switch]$Uninstall,

    [ValidatePattern('^([01]\d|2[0-3]):[0-5]\d$')]
    [string]$At = '03:00',

    [ValidateRange(1, 12)]
    [int]$RepeatHours = 3,

    [ValidateNotNullOrEmpty()]
    [string]$TaskName = 'Varredura do TEMP',

    [ValidatePattern('^\\(.+\\)?$')]
    [string]$TaskPath = '\GerenciadorComputador\'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$sweepScript = Join-Path $PSScriptRoot 'sweep-temp-residue.ps1'
$configPath = Join-Path $repoRoot 'local\temp-sweeper.json'
$stateDirectory = Join-Path $repoRoot 'reports\temp-sweeper'
$stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
New-Item -ItemType Directory -Force -Path $stateDirectory | Out-Null

function Write-InstallLog {
    param([Parameter(Mandatory)][string]$Action, $Detail)

    $line = [ordered]@{ timestamp = (Get-Date).ToString('o'); acao = $Action; tarefa = "$TaskPath$TaskName"; detalhe = $Detail }
    Add-Content -LiteralPath (Join-Path $stateDirectory 'instalacao.jsonl') -Value ($line | ConvertTo-Json -Depth 4 -Compress) -Encoding utf8
}

$existing = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
if ($existing) {
    $info = Get-ScheduledTaskInfo -TaskName $TaskName -TaskPath $TaskPath
    Write-Output ("Tarefa atual: {0}{1}, estado {2}, ultima execucao {3} (resultado {4}), proxima {5}" -f
        $TaskPath, $TaskName, $existing.State, $info.LastRunTime, $info.LastTaskResult, $info.NextRunTime)
} else {
    Write-Output "Tarefa atual: nenhuma em $TaskPath$TaskName"
}

function Backup-ExistingTask {
    if (-not $existing) { return }
    $xmlPath = Join-Path $stateDirectory "tarefa-anterior_$stamp.xml"
    Export-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath | Set-Content -LiteralPath $xmlPath -Encoding utf8
    Write-Output "Estado anterior exportado para $xmlPath"
}

if ($Uninstall) {
    if (-not $existing) { Write-Output 'Nada a remover.'; return }
    if (-not $Execute) { Write-Output 'Dry-run: com -Execute, exporta o XML e remove a tarefa.'; return }
    if ($PSCmdlet.ShouldProcess("$TaskPath$TaskName", 'Remover tarefa agendada')) {
        Backup-ExistingTask
        Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Confirm:$false
        Write-InstallLog -Action 'removida' -Detail $null
        Write-Output 'Tarefa removida.'
    }
    return
}

if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    throw "Configuracao nao encontrada: $configPath. Copie docs\temp-sweeper.example.json, revise host e grupos e rode de novo."
}
$configHost = [string]((Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json).PSObject.Properties['host'].Value)
if ($configHost -ne $env:COMPUTERNAME) {
    throw "local\temp-sweeper.json e do host '$configHost', e esta maquina e '$env:COMPUTERNAME'."
}

# O pwsh da Microsoft Store mora numa pasta com a versao no nome, que muda a cada
# atualizacao e quebraria a tarefa em silencio. A instalacao MSI e o alias de
# WindowsApps tem caminho estavel.
$pwshPath = @(
    (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'),
    (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe')
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $pwshPath) { $pwshPath = Join-Path $PSHOME 'pwsh.exe' }
$conhostPath = Join-Path $env:SystemRoot 'System32\conhost.exe'
$arguments = "--headless `"$pwshPath`" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$sweepScript`" -Execute"

$trigger = New-ScheduledTaskTrigger -Daily -At $At
$trigger.Repetition = (New-ScheduledTaskTrigger -Once -At $At -RepetitionInterval (New-TimeSpan -Hours $RepeatHours) `
    -RepetitionDuration (New-TimeSpan -Hours (24 - $RepeatHours))).Repetition
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Hours 2) -MultipleInstances IgnoreNew -Priority 7
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
$action = New-ScheduledTaskAction -Execute $conhostPath -Argument $arguments -WorkingDirectory $repoRoot
$description = 'Remove residuo de teste antigo do %TEMP% (GerenciadorComputador). Historico em reports\temp-sweeper\historico.jsonl.'

Write-Output "Tarefa planejada: $TaskPath$TaskName"
Write-Output "  Acao: $conhostPath $arguments"
Write-Output "  Gatilho: diario as $At, repetindo a cada $RepeatHours h ate o fim do dia; roda assim que possivel se perdeu o horario"
Write-Output "  Conta: $env:USERDOMAIN\$env:USERNAME, sem elevacao, so com o usuario logado; prioridade baixa; limite de 2 h"

if (-not $Execute) {
    Write-Output 'Dry-run: nada foi registrado. Rode com -Execute para instalar.'
    return
}

if ($PSCmdlet.ShouldProcess("$TaskPath$TaskName", 'Registrar tarefa agendada')) {
    Backup-ExistingTask
    $null = Register-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Action $action -Trigger $trigger `
        -Settings $settings -Principal $principal -Description $description -Force
    $info = Get-ScheduledTaskInfo -TaskName $TaskName -TaskPath $TaskPath
    Write-InstallLog -Action 'registrada' -Detail ([ordered]@{ at = $At; repeatHours = $RepeatHours; acao = "$conhostPath $arguments" })
    Write-Output "Tarefa registrada. Proxima execucao: $($info.NextRunTime)"
}
