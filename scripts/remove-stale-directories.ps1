<#
.SYNOPSIS
Revalida um manifesto de subdiretorios antigos e remove os que ainda passam.

.DESCRIPTION
Opera em dry-run por padrao. A remocao exige -Execute e ainda respeita
-WhatIf/-Confirm. Aceita o manifesto de measure-stale-directories.ps1
(criteria.include/exclude/minAgeDays/markerFile) e manifestos manuais com
root, directories[].Path e bloqueioRegex.

Cada alvo precisa ser filho direto de ExpectedRoot. Na hora, e nao so no
manifesto, o script confere de novo: nome ainda casa com include, nao casa com
nenhum bloqueio (exclude, bloqueioRegex e BlockPattern), idade minima, ausencia
do arquivo marcador, ausencia de reparse point no alvo e em qualquer
subdiretorio, e nenhum processo vivo com o caminho na linha de comando.
Um item bloqueado e recusado mesmo que esteja no manifesto.

.EXAMPLE
pwsh -NoProfile -File .\scripts\remove-stale-directories.ps1 `
    -ManifestPath .\reports\stale-dirs_tmp_2026-01-01_1200.json `
    -ExpectedRoot 'C:\Repos\meu-projeto'

.EXAMPLE
pwsh -NoProfile -Command "& .\scripts\remove-stale-directories.ps1 -ManifestPath .\reports\stale-dirs_tmp_2026-01-01_1200.json -ExpectedRoot 'C:\Repos\meu-projeto' -BlockPattern '^\.tmp-auth$','^\.tmp-x' -Execute"
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ManifestPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ExpectedRoot,

    [string[]]$BlockPattern = @(),

    [ValidateRange(0, 3650)]
    [double]$MinAgeDays = -1,

    [string[]]$BlockingProcessName = @('devenv', 'MSBuild', 'dotnet', 'VBCSCompiler'),

    [string[]]$BlockingCommandLinePattern = @('\bpytest\b', '-m\s+unittest\b', 'mutmut', 'mutante'),

    [switch]$Execute,

    [ValidateRange(0, 10000000)]
    [int]$MaxDeletes = 0,

    [ValidateRange(5, 3600)]
    [int]$ProcessRefreshSeconds = 30,

    [string]$LogPath = (
        Join-Path $PSScriptRoot "..\reports\cleanup-stale_$(Get-Date -Format 'yyyyMMdd_HHmmss').jsonl"
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
    return [int64][IO.DriveInfo]::new($volumeRoot).AvailableFreeSpace
}

function Write-LogLine {
    param([Parameter(Mandatory)]$Value)

    $script:LogWriter.WriteLine(($Value | ConvertTo-Json -Depth 5 -Compress))
    $script:LogWriter.Flush()
}

