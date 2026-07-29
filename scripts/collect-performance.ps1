[CmdletBinding()]
param(
    [int]$SampleCount = 8,
    [int]$SampleIntervalSeconds = 1,
    [string]$Stamp = (Get-Date -Format 'yyyy-MM-dd_HHmm'),
    [string]$OutDir = (Join-Path $PSScriptRoot '..\reports')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir | Out-Null
}

function Convert-EventRecord {
    param([Parameter(Mandatory)]$Event)
    $message = $null
    try {
        $message = ($Event.Message -replace '\s+', ' ').Trim()
        if ($message.Length -gt 500) {
            $message = $message.Substring(0, 500)
        }
    } catch {
        $message = $null
    }
    [pscustomobject]@{
        TimeCreated = $Event.TimeCreated.ToString('o')
        Id = $Event.Id
        ProviderName = $Event.ProviderName
        Level = $Event.LevelDisplayName
        Message = $message
    }
}

$computer = Get-CimInstance Win32_ComputerSystem
$os = Get-CimInstance Win32_OperatingSystem
$processor = Get-CimInstance Win32_Processor | Select-Object -First 1
$logicalProcessorCount = [int]$computer.NumberOfLogicalProcessors
$startProcesses = @{}
foreach ($process in Get-Process -ErrorAction SilentlyContinue) {
    try {
        $startProcesses[$process.Id] = [double]$process.TotalProcessorTime.TotalSeconds
    } catch {
        continue
    }
}
$sampleStart = Get-Date

$samples = [System.Collections.Generic.List[object]]::new()
for ($index = 0; $index -lt $SampleCount; $index++) {
    $cpuTotal = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -ErrorAction SilentlyContinue |
        Where-Object Name -eq '_Total' |
        Select-Object -First 1
    $diskTotal = Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk -ErrorAction SilentlyContinue |
        Where-Object Name -eq '_Total' |
        Select-Object -First 1
    $memory = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -ErrorAction SilentlyContinue
    $networkRows = @(
        Get-CimInstance Win32_PerfFormattedData_Tcpip_NetworkInterface -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne '_Total' }
    )
    $networkBytes = ($networkRows | Measure-Object BytesTotalPersec -Sum).Sum

    $samples.Add([pscustomobject]@{
        Timestamp = (Get-Date).ToString('o')
        CpuPercent = if ($cpuTotal) { [double]$cpuTotal.PercentProcessorTime } else { $null }
        DiskPercent = if ($diskTotal) { [double]$diskTotal.PercentDiskTime } else { $null }
        DiskQueueLength = if ($diskTotal) { [double]$diskTotal.AvgDiskQueueLength } else { $null }
        DiskBytesPerSec = if ($diskTotal) { [double]$diskTotal.DiskBytesPersec } else { $null }
        DiskReadBytesPerSec = if ($diskTotal) { [double]$diskTotal.DiskReadBytesPersec } else { $null }
        DiskWriteBytesPerSec = if ($diskTotal) { [double]$diskTotal.DiskWriteBytesPersec } else { $null }
        AvailableMB = if ($memory) { [double]$memory.AvailableMBytes } else { $null }
        CommitPercent = if ($memory) { [double]$memory.PercentCommittedBytesInUse } else { $null }
        PagesPerSec = if ($memory) { [double]$memory.PagesPersec } else { $null }
        PageReadsPerSec = if ($memory) { [double]$memory.PageReadsPersec } else { $null }
        NetworkBytesPerSec = [double]$networkBytes
    })

    if ($index -lt ($SampleCount - 1)) {
        Start-Sleep -Seconds $SampleIntervalSeconds
    }
}

$sampleEnd = Get-Date
$elapsedSeconds = [math]::Max(0.1, ($sampleEnd - $sampleStart).TotalSeconds)
$endProcesses = @(Get-Process -ErrorAction SilentlyContinue)
$processCpuWindow = @(
    foreach ($process in $endProcesses) {
        if (-not $startProcesses.ContainsKey($process.Id)) {
            continue
        }
        try {
            $deltaSeconds = [double]$process.TotalProcessorTime.TotalSeconds - $startProcesses[$process.Id]
            if ($deltaSeconds -lt 0) {
                continue
            }
            [pscustomobject]@{
                ProcessName = $process.ProcessName
                Id = $process.Id
                CpuPercentOfTotalCapacity = [math]::Round(
                    100 * $deltaSeconds / ($elapsedSeconds * $logicalProcessorCount),
                    2
                )
                CpuSecondsInWindow = [math]::Round($deltaSeconds, 3)
                WorkingSetMB = [math]::Round($process.WorkingSet64 / 1MB, 1)
            }
        } catch {
            continue
        }
    }
)

