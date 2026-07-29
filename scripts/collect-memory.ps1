<#
.SYNOPSIS
Coleta pressão de memória do Windows e tendências de processos sem alterar o host.

.DESCRIPTION
Registra memória disponível, commit, paginação, pools do kernel, cache, processos
e eventos 2004. Crescimento durante a janela é descrito como candidato, nunca
como prova de vazamento.
#>
[CmdletBinding()]
param(
    [ValidateRange(2, 720)]
    [int]$SampleCount = 13,

    [ValidateRange(1, 3600)]
    [int]$SampleIntervalSeconds = 5,

    [ValidateRange(1, 100)]
    [int]$Top = 20,

    [ValidateRange(1, 30)]
    [int]$EventLookbackDays = 7,

    [string]$Stamp = (Get-Date -Format 'yyyy-MM-dd_HHmm'),

    [string]$OutDir = (Join-Path $PSScriptRoot '..\reports')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$resolvedOutDir = [IO.Path]::GetFullPath($OutDir)
if (-not (Test-Path -LiteralPath $resolvedOutDir)) {
    New-Item -ItemType Directory -Path $resolvedOutDir | Out-Null
}

$collectionErrors = [Collections.Generic.List[object]]::new()

function Add-CollectionError {
    param(
        [Parameter(Mandatory)][string]$Area,
        [Parameter(Mandatory)][string]$Message
    )

    $collectionErrors.Add([pscustomobject]@{
        Area = $Area
        Message = $Message
    })
}

function Get-CimNumericValue {
    param(
        [AllowNull()]$Instance,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Instance) {
        return $null
    }

    $property = $Instance.CimInstanceProperties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return $null
    }

    return [double]$property.Value
}

function Convert-BytesToGB {
    param([AllowNull()]$Bytes)

    if ($null -eq $Bytes) {
        return $null
    }

    return [math]::Round([double]$Bytes / 1GB, 3)
}

function Convert-MemoryEvent {
    param([Parameter(Mandatory)]$Event)

    $message = $null
    try {
        $message = ($Event.Message -replace '\s+', ' ').Trim()
        if ($message.Length -gt 1000) {
            $message = $message.Substring(0, 1000)
        }
    } catch {
        $message = $null
    }

    [pscustomobject]@{
        TimeCreated = if ($Event.TimeCreated) { $Event.TimeCreated.ToString('o') } else { $null }
        Id = $Event.Id
        ProviderName = $Event.ProviderName
        Level = $Event.LevelDisplayName
        Message = $message
    }
}

function Get-ProcessMemorySnapshot {
    param([Parameter(Mandatory)][datetime]$ObservedAt)

    $rows = [Collections.Generic.List[object]]::new()
    foreach ($process in Get-Process -ErrorAction SilentlyContinue) {
        try {
            $startTimeUtc = $null
            try {
                $startTimeUtc = $process.StartTime.ToUniversalTime().ToString('o')
            } catch {
                $startTimeUtc = $null
            }

            $threadCount = $null
            try {
                $threadCount = $process.Threads.Count
            } catch {
                $threadCount = $null
            }

            $rows.Add([pscustomobject]@{
                ObservedAt = $ObservedAt
                ProcessName = $process.ProcessName
                Id = $process.Id
                StartTimeUtc = $startTimeUtc
                WorkingSetMB = [math]::Round([double]$process.WorkingSet64 / 1MB, 2)
                PrivateBytesMB = [math]::Round([double]$process.PrivateMemorySize64 / 1MB, 2)
                HandleCount = $process.HandleCount
                ThreadCount = $threadCount
            })
        } catch {
            continue
        }
    }

    return $rows.ToArray()
}

function Get-OptionalToolState {
    param([Parameter(Mandatory)][string[]]$Names)

    foreach ($name in $Names) {
        $command = Get-Command -Name $name -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        [pscustomobject]@{
            Name = $name
            Available = $null -ne $command
            Source = if ($command) { $command.Source } else { $null }
            AutomaticallyInvoked = $false
        }
    }
}

$collectionStarted = Get-Date
$computer = $null
$operatingSystem = $null

