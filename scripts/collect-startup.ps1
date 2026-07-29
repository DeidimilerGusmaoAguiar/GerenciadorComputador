[CmdletBinding()]
param(
    [string]$Stamp = (Get-Date -Format 'yyyy-MM-dd_HHmm'),
    [string]$OutDir = (Join-Path $PSScriptRoot '..\reports')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir | Out-Null
}

function Get-RunKeyEntries {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Scope
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    $item = Get-ItemProperty -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $item) {
        return
    }
    foreach ($property in $item.PSObject.Properties) {
        if ($property.Name -like 'PS*') {
            continue
        }
        [pscustomobject]@{
            Scope = $Scope
            RegistryPath = $Path
            Name = $property.Name
            Command = [string]$property.Value
        }
    }
}

function Get-StartupApprovedEntries {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    $item = Get-ItemProperty -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $item) {
        return
    }
    foreach ($property in $item.PSObject.Properties) {
        if ($property.Name -like 'PS*') {
            continue
        }
        $bytes = @($property.Value)
        $stateCode = if ($bytes.Count -gt 0) { [int]$bytes[0] } else { $null }
        $state = switch ($stateCode) {
            2 { 'Enabled' }
            3 { 'Disabled' }
            6 { 'Enabled' }
            7 { 'Disabled' }
            default { 'Unknown' }
        }
        [pscustomobject]@{
            RegistryPath = $Path
            Name = $property.Name
            StateCode = $stateCode
            State = $state
            DataHex = if ($bytes.Count -gt 0) {
                ($bytes | ForEach-Object { $_.ToString('X2') }) -join ''
            } else {
                $null
            }
        }
    }
}

function Get-ScheduledTaskInventory {
    $triggerNames = @{
        0 = 'Event'
        1 = 'Time'
        2 = 'Daily'
        3 = 'Weekly'
        4 = 'Monthly'
        5 = 'MonthlyDOW'
        6 = 'Idle'
        7 = 'Registration'
        8 = 'Boot'
        9 = 'Logon'
        11 = 'SessionStateChange'
        12 = 'Custom'
    }
    $scheduler = New-Object -ComObject 'Schedule.Service'
    $scheduler.Connect()
    $rows = [System.Collections.Generic.List[object]]::new()

    function Visit-TaskFolder {
        param(
            [Parameter(Mandatory)]$Folder,
            [Parameter(Mandatory)]$TargetRows,
            [Parameter(Mandatory)]$TriggerNames
        )
        foreach ($task in @($Folder.GetTasks(0))) {
            $triggers = @(
                foreach ($trigger in @($task.Definition.Triggers)) {
                    $typeCode = [int]$trigger.Type
                    [pscustomobject]@{
                        TypeCode = $typeCode
                        Type = if ($TriggerNames.ContainsKey($typeCode)) {
                            $TriggerNames[$typeCode]
                        } else {
                            "Unknown($typeCode)"
                        }
                        Enabled = $trigger.Enabled
                        StartBoundary = $trigger.StartBoundary
                        EndBoundary = $trigger.EndBoundary
                    }
                }
            )
            if (-not ($triggers | Where-Object Type -in 'Boot', 'Logon')) {
                continue
            }
            $actions = @(
                foreach ($action in @($task.Definition.Actions)) {
                    $execute = $null
                    try { $execute = $action.Path } catch { $execute = $null }
                    [pscustomobject]@{
                        TypeCode = [int]$action.Type
                        Execute = $execute
                    }
                }
            )
            $TargetRows.Add([pscustomobject]@{
                Path = $task.Path
                Name = $task.Name
                StateCode = [int]$task.State
                Enabled = $task.Enabled
                LastRunTime = if ($task.LastRunTime -and $task.LastRunTime.Year -gt 1900) {
                    $task.LastRunTime.ToString('o')
                } else {
                    $null
                }
                NextRunTime = if ($task.NextRunTime -and $task.NextRunTime.Year -gt 1900) {
                    $task.NextRunTime.ToString('o')
                } else {
                    $null
                }
                LastTaskResult = $task.LastTaskResult
                Author = $task.Definition.RegistrationInfo.Author
                Description = $task.Definition.RegistrationInfo.Description
                Triggers = $triggers
                Actions = $actions
            })
        }
        foreach ($subFolder in @($Folder.GetFolders(0))) {
            Visit-TaskFolder -Folder $subFolder -TargetRows $TargetRows -TriggerNames $TriggerNames
        }
    }

    $root = $scheduler.GetFolder('\')
    Visit-TaskFolder -Folder $root -TargetRows $rows -TriggerNames $triggerNames
    return $rows
}

$runKeyDefinitions = @(
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Scope = 'Machine64 Run' }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'; Scope = 'Machine64 RunOnce' }
    @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Scope = 'Machine32 Run' }
    @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce'; Scope = 'Machine32 RunOnce' }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; Scope = 'CurrentUser Run' }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'; Scope = 'CurrentUser RunOnce' }
)
$runKeys = @(
    foreach ($definition in $runKeyDefinitions) {
        Get-RunKeyEntries -Path $definition.Path -Scope $definition.Scope
    }
)