$processSnapshot = @(
    foreach ($process in $endProcesses) {
        try {
            [pscustomobject]@{
                ProcessName = $process.ProcessName
                Id = $process.Id
                CpuSecondsSinceStart = [math]::Round([double]$process.CPU, 1)
                WorkingSetMB = [math]::Round($process.WorkingSet64 / 1MB, 1)
                PrivateMemoryMB = [math]::Round($process.PrivateMemorySize64 / 1MB, 1)
                ThreadCount = $process.Threads.Count
            }
        } catch {
            continue
        }
    }
)

$pageFiles = @(
    Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue |
        Select-Object Name, AllocatedBaseSize, CurrentUsage, PeakUsage
)

$physicalDisks = @()
$physicalDiskInstances = @(
    Get-CimInstance -Namespace root/Microsoft/Windows/Storage -ClassName MSFT_PhysicalDisk -ErrorAction SilentlyContinue
)
foreach ($disk in $physicalDiskInstances) {
    $reliability = Get-CimAssociatedInstance -InputObject $disk `
        -Association MSFT_PhysicalDiskToStorageReliabilityCounter `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1
    $physicalDisks += [pscustomobject]@{
        DeviceId = $disk.DeviceId
        FriendlyName = $disk.FriendlyName
        MediaTypeCode = $disk.MediaType
        HealthStatusCode = $disk.HealthStatus
        OperationalStatusCodes = @($disk.OperationalStatus)
        SizeGB = [math]::Round($disk.Size / 1GB, 1)
        TemperatureC = if ($reliability) { $reliability.Temperature } else { $null }
        TemperatureMaxC = if ($reliability) { $reliability.TemperatureMax } else { $null }
        WearPercent = if ($reliability) { $reliability.Wear } else { $null }
        PowerOnHours = if ($reliability) { $reliability.PowerOnHours } else { $null }
        ReadErrorsTotal = if ($reliability) { $reliability.ReadErrorsTotal } else { $null }
        ReadErrorsUncorrected = if ($reliability) { $reliability.ReadErrorsUncorrected } else { $null }
        WriteErrorsTotal = if ($reliability) { $reliability.WriteErrorsTotal } else { $null }
        WriteErrorsUncorrected = if ($reliability) { $reliability.WriteErrorsUncorrected } else { $null }
    }
}

$videoControllers = @(
    Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
        ForEach-Object {
            [pscustomobject]@{
                Name = $_.Name
                DriverVersion = $_.DriverVersion
                AdapterRAMBytes = if ($_.AdapterRAM) { [uint64]$_.AdapterRAM } else { $null }
                VideoProcessor = $_.VideoProcessor
                Status = $_.Status
            }
        }
)

$activeAdapters = @(
    Get-CimInstance Win32_NetworkAdapter -ErrorAction SilentlyContinue |
        Where-Object NetEnabled -eq $true |
        ForEach-Object {
            [pscustomobject]@{
                Name = $_.Name
                NetConnectionId = $_.NetConnectionId
                AdapterType = $_.AdapterType
                SpeedMbps = if ($_.Speed) { [math]::Round([double]$_.Speed / 1MB, 1) } else { $null }
                PhysicalAdapter = $_.PhysicalAdapter
            }
        }
)