try {
    $computer = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
} catch {
    Add-CollectionError -Area 'Win32_ComputerSystem' -Message $_.Exception.Message
}

try {
    $operatingSystem = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
} catch {
    Add-CollectionError -Area 'Win32_OperatingSystem' -Message $_.Exception.Message
}

$totalPhysicalBytes = if ($computer -and $computer.TotalPhysicalMemory) {
    [double]$computer.TotalPhysicalMemory
} elseif ($operatingSystem -and $operatingSystem.TotalVisibleMemorySize) {
    [double]$operatingSystem.TotalVisibleMemorySize * 1KB
} else {
    $null
}

if ($null -eq $totalPhysicalBytes -or $totalPhysicalBytes -le 0) {
    throw 'Nao foi possivel determinar a memoria fisica total.'
}

$systemSamples = [Collections.Generic.List[object]]::new()
$processObservations = @{}
$lastProcessSnapshot = @()
$processSnapshotCount = 0

for ($index = 0; $index -lt $SampleCount; $index++) {
    $observedAt = Get-Date
    $memory = $null

    try {
        $memory = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -ErrorAction Stop
    } catch {
        Add-CollectionError `
            -Area "Win32_PerfFormattedData_PerfOS_Memory[$index]" `
            -Message $_.Exception.Message
    }

    if ($memory) {
        $availableBytes = Get-CimNumericValue -Instance $memory -Name 'AvailableBytes'
        $committedBytes = Get-CimNumericValue -Instance $memory -Name 'CommittedBytes'
        $commitLimit = Get-CimNumericValue -Instance $memory -Name 'CommitLimit'

        $standbyBytes = 0.0
        $hasStandbyValue = $false
        foreach ($propertyName in @(
            'StandbyCacheCoreBytes',
            'StandbyCacheNormalPriorityBytes',
            'StandbyCacheReserveBytes'
        )) {
            $value = Get-CimNumericValue -Instance $memory -Name $propertyName
            if ($null -ne $value) {
                $standbyBytes += $value
                $hasStandbyValue = $true
            }
        }

        $systemSamples.Add([pscustomobject]@{
            Timestamp = $observedAt.ToString('o')
            AvailableGB = Convert-BytesToGB $availableBytes
            AvailablePercent = if ($null -ne $availableBytes) {
                [math]::Round(100 * $availableBytes / $totalPhysicalBytes, 2)
            } else {
                $null
            }
            CommittedGB = Convert-BytesToGB $committedBytes
            CommitLimitGB = Convert-BytesToGB $commitLimit
            CommitHeadroomGB = if ($null -ne $committedBytes -and $null -ne $commitLimit) {
                Convert-BytesToGB ([math]::Max(0.0, $commitLimit - $committedBytes))
            } else {
                $null
            }
            CommitPercent = Get-CimNumericValue -Instance $memory -Name 'PercentCommittedBytesInUse'
            PagesPerSec = Get-CimNumericValue -Instance $memory -Name 'PagesPersec'
            PageReadsPerSec = Get-CimNumericValue -Instance $memory -Name 'PageReadsPersec'
            PageWritesPerSec = Get-CimNumericValue -Instance $memory -Name 'PageWritesPersec'
            PagesInputPerSec = Get-CimNumericValue -Instance $memory -Name 'PagesInputPersec'
            PagesOutputPerSec = Get-CimNumericValue -Instance $memory -Name 'PagesOutputPersec'
            PageFaultsPerSec = Get-CimNumericValue -Instance $memory -Name 'PageFaultsPersec'
            TransitionFaultsPerSec = Get-CimNumericValue -Instance $memory -Name 'TransitionFaultsPersec'
            PoolPagedGB = Convert-BytesToGB (
                Get-CimNumericValue -Instance $memory -Name 'PoolPagedBytes'
            )
            PoolNonpagedGB = Convert-BytesToGB (
                Get-CimNumericValue -Instance $memory -Name 'PoolNonpagedBytes'
            )
            CacheGB = Convert-BytesToGB (
                Get-CimNumericValue -Instance $memory -Name 'CacheBytes'
            )
            SystemCacheResidentGB = Convert-BytesToGB (
                Get-CimNumericValue -Instance $memory -Name 'SystemCacheResidentBytes'
            )
            StandbyCacheGB = if ($hasStandbyValue) {
                Convert-BytesToGB $standbyBytes
            } else {
                $null
            }
            ModifiedPageListGB = Convert-BytesToGB (
                Get-CimNumericValue -Instance $memory -Name 'ModifiedPageListBytes'
            )
        })
    }

    if ($index -eq 0 -or $index -eq ($SampleCount - 1)) {
        try {
            $currentProcesses = @(Get-ProcessMemorySnapshot -ObservedAt $observedAt)
            $lastProcessSnapshot = $currentProcesses
            $processSnapshotCount++

            foreach ($row in $currentProcesses) {
                $identity = if ($row.StartTimeUtc) {
                    "$($row.Id)|$($row.StartTimeUtc)"
                } else {
                    "$($row.Id)|$($row.ProcessName)"
                }

                if (-not $processObservations.ContainsKey($identity)) {
                    $processObservations[$identity] = [pscustomobject]@{
                        ProcessName = $row.ProcessName
                        Id = $row.Id
                        StartTimeUtc = $row.StartTimeUtc
                        FirstObserved = $observedAt
                        LastObserved = $observedAt
                        ObservationCount = 1
                        FirstWorkingSetMB = $row.WorkingSetMB
                        LastWorkingSetMB = $row.WorkingSetMB
                        MaximumWorkingSetMB = $row.WorkingSetMB
                        FirstPrivateBytesMB = $row.PrivateBytesMB
                        LastPrivateBytesMB = $row.PrivateBytesMB
                        MaximumPrivateBytesMB = $row.PrivateBytesMB
                    }
                    continue
                }

                $observation = $processObservations[$identity]
                $observation.LastObserved = $observedAt
                $observation.ObservationCount++
                $observation.LastWorkingSetMB = $row.WorkingSetMB
                $observation.LastPrivateBytesMB = $row.PrivateBytesMB
                $observation.MaximumWorkingSetMB = [math]::Max(
                    $observation.MaximumWorkingSetMB,
                    $row.WorkingSetMB
                )
                $observation.MaximumPrivateBytesMB = [math]::Max(
                    $observation.MaximumPrivateBytesMB,
                    $row.PrivateBytesMB
                )
            }
        } catch {
            Add-CollectionError -Area "processos[$index]" -Message $_.Exception.Message
        }
    }

    if ($index -lt ($SampleCount - 1)) {
        Start-Sleep -Seconds $SampleIntervalSeconds
    }
}

