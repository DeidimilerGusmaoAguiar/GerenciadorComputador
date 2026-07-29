<#
.SYNOPSIS
Monitora CPU e pressão de memória por uma janela limitada, sem alterar o host.

.DESCRIPTION
Grava CSV com CPU total, commit real do sistema, memória disponível, paginação
e os três processos com maior consumo de CPU durante cada intervalo.
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 1440)]
    [int]$Minutes = 15,

    [ValidateRange(2, 3600)]
    [int]$IntervalSec = 6,

    [string]$OutDir = (Join-Path $PSScriptRoot '..\reports')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$resolvedOutDir = [IO.Path]::GetFullPath($OutDir)
if (-not (Test-Path -LiteralPath $resolvedOutDir)) {
    New-Item -ItemType Directory -Path $resolvedOutDir | Out-Null
}

$stamp = Get-Date -Format 'yyyy-MM-dd_HHmm'
$csvPath = Join-Path $resolvedOutDir "perfmon_$stamp.csv"
$computer = Get-CimInstance Win32_ComputerSystem
$logicalProcessorCount = [math]::Max(1, [int]$computer.NumberOfLogicalProcessors)
$sampleCpuSeconds = [math]::Min(2, $IntervalSec)
$protectedProcessNames = @(
    'WindowsTerminal',
    'OpenConsole',
    'powershell',
    'pwsh',
    'cmd',
    'bash',
    'wsl',
    'codex',
    'claude',
    'gemini',
    'grok',
    'opencode'
)

$header = @(
    'timestamp',
    'verdict',
    'cpu_total_pct',
    'commit_pct',
    'available_gb',
    'available_pct',
    'pages_output_sec',
    'memory_compression_mb',
    'protected_private_mb',
    'protected_workingset_mb',
    'top1',
    'top1_capacity_pct',
    'top2',
    'top2_capacity_pct',
    'top3',
    'top3_capacity_pct'
) -join ';'
$header | Set-Content -LiteralPath $csvPath -Encoding utf8

$end = (Get-Date).AddMinutes($Minutes)
Write-Host "Monitorando ate $end. CSV: $csvPath"

while ((Get-Date) -lt $end) {
    $startCpuById = @{}
    foreach ($process in Get-Process -ErrorAction SilentlyContinue) {
        try {
            $startCpuById[$process.Id] = [double]$process.TotalProcessorTime.TotalSeconds
        } catch {
            continue
        }
    }

    Start-Sleep -Seconds $sampleCpuSeconds
    $endProcesses = @(Get-Process -ErrorAction SilentlyContinue)
    $deltas = @(
        foreach ($process in $endProcesses) {
            if (-not $startCpuById.ContainsKey($process.Id)) {
                continue
            }

            try {
                $deltaSeconds = (
                    [double]$process.TotalProcessorTime.TotalSeconds -
                    $startCpuById[$process.Id]
                )
                if ($deltaSeconds -le 0.05) {
                    continue
                }

                [pscustomobject]@{
                    Name = $process.ProcessName
                    CapacityPercent = [math]::Round(
                        100 * $deltaSeconds / ($sampleCpuSeconds * $logicalProcessorCount),
                        1
                    )
                }
            } catch {
                continue
            }
        }
    )
    $top = @(
        $deltas |
            Sort-Object CapacityPercent -Descending |
            Select-Object -First 3
    )

    $cpuTotal = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor |
        Where-Object Name -eq '_Total' |
        Select-Object -First 1
    $memory = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory

    $cpuPercent = [double]$cpuTotal.PercentProcessorTime
    $commitPercent = [double]$memory.PercentCommittedBytesInUse
    $availableGB = [math]::Round([double]$memory.AvailableBytes / 1GB, 2)
    $availablePercent = [math]::Round(
        100 * [double]$memory.AvailableBytes / [double]$computer.TotalPhysicalMemory,
        2
    )
    $pagesOutputPerSec = [double]$memory.PagesOutputPersec
    $memoryCompression = Get-Process 'Memory Compression' -ErrorAction SilentlyContinue |
        Select-Object -First 1
    $memoryCompressionMB = if ($memoryCompression) {
        [math]::Round([double]$memoryCompression.WorkingSet64 / 1MB, 0)
    } else {
        0
    }

    $protectedProcesses = @(
        $endProcesses | Where-Object { $_.ProcessName -in $protectedProcessNames }
    )
    $protectedPrivateMB = [math]::Round(
        ($protectedProcesses | Measure-Object PrivateMemorySize64 -Sum).Sum / 1MB,
        1
    )
    $protectedWorkingSetMB = [math]::Round(
        ($protectedProcesses | Measure-Object WorkingSet64 -Sum).Sum / 1MB,
        1
    )

    $verdict = if (
        $commitPercent -ge 80 -or
        $availableGB -lt (500MB / 1GB) -or
        $availablePercent -lt 1 -or
        $cpuPercent -ge 90
    ) {
        'CRITICO'
    } elseif (
        $commitPercent -ge 60 -or
        ($availablePercent -lt 10 -and $availableGB -lt 4) -or
        $cpuPercent -ge 80
    ) {
        'ALERTA'
    } elseif ($commitPercent -gt 50 -or $cpuPercent -ge 50) {
        'OBSERVAR'
    } else {
        'SAUDAVEL'
    }

    $topValues = @()
    for ($index = 0; $index -lt 3; $index++) {
        if ($index -lt $top.Count) {
            $topValues += $top[$index].Name
            $topValues += $top[$index].CapacityPercent
        } else {
            $topValues += ''
            $topValues += 0
        }
    }

    $fields = @(
        (Get-Date -Format 'o'),
        $verdict,
        $cpuPercent,
        $commitPercent,
        $availableGB,
        $availablePercent,
        $pagesOutputPerSec,
        $memoryCompressionMB,
        $protectedPrivateMB,
        $protectedWorkingSetMB
    ) + $topValues
    ($fields -join ';') | Add-Content -LiteralPath $csvPath -Encoding utf8

    Write-Host (
        '[{0}] {1} CPU={2}% commit={3}% disponivel={4} GB top={5}' -f
        (Get-Date -Format 'HH:mm:ss'),
        $verdict,
        $cpuPercent,
        $commitPercent,
        $availableGB,
        ($topValues[0] -as [string])
    )

    $remainingSeconds = $IntervalSec - $sampleCpuSeconds
    if ($remainingSeconds -gt 0) {
        Start-Sleep -Seconds $remainingSeconds
    }
}

Write-Host "Concluido. CSV: $csvPath"
