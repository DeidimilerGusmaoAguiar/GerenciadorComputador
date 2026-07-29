<#
.SYNOPSIS
Valida um manifesto e remove artefatos regeneraveis de build.

.DESCRIPTION
Opera em dry-run por padrao. A remocao exige -Execute e ainda respeita
-WhatIf/-Confirm. Somente bin, obj, .vs e TestResults sob ExpectedRoot sao
aceitos; reparse points, alvos sobrepostos e manifestos parciais sao recusados.

.EXAMPLE
pwsh -NoProfile -File .\scripts\remove-build-artifacts.ps1 `
    -ManifestPath .\reports\repo-artifacts_2026-01-01_1200.json `
    -ExpectedRoot 'C:\Repos\meu-projeto'

.EXAMPLE
pwsh -NoProfile -File .\scripts\remove-build-artifacts.ps1 `
    -ManifestPath .\reports\repo-artifacts_2026-01-01_1200.json `
    -ExpectedRoot 'C:\Repos\meu-projeto' -Execute -WhatIf
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ManifestPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ExpectedRoot,

    [switch]$Execute,

    [ValidateRange(0, 10000)]
    [int]$MaxDeletes = 0,

    [string]$LogPath = (
        Join-Path $PSScriptRoot "..\reports\cleanup-builds_$(Get-Date -Format 'yyyyMMdd_HHmmss').jsonl"
    )
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-FreeBytes {
    param([Parameter(Mandatory)][string]$Path)

    $volumeRoot = [IO.Path]::GetPathRoot($Path)
    if ([string]::IsNullOrWhiteSpace($volumeRoot)) {
        throw "Nao foi possivel determinar o volume de: $Path"
    }
    $drive = [IO.DriveInfo]::new($volumeRoot)
    return [int64]$drive.AvailableFreeSpace
}

function Write-LogLine {
    param([Parameter(Mandatory)]$Value)

    $jsonLine = $Value | ConvertTo-Json -Depth 5 -Compress
    $script:LogWriter.WriteLine($jsonLine)
    $script:LogWriter.Flush()
}

