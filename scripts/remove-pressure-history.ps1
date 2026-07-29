<#
.SYNOPSIS
Aplica a retencao dos arquivos de historico do painel de pressao.

.DESCRIPTION
Opera em dry-run por padrao. A remocao exige -Execute e ainda respeita
-WhatIf/-Confirm. Somente arquivos `pressure_*.jsonl` contidos no diretorio
informado sao aceitos; reparse points e caminhos fora da raiz sao recusados.

O plano de remocao e calculado por Get-PressureHistoryExpired, que e somente
leitura. Este script e o unico ponto do painel autorizado a apagar historico.

.EXAMPLE
pwsh -NoProfile -File .\scripts\remove-pressure-history.ps1

.EXAMPLE
pwsh -NoProfile -File .\scripts\remove-pressure-history.ps1 -Execute

.EXAMPLE
pwsh -NoProfile -File .\scripts\remove-pressure-history.ps1 -All -Execute
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
param(
    [AllowEmptyString()]
    [string]$Directory = '',

    [ValidateRange(1, 365)]
    [int]$RetentionDays = 7,

    [ValidateRange(1, 4096)]
    [int]$MaxMB = 50,

    [switch]$All,

    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$corePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'lib\pressure-core.ps1'))
if (-not (Test-Path -LiteralPath $corePath -PathType Leaf)) {
    throw "Nucleo do painel ausente: $corePath"
}
. $corePath

$resolvedDirectory = if ([string]::IsNullOrWhiteSpace($Directory)) {
    [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\reports\pressure-history'))
} else {
    [IO.Path]::GetFullPath($Directory)
}

if (-not (Test-Path -LiteralPath $resolvedDirectory -PathType Container)) {
    return [pscustomobject]@{
        Status = 'completed'
        Code = 'directory_absent'
        Message = "Nao ha historico em $resolvedDirectory."
        Directory = $resolvedDirectory
        Planned = @()
        RemovedFiles = @()
        FreedBytes = 0
    }
}

$directoryInfo = Get-Item -LiteralPath $resolvedDirectory
if ($directoryInfo.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
    return [pscustomobject]@{
        Status = 'refused'
        Code = 'reparse_point'
        Message = 'O diretorio de historico e um reparse point; nenhuma remocao foi tentada.'
        Directory = $resolvedDirectory
        Planned = @()
        RemovedFiles = @()
        FreedBytes = 0
    }
}

$now = Get-Date
$planned = if ($All) {
    @(
        Get-ChildItem -LiteralPath $resolvedDirectory -Filter 'pressure_*.jsonl' -File -ErrorAction SilentlyContinue |
            ForEach-Object {
                [pscustomobject]@{
                    Name = $_.Name
                    FullName = $_.FullName
                    Length = [double]$_.Length
                    LastWriteTime = $_.LastWriteTime
                    Reason = 'purga solicitada'
                }
            }
    )
} else {
    @(
        Get-PressureHistoryExpired `
            -Directory $resolvedDirectory `
            -RetentionDays $RetentionDays `
            -MaxBytes ([double]$MaxMB * 1MB) `
            -Now $now
    )
}

$plannedBytes = ($planned | Measure-Object Length -Sum).Sum
if ($null -eq $plannedBytes) {
    $plannedBytes = 0
}

if ($planned.Count -eq 0) {
    return [pscustomobject]@{
        Status = 'completed'
        Code = 'nothing_expired'
        Message = 'Nenhum arquivo de historico excedeu a retencao declarada.'
        Directory = $resolvedDirectory
        Planned = @()
        RemovedFiles = @()
        FreedBytes = 0
    }
}

if (-not $Execute) {
    return [pscustomobject]@{
        Status = 'dry_run'
        Code = 'approval_required'
        Message = "Dry-run: $($planned.Count) arquivo(s), $([math]::Round($plannedBytes / 1MB, 2)) MB. Use -Execute para aplicar."
        Directory = $resolvedDirectory
        Planned = @($planned)
        RemovedFiles = @()
        FreedBytes = 0
    }
}

$directoryPrefix = $resolvedDirectory.TrimEnd('\') + '\'
$removed = [Collections.Generic.List[string]]::new()
$freedBytes = 0.0

foreach ($candidate in $planned) {
    $candidatePath = [IO.Path]::GetFullPath([string]$candidate.FullName)

    # Contencao: o alvo tem de estar dentro da raiz aprovada e ter o nome do padrao.
    if (-not $candidatePath.StartsWith($directoryPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Alvo fora da raiz aprovada: $candidatePath"
    }
    if ([IO.Path]::GetFileName($candidatePath) -notlike 'pressure_*.jsonl') {
        throw "Alvo fora do padrao de historico: $candidatePath"
    }
    if (-not (Test-Path -LiteralPath $candidatePath -PathType Leaf)) {
        continue
    }

    $fileInfo = Get-Item -LiteralPath $candidatePath
    if ($fileInfo.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
        throw "Alvo e um reparse point: $candidatePath"
    }

    if ($PSCmdlet.ShouldProcess($candidatePath, 'Remover arquivo de historico do painel')) {
        $length = [double]$fileInfo.Length
        Remove-Item -LiteralPath $candidatePath -ErrorAction Stop
        $removed.Add([IO.Path]::GetFileName($candidatePath))
        $freedBytes += $length
    }
}

[pscustomobject]@{
    Status = 'completed'
    Code = 'history_trimmed'
    Message = "Removidos $($removed.Count) arquivo(s) de historico."
    Directory = $resolvedDirectory
    Planned = @($planned)
    RemovedFiles = @($removed)
    FreedBytes = $freedBytes
}