$criticalEvents = @(
    Get-WinEvent -FilterHashtable @{
        LogName = 'System'
        Level = 1, 2
        StartTime = (Get-Date).AddDays(-1)
    } -MaxEvents 50 -ErrorAction SilentlyContinue |
        ForEach-Object { Convert-EventRecord $_ }
)
$targetedEvents = @(
    Get-WinEvent -FilterHashtable @{
        LogName = 'System'
        Id = 1129, 1130, 5719, 10010, 10028, 7031, 7034
        StartTime = (Get-Date).AddDays(-7)
    } -MaxEvents 100 -ErrorAction SilentlyContinue |
        ForEach-Object { Convert-EventRecord $_ }
)
$bootEvents = @(
    Get-WinEvent -FilterHashtable @{
        LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'
        Id = 100, 200
    } -MaxEvents 10 -ErrorAction SilentlyContinue |
        ForEach-Object { Convert-EventRecord $_ }
)

$defenderStatus = $null
$defenderPreference = $null
try {
    $defenderStatus = Get-CimInstance `
        -Namespace root/Microsoft/Windows/Defender `
        -ClassName MSFT_MpComputerStatus `
        -ErrorAction Stop |
        Select-Object AMServiceEnabled, AntivirusEnabled, AntispywareEnabled,
            BehaviorMonitorEnabled, IoavProtectionEnabled, NISEnabled,
            OnAccessProtectionEnabled, RealTimeProtectionEnabled,
            AntivirusSignatureAge, AntivirusSignatureLastUpdated,
            QuickScanStartTime, QuickScanEndTime, FullScanStartTime, FullScanEndTime,
            ComputerState, RebootRequired
} catch {
    $defenderStatus = [pscustomobject]@{ Error = $_.Exception.Message }
}
try {
    $defenderPreference = Get-CimInstance `
        -Namespace root/Microsoft/Windows/Defender `
        -ClassName MSFT_MpPreference `
        -ErrorAction Stop |
        Select-Object ExclusionPath, ExclusionProcess, DisableRealtimeMonitoring,
            ScanScheduleDay, ScanScheduleTime
} catch {
    $defenderPreference = [pscustomobject]@{ Error = $_.Exception.Message }
}

$powerScheme = (powercfg.exe /getactivescheme 2>&1) -join "`n"
$sleepStates = (powercfg.exe /a 2>&1) -join "`n"
$wslConfigPath = Join-Path $env:USERPROFILE '.wslconfig'
$wslConfig = if (Test-Path -LiteralPath $wslConfigPath) {
    Get-Content -LiteralPath $wslConfigPath -Raw
} else {
    $null
}

$dockerWslProcesses = @(
    Get-Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ProcessName -match '^(vmmem|vmmemWSL|Docker Desktop|com\.docker|dockerd|wslservice|wsl)$'
        } |
        ForEach-Object {
            [pscustomobject]@{
                ProcessName = $_.ProcessName
                Id = $_.Id
                WorkingSetMB = [math]::Round($_.WorkingSet64 / 1MB, 1)
                PrivateMemoryMB = [math]::Round($_.PrivateMemorySize64 / 1MB, 1)
                CpuSecondsSinceStart = [math]::Round([double]$_.CPU, 1)
            }
        }
)

$cpuValues = @($samples | Where-Object { $null -ne $_.CpuPercent } | Select-Object -ExpandProperty CpuPercent)
$diskValues = @($samples | Where-Object { $null -ne $_.DiskPercent } | Select-Object -ExpandProperty DiskPercent)
$queueValues = @($samples | Where-Object { $null -ne $_.DiskQueueLength } | Select-Object -ExpandProperty DiskQueueLength)
$availableValues = @($samples | Where-Object { $null -ne $_.AvailableMB } | Select-Object -ExpandProperty AvailableMB)
$commitValues = @($samples | Where-Object { $null -ne $_.CommitPercent } | Select-Object -ExpandProperty CommitPercent)
$pagesValues = @($samples | Where-Object { $null -ne $_.PagesPerSec } | Select-Object -ExpandProperty PagesPerSec)