$allowedNames = [Collections.Generic.HashSet[string]]::new(
    [string[]]@('bin', 'obj', '.vs', 'TestResults'),
    [StringComparer]::OrdinalIgnoreCase
)
$resolvedManifestPath = [IO.Path]::GetFullPath($ManifestPath)
$resolvedRoot = [IO.Path]::GetFullPath($ExpectedRoot).TrimEnd('\')
$rootPrefix = "$resolvedRoot\"
$script:ResolvedLogPath = [IO.Path]::GetFullPath($LogPath)

if (-not (Test-Path -LiteralPath $resolvedManifestPath -PathType Leaf)) {
    throw "Manifesto nao encontrado: $resolvedManifestPath"
}
if (-not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) {
    throw "Raiz esperada nao encontrada: $resolvedRoot"
}

$logDirectory = Split-Path -Parent $script:ResolvedLogPath
if (-not (Test-Path -LiteralPath $logDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $logDirectory | Out-Null
}
$utf8WithoutBom = [Text.UTF8Encoding]::new($false)
$script:LogWriter = [IO.StreamWriter]::new(
    $script:ResolvedLogPath,
    $false,
    $utf8WithoutBom
)

$manifest = Get-Content -LiteralPath $resolvedManifestPath -Raw | ConvertFrom-Json
$manifestRoot = [IO.Path]::GetFullPath([string]$manifest.root).TrimEnd('\')
if (-not $manifestRoot.Equals($resolvedRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "A raiz do manifesto '$manifestRoot' difere da raiz permitida '$resolvedRoot'."
}

$rawTargets = @($manifest.directories)
if ($rawTargets.Count -ne [int]$manifest.selectedNonOverlappingCount) {
    throw 'A contagem de diretorios do manifesto nao confere.'
}
if (@($rawTargets | Where-Object { $_.Partial }).Count -gt 0) {
    throw 'O manifesto contem medicoes parciais; gere um novo inventario completo.'
}

$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$validated = [Collections.Generic.List[object]]::new()
$validationErrors = [Collections.Generic.List[string]]::new()

foreach ($target in $rawTargets) {
    try {
        $fullPath = [IO.Path]::GetFullPath([string]$target.Path).TrimEnd('\')
        $category = [string]$target.Category
        $leaf = [IO.Path]::GetFileName($fullPath)

        if (-not $fullPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Fora da raiz permitida: $fullPath"
        }
        if (-not $allowedNames.Contains($category)) {
            throw "Categoria nao permitida '$category': $fullPath"
        }
        if (-not $leaf.Equals($category, [StringComparison]::OrdinalIgnoreCase)) {
            throw "O nome final '$leaf' difere da categoria '$category': $fullPath"
        }
        if (-not $seen.Add($fullPath)) {
            throw "Path duplicado: $fullPath"
        }

        $validated.Add([pscustomobject]@{
            Category = $category
            Path = $fullPath
            PlannedBytes = [int64]$target.Bytes
        })
    } catch {
        $validationErrors.Add($_.Exception.Message)
    }
}

foreach ($target in $validated) {
    $parentPath = [IO.Path]::GetDirectoryName($target.Path)
    while (
        $parentPath -and
        $parentPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)
    ) {
        if ($seen.Contains($parentPath)) {
            $validationErrors.Add(
                "Alvos sobrepostos: '$parentPath' e '$($target.Path)'."
            )
            break
        }
        $parentPath = [IO.Path]::GetDirectoryName($parentPath)
    }
}

if ($validationErrors.Count -gt 0) {
    $validationErrors | ForEach-Object { Write-Error $_ }
    throw "Manifesto rejeitado: $($validationErrors.Count) erro(s) de validacao."
}

if ($Execute) {
    $activeBuildProcesses = @(
        Get-Process -ErrorAction SilentlyContinue |
            Where-Object { $_.ProcessName -match '^(devenv|MSBuild|dotnet|VBCSCompiler)$' }
    )
    if ($activeBuildProcesses.Count -gt 0) {
        $names = ($activeBuildProcesses | ForEach-Object { "$($_.ProcessName):$($_.Id)" }) -join ', '
        throw "Processos de build ativos; limpeza abortada sem excluir nada: $names"
    }
}

$freeBefore = Get-FreeBytes -Path $resolvedRoot
$mode = if (-not $Execute) {
    'dry-run'
} elseif ($WhatIfPreference) {
    'what-if'
} else {
    'execute'
}
Write-LogLine ([ordered]@{
    recordType = 'header'
    timestamp = (Get-Date).ToString('o')
    mode = $mode
    manifestPath = $resolvedManifestPath
    expectedRoot = $resolvedRoot
    targetCount = $validated.Count
    plannedBytes = [int64](($validated | Measure-Object PlannedBytes -Sum).Sum)
    freeBytesBefore = $freeBefore
})

$deleted = 0
$deferred = 0
$skipped = 0
$missing = 0
$failed = 0
$planned = 0
$deletedPlannedBytes = [int64]0

foreach ($target in $validated) {
    $status = 'planned'
    $errorText = $null

    if (-not (Test-Path -LiteralPath $target.Path -PathType Container)) {
        $status = 'missing'
        $missing++
    } elseif (-not $Execute) {
        $planned++
    } elseif ($MaxDeletes -gt 0 -and $deleted -ge $MaxDeletes) {
        $status = 'deferred'
        $deferred++
    } elseif (-not $PSCmdlet.ShouldProcess(
        $target.Path,
        "Remover diretorio regeneravel '$($target.Category)'"
    )) {
        $status = 'skipped'
        $skipped++
    } else {
        try {
            $item = Get-Item -LiteralPath $target.Path -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'Alvo e um reparse point; exclusao recusada.'
            }

            Remove-Item -LiteralPath $target.Path -Recurse -Force -ErrorAction Stop
            if (Test-Path -LiteralPath $target.Path) {
                throw 'O diretorio ainda existe apos Remove-Item.'
            }

            $status = 'deleted'
            $deleted++
            $deletedPlannedBytes += [int64]$target.PlannedBytes
        } catch {
            $status = 'failed'
            $failed++
            $errorText = $_.Exception.Message
        }
    }

    Write-LogLine ([ordered]@{
        recordType = 'target'
        timestamp = (Get-Date).ToString('o')
        category = $target.Category
        path = $target.Path
        plannedBytes = [int64]$target.PlannedBytes
        status = $status
        error = $errorText
    })
}

$freeAfter = Get-FreeBytes -Path $resolvedRoot
$summary = [ordered]@{
    recordType = 'summary'
    timestamp = (Get-Date).ToString('o')
    mode = $mode
    targetCount = $validated.Count
    planned = $planned
    deleted = $deleted
    deferred = $deferred
    skipped = $skipped
    missing = $missing
    failed = $failed
    deletedPlannedBytes = $deletedPlannedBytes
    freeBytesBefore = $freeBefore
    freeBytesAfter = $freeAfter
    freeBytesDelta = [int64]($freeAfter - $freeBefore)
    logPath = $script:ResolvedLogPath
}
Write-LogLine $summary
$script:LogWriter.Dispose()

[pscustomobject]$summary | ConvertTo-Json -Depth 4