$collectionEnded = Get-Date
$durationSeconds = [math]::Round(($collectionEnded - $collectionStarted).TotalSeconds, 2)

if ($systemSamples.Count -eq 0) {
    throw 'Nenhuma amostra de memoria do sistema foi coletada.'
}

$availableGBValues = @(
    $systemSamples | ForEach-Object {
        if ($null -ne $_.AvailableGB) { [double]$_.AvailableGB }
    }
)
$availablePercentValues = @(
    $systemSamples | ForEach-Object {
        if ($null -ne $_.AvailablePercent) { [double]$_.AvailablePercent }
    }
)
$commitPercentValues = @(
    $systemSamples | ForEach-Object {
        if ($null -ne $_.CommitPercent) { [double]$_.CommitPercent }
    }
)
$pagesOutputValues = @(
    $systemSamples | ForEach-Object {
        if ($null -ne $_.PagesOutputPerSec) { [double]$_.PagesOutputPerSec }
    }
)

$minimumAvailableGB = ($availableGBValues | Measure-Object -Minimum).Minimum
$averageAvailableGB = ($availableGBValues | Measure-Object -Average).Average
$minimumAvailablePercent = ($availablePercentValues | Measure-Object -Minimum).Minimum
$maximumCommitPercent = ($commitPercentValues | Measure-Object -Maximum).Maximum
$averageCommitPercent = ($commitPercentValues | Measure-Object -Average).Average
$maximumPagesOutputPerSec = ($pagesOutputValues | Measure-Object -Maximum).Maximum