$summary = [ordered]@{
    CpuAveragePercent = if ($cpuValues) { [math]::Round(($cpuValues | Measure-Object -Average).Average, 1) } else { $null }
    CpuPeakPercent = if ($cpuValues) { [math]::Round(($cpuValues | Measure-Object -Maximum).Maximum, 1) } else { $null }
    DiskAveragePercent = if ($diskValues) { [math]::Round(($diskValues | Measure-Object -Average).Average, 1) } else { $null }
    DiskPeakPercent = if ($diskValues) { [math]::Round(($diskValues | Measure-Object -Maximum).Maximum, 1) } else { $null }
    DiskQueueAverage = if ($queueValues) { [math]::Round(($queueValues | Measure-Object -Average).Average, 2) } else { $null }
    DiskQueuePeak = if ($queueValues) { [math]::Round(($queueValues | Measure-Object -Maximum).Maximum, 2) } else { $null }
    AvailableMemoryAverageGB = if ($availableValues) { [math]::Round(($availableValues | Measure-Object -Average).Average / 1024, 2) } else { $null }
    AvailableMemoryMinimumGB = if ($availableValues) { [math]::Round(($availableValues | Measure-Object -Minimum).Minimum / 1024, 2) } else { $null }
    CommitAveragePercent = if ($commitValues) { [math]::Round(($commitValues | Measure-Object -Average).Average, 1) } else { $null }
    PagesPerSecAverage = if ($pagesValues) { [math]::Round(($pagesValues | Measure-Object -Average).Average, 1) } else { $null }
    PagesPerSecPeak = if ($pagesValues) { [math]::Round(($pagesValues | Measure-Object -Maximum).Maximum, 1) } else { $null }
}

$result = [ordered]@{
    collectedAt = (Get-Date).ToString('o')
    stamp = $Stamp
    system = [ordered]@{
        ComputerName = $env:COMPUTERNAME
        Manufacturer = $computer.Manufacturer
        Model = $computer.Model
        PartOfDomain = $computer.PartOfDomain
        Domain = $computer.Domain
        OS = $os.Caption
        OSVersion = $os.Version
        BuildNumber = $os.BuildNumber
        LastBootUpTime = $os.LastBootUpTime.ToString('o')
        UptimeHours = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours, 1)
        CpuName = $processor.Name
        PhysicalCores = $processor.NumberOfCores
        LogicalProcessors = $logicalProcessorCount
        TotalPhysicalMemoryGB = [math]::Round([double]$computer.TotalPhysicalMemory / 1GB, 2)
        FreePhysicalMemoryGB = [math]::Round([double]$os.FreePhysicalMemory / 1MB, 2)
        TotalVirtualMemoryGB = [math]::Round([double]$os.TotalVirtualMemorySize / 1MB, 2)
        FreeVirtualMemoryGB = [math]::Round([double]$os.FreeVirtualMemory / 1MB, 2)
        CommitUsedGB = [math]::Round(
            ([double]$os.TotalVirtualMemorySize - [double]$os.FreeVirtualMemory) / 1MB,
            2
        )
        PageFileStoredGB = [math]::Round([double]$os.SizeStoredInPagingFiles / 1MB, 2)
    }
    summary = $summary
    samples = $samples
    topCpuWindow = @($processCpuWindow | Sort-Object CpuSecondsInWindow -Descending | Select-Object -First 20)
    topWorkingSet = @($processSnapshot | Sort-Object WorkingSetMB -Descending | Select-Object -First 20)
    topPrivateMemory = @($processSnapshot | Sort-Object PrivateMemoryMB -Descending | Select-Object -First 20)
    topCpuSinceStart = @($processSnapshot | Sort-Object CpuSecondsSinceStart -Descending | Select-Object -First 20)
    pageFiles = $pageFiles
    physicalDisks = $physicalDisks
    videoControllers = $videoControllers
    activeNetworkAdapters = $activeAdapters
    criticalSystemEvents24h = $criticalEvents
    targetedSystemEvents7d = $targetedEvents
    bootEvents = $bootEvents
    defenderStatus = $defenderStatus
    defenderPreference = $defenderPreference
    powerScheme = $powerScheme
    sleepStates = $sleepStates
    wslConfigPath = $wslConfigPath
    wslConfig = $wslConfig
    dockerWslProcesses = $dockerWslProcesses
}

$outputPath = Join-Path $OutDir "performance_$Stamp.json"
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $outputPath -Encoding utf8
Write-Host "Coleta salva em $outputPath"
$summary | Format-List
$result.topCpuWindow | Select-Object -First 10 | Format-Table -AutoSize
$result.topWorkingSet | Select-Object -First 10 | Format-Table -AutoSize
$physicalDisks | Format-Table -AutoSize
Write-Output $outputPath
