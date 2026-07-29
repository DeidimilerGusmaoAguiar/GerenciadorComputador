[CmdletBinding()]
param(
    [string]$Drive = 'C:',
    [int]$BigFileMB = 500,
    [int]$AggregateDepth = 6,
    [int]$MaxScanMinutes = 6,
    [string]$Stamp = (Get-Date -Format 'yyyy-MM-dd_HHmm'),
    [string]$OutDir = (Join-Path $PSScriptRoot '..\reports')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir | Out-Null
}

$driveId = $Drive.TrimEnd('\')
$rootPath = "$driveId\"
$outputPath = Join-Path $OutDir "disk-investigation_$Stamp.json"
$logicalDisks = @(
    Get-CimInstance Win32_LogicalDisk |
        ForEach-Object {
            [pscustomobject]@{
                DeviceId  = $_.DeviceID
                VolumeName = $_.VolumeName
                FileSystem = $_.FileSystem
                DriveType = $_.DriveType
                SizeBytes = [int64]$_.Size
                FreeBytes = [int64]$_.FreeSpace
                SizeGB    = [math]::Round([double]$_.Size / 1GB, 2)
                FreeGB    = [math]::Round([double]$_.FreeSpace / 1GB, 2)
                FreePct   = if ($_.Size) {
                    [math]::Round(100 * [double]$_.FreeSpace / [double]$_.Size, 2)
                } else {
                    $null
                }
            }
        }
)
$targetVolume = $logicalDisks | Where-Object DeviceId -eq $driveId
if (-not $targetVolume) {
    throw "Volume $driveId nao encontrado."
}

$enumOptions = [System.IO.EnumerationOptions]::new()
$enumOptions.RecurseSubdirectories = $true
$enumOptions.IgnoreInaccessible = $true
$enumOptions.ReturnSpecialDirectories = $false
$enumOptions.AttributesToSkip = [System.IO.FileAttributes]::ReparsePoint
$enumOptions.MaxRecursionDepth = 256

$folderBytes = [System.Collections.Generic.Dictionary[string, int64]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)
$folderDepth = [System.Collections.Generic.Dictionary[string, int]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)
$largeFiles = [System.Collections.Generic.List[object]]::new()
$rootFiles = [System.Collections.Generic.List[object]]::new()

$fileCount = [int64]0
$scannedBytes = [int64]0
$metadataErrors = [int64]0
$partial = $false
$deadline = (Get-Date).AddMinutes($MaxScanMinutes)
$scanWatch = [System.Diagnostics.Stopwatch]::StartNew()
$rootLength = $rootPath.Length

Write-Host "Enumerando metadados em $rootPath (sem abrir conteudo de arquivos)..."
$rootInfo = [System.IO.DirectoryInfo]::new($rootPath)
try {
    foreach ($file in $rootInfo.EnumerateFiles('*', $enumOptions)) {
        if ((Get-Date) -ge $deadline) {
            $partial = $true
            break
        }

        try {
            $length = [int64]$file.Length
            $fullName = $file.FullName
            $lastWriteTime = $file.LastWriteTime
        } catch {
            $metadataErrors++
            continue
        }

        $fileCount++
        $scannedBytes += $length

        $relative = $fullName.Substring($rootLength)
        $parts = $relative -split '[\\/]'
        $directoryPartCount = [math]::Max(0, $parts.Count - 1)
        $depthLimit = [math]::Min($AggregateDepth, $directoryPartCount)

        for ($depth = 1; $depth -le $depthLimit; $depth++) {
            $relativeFolder = [string]::Join('\', $parts[0..($depth - 1)])
            $folderPath = Join-Path $rootPath $relativeFolder
            if ($folderBytes.ContainsKey($folderPath)) {
                $folderBytes[$folderPath] += $length
            } else {
                $folderBytes[$folderPath] = $length
                $folderDepth[$folderPath] = $depth
            }
        }

        if ($length -ge ($BigFileMB * 1MB)) {
            $largeFiles.Add([pscustomobject]@{
                Path          = $fullName
                Bytes         = $length
                GB            = [math]::Round($length / 1GB, 3)
                LastWriteTime = $lastWriteTime.ToString('o')
                Extension     = $file.Extension
            })
        }

        if ($directoryPartCount -eq 0) {
            $rootFiles.Add([pscustomobject]@{
                Path          = $fullName
                Bytes         = $length
                GB            = [math]::Round($length / 1GB, 3)
                LastWriteTime = $lastWriteTime.ToString('o')
            })
        }

        if (($fileCount % 100000) -eq 0) {
            Write-Host ("  {0:N0} arquivos, {1:N1} GB de tamanho logico..." -f $fileCount, ($scannedBytes / 1GB))
        }
    }
} catch {
    $partial = $true
    Write-Warning "Enumeracao global interrompida: $($_.Exception.Message)"
}
$scanWatch.Stop()

$folderRows = @(
    foreach ($entry in $folderBytes.GetEnumerator()) {
        [pscustomobject]@{
            Path  = $entry.Key
            Bytes = [int64]$entry.Value
            GB    = [math]::Round($entry.Value / 1GB, 3)
            Depth = $folderDepth[$entry.Key]
        }
    }
)
$topFolders = @($folderRows | Sort-Object Bytes -Descending | Select-Object -First 100)
$topLevelFolders = @(
    $folderRows |
        Where-Object Depth -eq 1 |
        Sort-Object Bytes -Descending
)

function Measure-FolderMetadata {
    param(
        [Parameter(Mandatory)]
        [string]$LiteralPath,
        [int]$TimeoutSeconds = 120
    )

    if (-not (Test-Path -LiteralPath $LiteralPath -PathType Container)) {
        return [pscustomobject]@{
            Exists = $false
            Bytes = [int64]0
            FileCount = [int64]0
            Partial = $false
            Error = $null
        }
    }

    $normalized = [System.IO.Path]::GetFullPath($LiteralPath).TrimEnd('\')
    if ($folderBytes.ContainsKey($normalized)) {
        return [pscustomobject]@{
            Exists = $true
            Bytes = [int64]$folderBytes[$normalized]
            FileCount = $null
            Partial = $partial
            Error = if ($partial) { 'Valor herdado de varredura global parcial.' } else { $null }
        }
    }

    $bytes = [int64]0
    $count = [int64]0
    $isPartial = $false
    $errorText = $null
    $pathDeadline = (Get-Date).AddSeconds($TimeoutSeconds)
    try {
        $dirInfo = [System.IO.DirectoryInfo]::new($normalized)
        foreach ($item in $dirInfo.EnumerateFiles('*', $enumOptions)) {
            if ((Get-Date) -ge $pathDeadline) {
                $isPartial = $true
                $errorText = "Timeout de $TimeoutSeconds segundos."
                break
            }
            try {
                $bytes += [int64]$item.Length
                $count++
            } catch {
                continue
            }
        }
    } catch {
        $isPartial = $true
        $errorText = $_.Exception.Message
    }

    [pscustomobject]@{
        Exists = $true
        Bytes = $bytes
        FileCount = $count
        Partial = $isPartial
        Error = $errorText
    }
}

$profile = $env:USERPROFILE
$local = $env:LOCALAPPDATA
$roaming = $env:APPDATA
$knownPathMap = [ordered]@{
    'Windows Component Store (nao apagar manualmente)' = "$env:SystemRoot\WinSxS"
    'Windows Installer cache (nao apagar manualmente)' = "$env:SystemRoot\Installer"
    'Windows Update download cache' = "$env:SystemRoot\SoftwareDistribution\Download"
    'Windows Temp' = "$env:SystemRoot\Temp"
    'User Temp' = "$local\Temp"
    'Recycle Bin' = "$driveId\`$Recycle.Bin"
    'C Temp' = "$driveId\Temp"
    'Downloads' = "$profile\Downloads"
    'Docker WSL' = "$local\Docker\wsl"
    'WSL distro storage' = "$local\wsl"
    'NuGet packages' = "$profile\.nuget\packages"
    'npm cache' = "$local\npm-cache"
    'pip cache' = "$local\pip\Cache"
    'Cargo registry' = "$profile\.cargo\registry"
    'Claude data (nao limpar automaticamente)' = "$profile\.claude"
    'Codex data' = "$profile\.codex"
    'Gemini data' = "$profile\.gemini"
    'Grok data' = "$profile\.grok"
    'Visual Studio local data' = "$local\Microsoft\VisualStudio"
    'Android SDK' = "$local\Android\Sdk"
    'UWP package data' = "$local\Packages"
    'Edge default cache' = "$local\Microsoft\Edge\User Data\Default\Cache"
    'Chrome default cache' = "$local\Google\Chrome\User Data\Default\Cache"
    'Firefox local profiles' = "$local\Mozilla\Firefox\Profiles"
    'New Teams local cache' = "$local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache"
    'Classic Teams roaming data' = "$roaming\Microsoft\Teams"
    'Discord roaming data' = "$roaming\discord"
    'Slack roaming data' = "$roaming\Slack"
}

$knownLocations = @(
    foreach ($name in $knownPathMap.Keys) {
        $path = $knownPathMap[$name]
        $measurement = Measure-FolderMetadata -LiteralPath $path
        [pscustomobject]@{
            Name      = $name
            Path      = $path
            Exists    = $measurement.Exists
            Bytes     = [int64]$measurement.Bytes
            GB        = [math]::Round($measurement.Bytes / 1GB, 3)
            FileCount = $measurement.FileCount
            Partial   = $measurement.Partial
            Error     = $measurement.Error
        }
    }
)

$result = [ordered]@{
    scannedAt = (Get-Date).ToString('o')
    stamp = $Stamp
    scan = [ordered]@{
        root = $rootPath
        durationSeconds = [math]::Round($scanWatch.Elapsed.TotalSeconds, 1)
        fileCount = $fileCount
        scannedLogicalBytes = $scannedBytes
        scannedLogicalGB = [math]::Round($scannedBytes / 1GB, 2)
        partial = $partial
        maxScanMinutes = $MaxScanMinutes
        metadataErrors = $metadataErrors
        reparsePointsSkipped = $true
        note = 'Tamanhos sao logicos; hardlinks podem causar diferenca em relacao ao espaco fisico usado.'
    }
    volumes = $logicalDisks
    targetVolume = $targetVolume
    topLevelFolders = $topLevelFolders
    topFolders = $topFolders
    largeFiles = @($largeFiles | Sort-Object Bytes -Descending | Select-Object -First 50)
    rootFiles = @($rootFiles | Sort-Object Bytes -Descending)
    knownLocations = @($knownLocations | Sort-Object Bytes -Descending)
}

$result | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $outputPath -Encoding utf8
Write-Host "Inventario salvo em $outputPath"
Write-Host ("Varredura: {0:N0} arquivos, {1:N2} GB logicos, {2:N1}s, parcial={3}" -f $fileCount, ($scannedBytes / 1GB), $scanWatch.Elapsed.TotalSeconds, $partial)
Write-Output $outputPath