$criticalReasons = [Collections.Generic.List[string]]::new()
$warningReasons = [Collections.Generic.List[string]]::new()
$observationReasons = [Collections.Generic.List[string]]::new()

if ($minimumAvailableGB -lt (500MB / 1GB)) {
    $criticalReasons.Add('Memoria disponivel abaixo de 500 MB.')
}
if ($minimumAvailablePercent -lt 1) {
    $criticalReasons.Add('Memoria disponivel abaixo de 1% da RAM fisica.')
}
if ($maximumCommitPercent -ge 80) {
    $criticalReasons.Add('Commit em 80% ou mais do limite.')
} elseif ($maximumCommitPercent -ge 60) {
    $warningReasons.Add('Commit entre 60% e 80% do limite.')
} elseif ($maximumCommitPercent -gt 50) {
    $observationReasons.Add('Commit acima da faixa saudavel de 0% a 50%.')
}
if ($minimumAvailablePercent -lt 10 -and $minimumAvailableGB -lt 4) {
    $warningReasons.Add('Memoria disponivel abaixo de 10% e de 4 GB.')
}

$pressureStatus = if ($criticalReasons.Count -gt 0) {
    'CRITICO'
} elseif ($warningReasons.Count -gt 0) {
    'ALERTA'
} elseif ($observationReasons.Count -gt 0) {
    'OBSERVAR'
} else {
    'SAUDAVEL'
}

$processTrends = @(
    foreach ($observation in $processObservations.Values) {
        if ($observation.ObservationCount -lt 2) {
            continue
        }

        $elapsedMinutes = ($observation.LastObserved - $observation.FirstObserved).TotalMinutes
        if ($elapsedMinutes -le 0) {
            continue
        }

        $privateDeltaMB = $observation.LastPrivateBytesMB - $observation.FirstPrivateBytesMB
        $workingSetDeltaMB = $observation.LastWorkingSetMB - $observation.FirstWorkingSetMB
        [pscustomobject]@{
            ProcessName = $observation.ProcessName
            Id = $observation.Id
            StartTimeUtc = $observation.StartTimeUtc
            Observations = $observation.ObservationCount
            WindowSeconds = [math]::Round(60 * $elapsedMinutes, 2)
            PrivateBytesStartMB = $observation.FirstPrivateBytesMB
            PrivateBytesEndMB = $observation.LastPrivateBytesMB
            PrivateBytesMaximumMB = $observation.MaximumPrivateBytesMB
            PrivateBytesDeltaMB = [math]::Round($privateDeltaMB, 2)
            PrivateBytesGrowthMBPerMinute = [math]::Round($privateDeltaMB / $elapsedMinutes, 2)
            WorkingSetStartMB = $observation.FirstWorkingSetMB
            WorkingSetEndMB = $observation.LastWorkingSetMB
            WorkingSetMaximumMB = $observation.MaximumWorkingSetMB
            WorkingSetDeltaMB = [math]::Round($workingSetDeltaMB, 2)
        }
    }
)

$processGroups = @(
    foreach ($group in ($lastProcessSnapshot | Group-Object ProcessName)) {
        [pscustomobject]@{
            ProcessName = $group.Name
            InstanceCount = $group.Count
            PrivateBytesMB = [math]::Round(
                ($group.Group | Measure-Object PrivateBytesMB -Sum).Sum,
                2
            )
            WorkingSetMB = [math]::Round(
                ($group.Group | Measure-Object WorkingSetMB -Sum).Sum,
                2
            )
            HandleCount = ($group.Group | Measure-Object HandleCount -Sum).Sum
            ThreadCount = ($group.Group | Measure-Object ThreadCount -Sum).Sum
        }
    }
)

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
$protectedProcesses = @(
    $lastProcessSnapshot |
        Where-Object { $_.ProcessName -in $protectedProcessNames } |
        Sort-Object ProcessName, Id
)
$protectedProcessGroups = @(
    $processGroups |
        Where-Object { $_.ProcessName -in $protectedProcessNames } |
        Sort-Object PrivateBytesMB -Descending
)

