<#
.SYNOPSIS
Mede diretorios regeneraveis de build dentro de uma raiz declarada.

.DESCRIPTION
Localiza somente os nomes informados em DirectoryNames, rejeita reparse points
e grava um manifesto JSON para revisao. Este script nao remove arquivos.

.EXAMPLE
pwsh -NoProfile -File .\scripts\measure-repo-artifacts.ps1 `
    -Root 'C:\Repos\meu-projeto'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Root,

    [string[]]$DirectoryNames = @('bin', 'obj', '.vs', 'TestResults'),
    [int]$ThrottleLimit = 8,
    [int]$TimeoutSecondsPerDirectory = 120,
    [string]$Stamp = (Get-Date -Format 'yyyy-MM-dd_HHmm'),
    [string]$OutDir = (Join-Path $PSScriptRoot '..\reports')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = [IO.Path]::GetFullPath($Root)
if ($Root.Length -gt 3) {
    $Root = $Root.TrimEnd('\')
}
$OutDir = [IO.Path]::GetFullPath($OutDir)

if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
    throw "Diretorio nao encontrado: $Root"
}
if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir | Out-Null
}

$watch = [System.Diagnostics.Stopwatch]::StartNew()
$options = [System.IO.EnumerationOptions]::new()
$options.RecurseSubdirectories = $true
$options.IgnoreInaccessible = $true
$options.ReturnSpecialDirectories = $false
$options.AttributesToSkip = [System.IO.FileAttributes]::ReparsePoint
$options.MaxRecursionDepth = 256

$targetNames = [System.Collections.Generic.HashSet[string]]::new(
    $DirectoryNames,
    [System.StringComparer]::OrdinalIgnoreCase
)
$found = [System.Collections.Generic.List[object]]::new()
$rootInfo = [System.IO.DirectoryInfo]::new($Root)

Write-Host "Localizando diretorios de artefatos em $Root..."
foreach ($directory in $rootInfo.EnumerateDirectories('*', $options)) {
    if ($targetNames.Contains($directory.Name)) {
        $found.Add([pscustomobject]@{
            Path = $directory.FullName.TrimEnd('\')
            Category = $directory.Name
        })
    }
}

# Evita dupla contagem se um alvo estiver contido em outro alvo.
$ordered = @($found | Sort-Object { $_.Path.Length })
$selected = [System.Collections.Generic.List[object]]::new()
foreach ($candidate in $ordered) {
    $insideSelected = $false
    foreach ($parent in $selected) {
        if ($candidate.Path.StartsWith(
            "$($parent.Path)\",
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
            $insideSelected = $true
            break
        }
    }
    if (-not $insideSelected) {
        $selected.Add($candidate)
    }
}

$measurements = @(
    $selected | ForEach-Object -Parallel {
        $target = $_
        $enumOptions = [System.IO.EnumerationOptions]::new()
        $enumOptions.RecurseSubdirectories = $true
        $enumOptions.IgnoreInaccessible = $true
        $enumOptions.ReturnSpecialDirectories = $false
        $enumOptions.AttributesToSkip = [System.IO.FileAttributes]::ReparsePoint
        $enumOptions.MaxRecursionDepth = 256

        $bytes = [int64]0
        $files = [int64]0
        $partial = $false
        $errorText = $null
        $deadline = (Get-Date).AddSeconds($using:TimeoutSecondsPerDirectory)
        $itemWatch = [System.Diagnostics.Stopwatch]::StartNew()

        try {
            $dirInfo = [System.IO.DirectoryInfo]::new($target.Path)
            foreach ($file in $dirInfo.EnumerateFiles('*', $enumOptions)) {
                if ((Get-Date) -ge $deadline) {
                    $partial = $true
                    $errorText = "Timeout de $using:TimeoutSecondsPerDirectory segundos."
                    break
                }
                try {
                    $bytes += [int64]$file.Length
                    $files++
                } catch {
                    continue
                }
            }
        } catch {
            $partial = $true
            $errorText = $_.Exception.Message
        }
        $itemWatch.Stop()

        [pscustomobject]@{
            Category = $target.Category
            Path = $target.Path
            Bytes = $bytes
            GB = [math]::Round($bytes / 1GB, 3)
            FileCount = $files
            DurationSeconds = [math]::Round($itemWatch.Elapsed.TotalSeconds, 1)
            Partial = $partial
            Error = $errorText
        }
    } -ThrottleLimit $ThrottleLimit
)
$watch.Stop()

$byCategory = @(
    $measurements |
        Group-Object Category |
        ForEach-Object {
            $sum = ($_.Group | Measure-Object Bytes -Sum).Sum
            [pscustomobject]@{
                Category = $_.Name
                DirectoryCount = $_.Count
                Bytes = [int64]$sum
                GB = [math]::Round($sum / 1GB, 3)
                PartialCount = @($_.Group | Where-Object Partial).Count
            }
        } |
        Sort-Object Bytes -Descending
)
$totalBytes = ($measurements | Measure-Object Bytes -Sum).Sum

$result = [ordered]@{
    scannedAt = (Get-Date).ToString('o')
    root = $Root
    durationSeconds = [math]::Round($watch.Elapsed.TotalSeconds, 1)
    targetDirectoryNames = $DirectoryNames
    discoveredCount = $found.Count
    selectedNonOverlappingCount = $selected.Count
    totalBytes = [int64]$totalBytes
    totalGB = [math]::Round($totalBytes / 1GB, 3)
    byCategory = $byCategory
    directories = @($measurements | Sort-Object Bytes -Descending)
}

$outputPath = Join-Path $OutDir "repo-artifacts_$Stamp.json"
$result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $outputPath -Encoding utf8
Write-Host "Medicao salva em $outputPath"
$byCategory | Format-Table -AutoSize
$result.directories | Select-Object -First 30 Category, GB, FileCount, Partial, Path | Format-Table -AutoSize
Write-Output $outputPath
