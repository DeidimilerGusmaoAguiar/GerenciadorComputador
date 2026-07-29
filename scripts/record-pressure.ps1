<#
.SYNOPSIS
Grava o historico de pressao sem servidor HTTP e sem navegador.

.DESCRIPTION
O painel coleta sob demanda: uma amostra por requisicao. Isso e adequado para
observacao ao vivo, e inadequado para captura desassistida de um episodio que
comeca em horario conhecido, porque depende de uma aba aberta.

Este script coleta por conta propria, na mesma cadencia adaptativa do painel, e
grava as amostras em reports\pressure-history. Nao abre porta, nao serve
interface e nao encerra processo algum.

Termina por duracao (-Minutes), por Ctrl+C, ou quando o processo que o iniciou
desaparece.

.EXAMPLE
pwsh -NoProfile -File .\scripts\record-pressure.ps1 -Minutes 120

.EXAMPLE
pwsh -NoProfile -File .\scripts\record-pressure.ps1 -Minutes 1440 -MaxRefreshSeconds 60
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 10080)]
    [int]$Minutes = 60,

    [ValidateRange(2, 60)]
    [int]$RefreshSeconds = 5,

    [ValidateRange(2, 600)]
    [int]$MaxRefreshSeconds = 30,

    [switch]$FixedCadence,

    [ValidateRange(1, 365)]
    [int]$HistoryRetentionDays = 7,

    [ValidateRange(1, 4096)]
    [int]$HistoryMaxMB = 50,

    [AllowEmptyString()]
    [string]$HistoryDirectory = '',

    [switch]$NoParentWatch,

    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$corePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'lib\pressure-core.ps1'))
if (-not (Test-Path -LiteralPath $corePath -PathType Leaf)) {
    throw "Nucleo do painel ausente: $corePath"
}
. $corePath

$resolvedHistoryDirectory = if ([string]::IsNullOrWhiteSpace($HistoryDirectory)) {
    [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\reports\pressure-history'))
} else {
    [IO.Path]::GetFullPath($HistoryDirectory)
}

$state = New-PressureMonitorState `
    -RefreshSeconds $RefreshSeconds `
    -MaxRefreshSeconds $MaxRefreshSeconds `
    -FixedCadence:$FixedCadence `
    -DashboardProcessId ([uint32]$PID)

$writer = New-PressureHistoryWriter `
    -Directory $resolvedHistoryDirectory `
    -RetentionDays $HistoryRetentionDays `
    -MaxMB $HistoryMaxMB

$parentWatch = if ($NoParentWatch) {
    [pscustomobject]@{
        Enabled = $false
        ParentId = [uint32]0
        ParentName = ''
        StartedAt = [datetime]::MinValue
    }
} else {
    Get-PressureParentWatch
}

$startedAt = Get-Date
$endAt = $startedAt.AddMinutes($Minutes)
$stopReason = 'duracao concluida'
$samples = 0

if (-not $Quiet) {
    Write-Host "Gravando pressao ate $($endAt.ToString('dd/MM HH:mm')) em $resolvedHistoryDirectory"
    Write-Host 'Contem dados desta maquina; nao versione. Use Ctrl+C para parar.'
    if ($parentWatch.Enabled) {
        Write-Host "Encerra sozinho se $($parentWatch.ParentName) PID $($parentWatch.ParentId) desaparecer."
    }
}

try {
    $null = Add-PressureHistoryRecord `
        -Writer $writer `
        -Record (New-PressureHistoryBaseline -State $state -Kind 'session-start' -Reason 'gravador de fundo') `
        -Flush

    while ((Get-Date) -lt $endAt) {
        if (-not (Test-PressureParentAlive -Watch $parentWatch)) {
            $stopReason = "processo pai $($parentWatch.ParentName) PID $($parentWatch.ParentId) desapareceu"
            break
        }

        $cycleStartedAt = Get-Date
        $snapshot = Get-PressureSnapshot -State $state
        $null = Add-PressureHistoryRecord `
            -Writer $writer `
            -Record (ConvertTo-PressureHistoryRecord -Snapshot $snapshot)
        $samples++

        if (-not $Quiet) {
            Write-Host (
                '[{0}] {1} cadencia={2}s fila={3} varredura={4} custo={5}%' -f
                (Get-Date -Format 'HH:mm:ss'),
                $snapshot.Overall.State,
                $snapshot.RefreshSeconds,
                $snapshot.Metrics.DiskQueue,
                $snapshot.Defender.ScanInProgress,
                $snapshot.SelfCost.DutyPercent
            )
        }

        # A cadencia efetiva ja foi ajustada dentro do snapshot; descontar o
        # tempo de coleta evita que a gravacao ande mais devagar que o alvo.
        $elapsedMs = ((Get-Date) - $cycleStartedAt).TotalMilliseconds
        $waitMs = ([int]$state.RefreshSeconds * 1000) - $elapsedMs
        if ($waitMs -gt 0 -and (Get-Date).AddMilliseconds($waitMs) -lt $endAt) {
            Start-Sleep -Milliseconds $waitMs
        } elseif ($waitMs -gt 0) {
            break
        }
    }
} finally {
    try {
        $null = Add-PressureHistoryRecord `
            -Writer $writer `
            -Record (
                New-PressureHistoryBaseline `
                    -State $state `
                    -Kind 'session-end' `
                    -Reason $stopReason
            ) `
            -Flush
    } catch {
        Write-Warning "O historico nao pode ser finalizado: $($_.Exception.Message)"
    }
}

[pscustomobject]@{
    Status = 'completed'
    Reason = $stopReason
    Samples = $samples
    LinesWritten = [int]$writer.WrittenLines
    Directory = $resolvedHistoryDirectory
    File = (Get-PressureHistoryFilePath -Writer $writer)
    StartedAt = $startedAt.ToString('o')
    EndedAt = (Get-Date).ToString('o')
    PendingCleanup = @($writer.PendingCleanup | ForEach-Object { $_.Name })
}