$terminalProcesses = @(
    $lastProcessSnapshot | Where-Object ProcessName -eq 'WindowsTerminal'
)
$terminalPrivateGB = if ($terminalProcesses.Count -gt 0) {
    [math]::Round(
        ($terminalProcesses | Measure-Object PrivateBytesMB -Sum).Sum / 1024,
        3
    )
} else {
    0
}
$terminalWorkingSetGB = if ($terminalProcesses.Count -gt 0) {
    [math]::Round(
        ($terminalProcesses | Measure-Object WorkingSetMB -Sum).Sum / 1024,
        3
    )
} else {
    0
}

$memoryGateReasons = [Collections.Generic.List[string]]::new()
if ($minimumAvailableGB -lt 4) {
    $memoryGateReasons.Add('Menos de 4 GB de RAM disponivel.')
}
if ($maximumCommitPercent -ge 80) {
    $memoryGateReasons.Add('Commit em 80% ou mais.')
}
if ($terminalPrivateGB -gt 4) {
    $memoryGateReasons.Add('Windows Terminal acima de 4 GB privados.')
}
if ($terminalWorkingSetGB -gt 2) {
    $memoryGateReasons.Add('Windows Terminal acima de 2 GB de working set.')
}

$resourceExhaustionEvents = @(
    Get-WinEvent -FilterHashtable @{
        LogName = 'System'
        Id = 2004
        StartTime = (Get-Date).AddDays(-$EventLookbackDays)
    } -MaxEvents 20 -ErrorAction SilentlyContinue |
        ForEach-Object { Convert-MemoryEvent $_ }
)

$pageFiles = @(
    Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue |
        ForEach-Object {
            [pscustomobject]@{
                Name = $_.Name
                AllocatedMB = $_.AllocatedBaseSize
                CurrentUsageMB = $_.CurrentUsage
                PeakUsageMB = $_.PeakUsage
            }
        }
)

$optionalTools = @(
    Get-OptionalToolState -Names @(
        'wpr.exe',
        'wpa.exe',
        'RAMMap.exe',
        'VMMap.exe',
        'poolmon.exe',
        'PerfView.exe',
        'SystemInformer.exe',
        'dotnet-trace.exe'
    )
)

$summary = [ordered]@{
    Status = $pressureStatus
    TotalPhysicalMemoryGB = [math]::Round($totalPhysicalBytes / 1GB, 2)
    AvailableMemoryMinimumGB = [math]::Round($minimumAvailableGB, 2)
    AvailableMemoryAverageGB = [math]::Round($averageAvailableGB, 2)
    AvailableMemoryMinimumPercent = [math]::Round($minimumAvailablePercent, 2)
    CommitMaximumPercent = [math]::Round($maximumCommitPercent, 2)
    CommitAveragePercent = [math]::Round($averageCommitPercent, 2)
    PagesOutputMaximumPerSec = [math]::Round($maximumPagesOutputPerSec, 2)
    WindowSeconds = $durationSeconds
    WindowLongEnoughForSustainedAssessment = $durationSeconds -ge 60
    CriticalReasons = $criticalReasons.ToArray()
    WarningReasons = $warningReasons.ToArray()
    ObservationReasons = $observationReasons.ToArray()
    MemoryOnlyHostChangeGatePassed = $memoryGateReasons.Count -eq 0
    MemoryOnlyHostChangeGateReasons = $memoryGateReasons.ToArray()
    WindowsTerminalPrivateGB = $terminalPrivateGB
    WindowsTerminalWorkingSetGB = $terminalWorkingSetGB
    ProtectedProcessCount = $protectedProcesses.Count
    ResourceExhaustionEventCount = $resourceExhaustionEvents.Count
    Interpretation = 'Crescimento nesta janela indica apenas candidato; vazamento exige tendencia sustentada e investigacao adicional.'
}