function Get-OptionalProperty {
    param($Object, [Parameter(Mandatory)][string]$Name)

    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

# Nomes de filhos diretos da raiz citados na linha de comando de processos vivos.
function Get-ChildNamesInUse {
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($process in Get-CimInstance Win32_Process -Property ProcessId, CommandLine) {
        if ($process.ProcessId -eq $PID -or [string]::IsNullOrEmpty($process.CommandLine)) { continue }
        $commandLine = $process.CommandLine.Replace('/', '\')
        $index = $commandLine.IndexOf($script:RootPrefix, [StringComparison]::OrdinalIgnoreCase)
        while ($index -ge 0) {
            $start = $index + $script:RootPrefix.Length
            $end = $commandLine.IndexOfAny([char[]]@('\', '"', "'", ' ', ';', ','), $start)
            if ($end -lt 0) { $end = $commandLine.Length }
            if ($end -gt $start) { $null = $names.Add($commandLine.Substring($start, $end - $start)) }
            $index = $commandLine.IndexOf($script:RootPrefix, $start, [StringComparison]::OrdinalIgnoreCase)
        }
    }
    return , $names
}

function Find-ReparsePoint {
    param([Parameter(Mandatory)][string]$Path)

    $pending = [Collections.Generic.Stack[IO.DirectoryInfo]]::new()
    $pending.Push([IO.DirectoryInfo]::new($Path))
    $options = [IO.EnumerationOptions]::new()
    $options.AttributesToSkip = [IO.FileAttributes]0
    $options.IgnoreInaccessible = $false
    while ($pending.Count -gt 0) {
        foreach ($child in $pending.Pop().EnumerateDirectories('*', $options)) {
            if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $child.FullName }
            $pending.Push($child)
        }
    }
    return $null
}

function Get-BlockingProcesses {
    $found = [Collections.Generic.List[string]]::new()
    foreach ($process in Get-CimInstance Win32_Process -Property ProcessId, Name, CommandLine) {
        if ($process.ProcessId -eq $PID) { continue }
        $baseName = [IO.Path]::GetFileNameWithoutExtension([string]$process.Name)
        if ($BlockingProcessName | Where-Object { $baseName -eq $_ }) {
            $found.Add("$($process.Name):$($process.ProcessId)")
            continue
        }
        $commandLine = [string]$process.CommandLine
        if ($commandLine -and ($BlockingCommandLinePattern | Where-Object { $commandLine -match $_ })) {
            $found.Add("$($process.Name):$($process.ProcessId)")
        }
    }
    return , $found
}

$resolvedManifestPath = [IO.Path]::GetFullPath($ManifestPath)
$resolvedRoot = [IO.Path]::GetFullPath($ExpectedRoot).TrimEnd('\')
$script:RootPrefix = "$resolvedRoot\"
$resolvedLogPath = [IO.Path]::GetFullPath($LogPath)

if ($resolvedRoot.Length -le 3) {
    throw "Raiz de volume nao e aceita como ExpectedRoot: $resolvedRoot"
}
if (-not (Test-Path -LiteralPath $resolvedManifestPath -PathType Leaf)) {
    throw "Manifesto nao encontrado: $resolvedManifestPath"
}
if (-not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) {
    throw "Raiz esperada nao encontrada: $resolvedRoot"
}

$manifest = Get-Content -LiteralPath $resolvedManifestPath -Raw | ConvertFrom-Json
$manifestRoot = [IO.Path]::GetFullPath([string]$manifest.root).TrimEnd('\')
if (-not $manifestRoot.Equals($resolvedRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "A raiz do manifesto '$manifestRoot' difere da raiz permitida '$resolvedRoot'."
}

$rawTargets = @($manifest.directories)
$declaredCount = Get-OptionalProperty $manifest 'selectedCount'
if ($null -eq $declaredCount) { $declaredCount = Get-OptionalProperty $manifest 'count' }
if ($null -eq $declaredCount -or $rawTargets.Count -ne [int]$declaredCount) {
    throw "A contagem de diretorios do manifesto nao confere: $($rawTargets.Count) itens, declarados '$declaredCount'."
}

$criteria = Get-OptionalProperty $manifest 'criteria'
$includePatterns = @(Get-OptionalProperty $criteria 'include' | Where-Object { $_ })
$blockPatterns = @(
    @(Get-OptionalProperty $criteria 'exclude') +
    @(Get-OptionalProperty $manifest 'bloqueioRegex') +
    $BlockPattern | Where-Object { $_ }
)
$markerFiles = @(Get-OptionalProperty $criteria 'markerFile' | Where-Object { $_ })
if ($markerFiles.Count -eq 0) { $markerFiles = @('LEIA-ME-NAO-APAGAR.md') }
if ($MinAgeDays -lt 0) {
    $manifestAge = Get-OptionalProperty $criteria 'minAgeDays'
    if ($null -eq $manifestAge) {
        throw 'O manifesto nao declara criteria.minAgeDays; informe -MinAgeDays.'
    }
    $MinAgeDays = [double]$manifestAge
}
$regexOptions = [Text.RegularExpressions.RegexOptions]'IgnoreCase, CultureInvariant, Compiled'
$includeRegexes = @($includePatterns | ForEach-Object { [regex]::new($_, $regexOptions) })
$blockRegexes = @($blockPatterns | ForEach-Object { [regex]::new($_, $regexOptions) })

function Get-FirstMatch {
    param([regex[]]$Regexes, [string]$Name)

    foreach ($regex in $Regexes) {
        if ($regex.IsMatch($Name)) { return $regex.ToString() }
    }
    return $null
}

$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$validated = [Collections.Generic.List[object]]::new()
$validationErrors = [Collections.Generic.List[string]]::new()
foreach ($target in $rawTargets) {
    $fullPath = [IO.Path]::GetFullPath([string]$target.Path).TrimEnd('\')
    $parent = [IO.Path]::GetDirectoryName($fullPath)
    if (-not $resolvedRoot.Equals($parent, [StringComparison]::OrdinalIgnoreCase)) {
        $validationErrors.Add("Nao e filho direto da raiz: $fullPath")
    } elseif (-not $seen.Add($fullPath)) {
        $validationErrors.Add("Path duplicado: $fullPath")
    } else {
        $validated.Add([pscustomobject]@{
            Path = $fullPath
            Name = [IO.Path]::GetFileName($fullPath)
            PlannedBytes = Get-OptionalProperty $target 'Bytes'
        })
    }
}
if ($validationErrors.Count -gt 0) {
    $validationErrors | Select-Object -First 20 | ForEach-Object { Write-Error $_ -ErrorAction Continue }
    throw "Manifesto rejeitado: $($validationErrors.Count) erro(s) de validacao."
}

if ($Execute) {
    $blocking = Get-BlockingProcesses
    if ($blocking.Count -gt 0) {
        throw "Processos de build ou teste ativos; limpeza abortada sem excluir nada: $($blocking -join ', ')"
    }
}

$logDirectory = Split-Path -Parent $resolvedLogPath
if (-not (Test-Path -LiteralPath $logDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $logDirectory | Out-Null
}
$script:LogWriter = [IO.StreamWriter]::new($resolvedLogPath, $false, [Text.UTF8Encoding]::new($false))

$mode = if (-not $Execute) { 'dry-run' } elseif ($WhatIfPreference) { 'what-if' } else { 'execute' }
$freeBefore = Get-FreeBytes -Path $resolvedRoot
$sized = @($validated | Where-Object { $null -ne $_.PlannedBytes })
$plannedTotal = if ($sized.Count -gt 0) { [int64]($sized | Measure-Object PlannedBytes -Sum).Sum } else { [int64]0 }
Write-LogLine ([ordered]@{
    recordType = 'header'
    timestamp = (Get-Date).ToString('o')
    mode = $mode
    manifestPath = $resolvedManifestPath
    expectedRoot = $resolvedRoot
    targetCount = $validated.Count
    plannedBytes = $plannedTotal
    minAgeDays = $MinAgeDays
    include = $includePatterns
    block = $blockPatterns
    markerFile = $markerFiles
    freeBytesBefore = $freeBefore
})

$counts = [ordered]@{
    planned = 0; deleted = 0; deferred = 0; skipped = 0; missing = 0
    blocked = 0; tooRecent = 0; marker = 0; reparsePoint = 0; inUse = 0; failed = 0
}
$deletedPlannedBytes = [int64]0
$inUse = Get-ChildNamesInUse
$inUseRefreshedAt = Get-Date
$progressEvery = [Math]::Max(1, [int]($validated.Count / 100))
$index = 0

foreach ($target in $validated) {
    $index++
    if ($index % $progressEvery -eq 0) {
        Write-Progress -Activity 'Revalidando alvos' -Status "$index de $($validated.Count)" `
            -PercentComplete ([int](100 * $index / $validated.Count))
    }
    if (((Get-Date) - $inUseRefreshedAt).TotalSeconds -ge $ProcessRefreshSeconds) {
        $inUse = Get-ChildNamesInUse
        $inUseRefreshedAt = Get-Date
    }

    $status = $null
    $detail = $null
    try {
        $item = [IO.DirectoryInfo]::new($target.Path)
        if (-not $item.Exists) {
            $status = 'missing'
        } elseif ($includeRegexes.Count -gt 0 -and -not (Get-FirstMatch $includeRegexes $target.Name)) {
            $status = 'blocked'; $detail = 'nome nao casa mais com include'
        } elseif ($hit = Get-FirstMatch $blockRegexes $target.Name) {
            $status = 'blocked'; $detail = "casa com bloqueio '$hit'"
        } elseif (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            $status = 'reparsePoint'; $detail = 'o alvo e um reparse point'
        } elseif (([datetime]::Now - $item.LastWriteTime).TotalDays -lt $MinAgeDays) {
            $status = 'tooRecent'; $detail = "escrita em $($item.LastWriteTime.ToString('o'))"
        } elseif ($hit = $markerFiles | Where-Object { [IO.File]::Exists([IO.Path]::Combine($target.Path, $_)) } | Select-Object -First 1) {
            $status = 'marker'; $detail = "contem $hit"
        } elseif ($inUse.Contains($target.Name)) {
            $status = 'inUse'; $detail = 'caminho citado na linha de comando de processo vivo'
        } elseif ($reparse = Find-ReparsePoint -Path $target.Path) {
            $status = 'reparsePoint'; $detail = "contem reparse point: $reparse"
        } elseif (-not $Execute) {
            $status = 'planned'
        } elseif ($MaxDeletes -gt 0 -and $counts.deleted -ge $MaxDeletes) {
            $status = 'deferred'
        } elseif (-not $PSCmdlet.ShouldProcess($target.Path, 'Remover diretorio antigo revalidado')) {
            $status = 'skipped'
        } else {
            # -Force remove somente leitura (objetos do git); as validacoes acima ja correram.
            Remove-Item -LiteralPath $target.Path -Recurse -Force -ErrorAction Stop
            if (Test-Path -LiteralPath $target.Path) { throw 'O diretorio ainda existe apos Remove-Item.' }
            $status = 'deleted'
            if ($null -ne $target.PlannedBytes) { $deletedPlannedBytes += [int64]$target.PlannedBytes }
        }
    } catch {
        $status = 'failed'
        $detail = $_.Exception.Message
    }
    $counts[$status]++

    Write-LogLine ([ordered]@{
        recordType = 'target'
        timestamp = (Get-Date).ToString('o')
        path = $target.Path
        plannedBytes = $target.PlannedBytes
        status = $status
        detail = $detail
    })
}
Write-Progress -Activity 'Revalidando alvos' -Completed

$freeAfter = Get-FreeBytes -Path $resolvedRoot
$summary = [ordered]@{
    recordType = 'summary'
    timestamp = (Get-Date).ToString('o')
    mode = $mode
    targetCount = $validated.Count
}
foreach ($entry in $counts.GetEnumerator()) { $summary[$entry.Key] = $entry.Value }
$summary.plannedBytes = $plannedTotal
$summary.deletedPlannedBytes = $deletedPlannedBytes
$summary.freeBytesBefore = $freeBefore
$summary.freeBytesAfter = $freeAfter
$summary.freeBytesDelta = [int64]($freeAfter - $freeBefore)
$summary.logPath = $resolvedLogPath
Write-LogLine $summary
$script:LogWriter.Dispose()

[pscustomobject]$summary | ConvertTo-Json -Depth 4