$startupCommands = @(
    Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue |
        Select-Object Name, Command, Location, User
)

$startupFolderPaths = @(
    [pscustomobject]@{
        Scope = 'CurrentUser'
        Path = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
    }
    [pscustomobject]@{
        Scope = 'AllUsers'
        Path = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup'
    }
)
$startupFolders = @(
    foreach ($folder in $startupFolderPaths) {
        if (-not (Test-Path -LiteralPath $folder.Path)) {
            continue
        }
        foreach ($item in Get-ChildItem -LiteralPath $folder.Path -Force -ErrorAction SilentlyContinue) {
            [pscustomobject]@{
                Scope = $folder.Scope
                FolderPath = $folder.Path
                Name = $item.Name
                FullName = $item.FullName
                LengthBytes = if ($item.PSIsContainer) { $null } else { $item.Length }
                LastWriteTime = $item.LastWriteTime.ToString('o')
                IsDirectory = $item.PSIsContainer
            }
        }
    }
)

$services = @(
    Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
        Where-Object StartMode -eq 'Auto' |
        ForEach-Object {
            [pscustomobject]@{
                Name = $_.Name
                DisplayName = $_.DisplayName
                State = $_.State
                Status = $_.Status
                StartMode = $_.StartMode
                StartName = $_.StartName
                ProcessId = $_.ProcessId
                PathName = $_.PathName
                Description = $_.Description
                ServiceType = $_.ServiceType
            }
        } |
        Sort-Object Name
)

$scheduledTasks = @()
$scheduledTaskError = $null
try {
    $scheduledTasks = @(Get-ScheduledTaskInventory)
} catch {
    $scheduledTaskError = $_.Exception.Message
}

$startupApprovedPaths = @(
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'
)
$startupApproved = @(
    foreach ($path in $startupApprovedPaths) {
        Get-StartupApprovedEntries -Path $path
    }
)

$result = [ordered]@{
    collectedAt = (Get-Date).ToString('o')
    stamp = $Stamp
    counts = [ordered]@{
        RunKeyEntries = $runKeys.Count
        CimStartupCommands = $startupCommands.Count
        StartupFolderEntries = $startupFolders.Count
        AutomaticServices = $services.Count
        BootOrLogonScheduledTasks = $scheduledTasks.Count
        StartupApprovedEntries = $startupApproved.Count
    }
    runKeys = $runKeys
    cimStartupCommands = $startupCommands
    startupFolders = $startupFolders
    automaticServices = $services
    bootOrLogonScheduledTasks = $scheduledTasks
    scheduledTaskError = $scheduledTaskError
    startupApproved = $startupApproved
}

$outputPath = Join-Path $OutDir "startup-inventory_$Stamp.json"
$result | ConvertTo-Json -Depth 9 | Set-Content -LiteralPath $outputPath -Encoding utf8
Write-Host "Inventario salvo em $outputPath"
$result.counts | Format-List
$runKeys | Select-Object Scope, Name, Command | Format-Table -Wrap -AutoSize
$startupFolders | Format-Table -AutoSize
$scheduledTasks | Select-Object Path, Enabled, StateCode, LastTaskResult, Author | Format-Table -Wrap -AutoSize
Write-Output $outputPath