$result = [ordered]@{
    schemaVersion = '1.0.0'
    generatedAt = $collectionEnded.ToString('o')
    collection = [ordered]@{
        sampleCountRequested = $SampleCount
        sampleCountCollected = $systemSamples.Count
        sampleIntervalSeconds = $SampleIntervalSeconds
        processSnapshotCount = $processSnapshotCount
        durationSeconds = $durationSeconds
        partial = $collectionErrors.Count -gt 0
        errors = $collectionErrors.ToArray()
    }
    summary = $summary
    systemSamples = $systemSamples.ToArray()
    topProcessGroupsByPrivateBytes = @(
        $processGroups |
            Sort-Object PrivateBytesMB -Descending |
            Select-Object -First $Top
    )
    topProcessesByPrivateBytes = @(
        $lastProcessSnapshot |
            Sort-Object PrivateBytesMB -Descending |
            Select-Object -First $Top
    )
    privateBytesGrowthCandidates = @(
        $processTrends |
            Where-Object PrivateBytesDeltaMB -gt 0 |
            Sort-Object PrivateBytesDeltaMB -Descending |
            Select-Object -First $Top
    )
    protectedProcesses = $protectedProcesses
    protectedProcessGroups = $protectedProcessGroups
    resourceExhaustionEvents = $resourceExhaustionEvents
    pageFiles = $pageFiles
    optionalInvestigationTools = $optionalTools
}

$jsonPath = Join-Path $resolvedOutDir "memory_$Stamp.json"
$markdownPath = Join-Path $resolvedOutDir "memory_$Stamp.md"
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonPath -Encoding utf8

$markdown = [Collections.Generic.List[string]]::new()
$markdown.Add('# Diagnóstico de memória')
$markdown.Add('')
$markdown.Add("- Gerado em: $($result.generatedAt)")
$markdown.Add("- Estado: **$($summary.Status)**")
$markdown.Add("- Janela: $($summary.WindowSeconds) s")
$markdown.Add("- RAM física: $($summary.TotalPhysicalMemoryGB) GB")
$markdown.Add("- Disponível (mínimo): $($summary.AvailableMemoryMinimumGB) GB ($($summary.AvailableMemoryMinimumPercent)%)")
$markdown.Add("- Commit (máximo): $($summary.CommitMaximumPercent)%")
$markdown.Add("- Pages Output/sec (pico): $($summary.PagesOutputMaximumPerSec)")
$markdown.Add("- Gate de memória para mudanças no host: $($summary.MemoryOnlyHostChangeGatePassed)")
$markdown.Add('')
$markdown.Add('> Crescimento durante esta janela é somente um candidato. Ele não comprova vazamento de memória.')
$markdown.Add('')
$markdown.Add('## Maiores grupos por memória privada')
$markdown.Add('')
$markdown.Add('| Processo | Instâncias | Private Bytes (MB) | Working Set (MB) |')
$markdown.Add('|---|---:|---:|---:|')
foreach ($row in $result.topProcessGroupsByPrivateBytes) {
    $safeName = $row.ProcessName -replace '\|', '\|'
    $markdown.Add("| $safeName | $($row.InstanceCount) | $($row.PrivateBytesMB) | $($row.WorkingSetMB) |")
}
$markdown.Add('')
$markdown.Add('## Grupos protegidos (somente observação)')
$markdown.Add('')
$markdown.Add('| Processo | Instâncias | Private Bytes (MB) | Working Set (MB) |')
$markdown.Add('|---|---:|---:|---:|')
foreach ($row in $protectedProcessGroups) {
    $safeName = $row.ProcessName -replace '\|', '\|'
    $markdown.Add("| $safeName | $($row.InstanceCount) | $($row.PrivateBytesMB) | $($row.WorkingSetMB) |")
}
$markdown.Add('')
$markdown.Add("O JSON preserva PID e consumo individual dos $($protectedProcesses.Count) processos protegidos.")
$markdown.Add('')
$markdown.Add("Eventos 2004 nos últimos $EventLookbackDays dias: $($resourceExhaustionEvents.Count).")
if ($collectionErrors.Count -gt 0) {
    $markdown.Add('')
    $markdown.Add('## Coleta parcial')
    $markdown.Add('')
    foreach ($errorRow in $collectionErrors) {
        $markdown.Add("- $($errorRow.Area): $($errorRow.Message)")
    }
}
$markdown | Set-Content -LiteralPath $markdownPath -Encoding utf8

[pscustomobject]$summary | Format-List
Write-Host "JSON: $jsonPath"
Write-Host "Resumo: $markdownPath"
