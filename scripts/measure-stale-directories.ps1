<#
.SYNOPSIS
Gera manifesto somente leitura de subdiretorios antigos de uma raiz declarada.

.DESCRIPTION
Considera apenas filhos diretos de Root. Um filho entra no manifesto quando o
nome casa com algum padrao de Include, nao casa com nenhum de Exclude, a ultima
escrita tem pelo menos MinAgeDays dias, nao e reparse point e nao contem o
arquivo marcador (LEIA-ME-NAO-APAGAR.md por padrao). Os criterios ficam gravados
no manifesto para que remove-stale-directories.ps1 os confira de novo no momento
da execucao. Este script nao remove nada.

.EXAMPLE
pwsh -NoProfile -File .\scripts\measure-stale-directories.ps1 `
    -Root 'C:\Repos\meu-projeto' -Include '^\.tmp-' -Exclude '^\.tmp-auth$' -MinAgeDays 7
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Root,

    [Parameter(Mandatory)]
    [string[]]$Include,

    [string[]]$Exclude = @(),

    [ValidateRange(0, 3650)]
    [double]$MinAgeDays = 7,

    [string[]]$MarkerFile = @('LEIA-ME-NAO-APAGAR.md'),

    [switch]$SkipSize,
    [int]$ThrottleLimit = 4,
    [int]$TimeoutSecondsPerDirectory = 300,
    [string]$Label = 'stale',
    [string]$Stamp = (Get-Date -Format 'yyyy-MM-dd_HHmm'),
    [string]$OutDir = (Join-Path $PSScriptRoot '..\reports')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = [IO.Path]::GetFullPath($Root).TrimEnd('\')
$OutDir = [IO.Path]::GetFullPath($OutDir)
if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
    throw "Diretorio nao encontrado: $Root"
}
if ($Root.Length -le 3) {
    throw "Raiz de volume nao e aceita como Root: $Root"
}
if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir | Out-Null
}

$now = Get-Date
$selected = [Collections.Generic.List[object]]::new()
$skipped = [ordered]@{ excluded = 0; tooRecent = 0; reparsePoint = 0; marker = 0; noMatch = 0 }

foreach ($dir in [IO.DirectoryInfo]::new($Root).EnumerateDirectories()) {
    $name = $dir.Name
    if (-not ($Include | Where-Object { $name -match $_ })) { $skipped.noMatch++; continue }
    if ($Exclude | Where-Object { $name -match $_ }) { $skipped.excluded++; continue }
    if (($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $skipped.reparsePoint++; continue }
    if (($now - $dir.LastWriteTime).TotalDays -lt $MinAgeDays) { $skipped.tooRecent++; continue }
    if ($MarkerFile | Where-Object { Test-Path -LiteralPath (Join-Path $dir.FullName $_) }) { $skipped.marker++; continue }
    $selected.Add([pscustomobject]@{
        Path = $dir.FullName
        LastWrite = $dir.LastWriteTime.ToString('o')
        Bytes = $null
    })
}

if (-not $SkipSize -and $selected.Count -gt 0) {
    $sizes = $selected | ForEach-Object -Parallel {
        $psi = [System.Diagnostics.ProcessStartInfo]::new("$env:SystemRoot\System32\diskusage.exe")
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        foreach ($a in '/c', '/d:0', '/x', '/g:0x07', $_.Path) { $null = $psi.ArgumentList.Add($a) }
        $p = [System.Diagnostics.Process]::Start($psi)
        $task = $p.StandardOutput.ReadToEndAsync()
        if (-not $p.WaitForExit($using:TimeoutSecondsPerDirectory * 1000)) { $p.Kill($true) }
        $line = @($task.GetAwaiter().GetResult() -split '\r?\n' | Where-Object { $_ -match '^\d+,\d+,\d+,' }) | Select-Object -First 1
        [pscustomobject]@{ Path = $_.Path; Bytes = if ($line -match '^(\d+),') { [int64]$Matches[1] } else { $null } }
    } -ThrottleLimit $ThrottleLimit
    $byPath = @{}
    $sizes | ForEach-Object { $byPath[$_.Path] = $_.Bytes }
    foreach ($item in $selected) { $item.Bytes = $byPath[$item.Path] }
}

$measured = @($selected | Where-Object { $null -ne $_.Bytes })
$manifest = [ordered]@{
    scannedAt = $now.ToString('o')
    root = $Root
    criteria = [ordered]@{
        include = @($Include)
        exclude = @($Exclude)
        minAgeDays = $MinAgeDays
        markerFile = @($MarkerFile)
    }
    skipped = $skipped
    selectedCount = $selected.Count
    sizeMeasured = (-not $SkipSize)
    totalBytes = [int64](($measured | Measure-Object Bytes -Sum).Sum)
    directories = @($selected)
}

$outputPath = Join-Path $OutDir "stale-dirs_${Label}_$Stamp.json"
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $outputPath -Encoding utf8
Write-Host ("{0} diretorios selecionados, {1:N2} GB medidos. Ignorados: {2}" -f
    $selected.Count, ($manifest.totalBytes / 1GB), (($skipped.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '))
Write-Output $outputPath
