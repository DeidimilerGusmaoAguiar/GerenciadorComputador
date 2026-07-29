<#
.SYNOPSIS
Gera relatorio local de cobertura das exclusoes do antimalware.

.DESCRIPTION
Somente leitura. Cruza os diretorios de estado das CLIs de IA e os caminhos do
toolchain Node com as exclusoes declaradas, mede volume de arquivos e monta o
bloco pronto para anexar a um chamado.

O relatorio contem caminhos completos, nome de usuario e nomes de sistemas
internos. Ele e gravado em reports\, que e ignorado pelo Git, e nao deve ser
versionado nem publicado fora da organizacao.

Nenhuma configuracao de antimalware e alterada. Em maquina gerenciada essa
decisao e da organizacao, e privilegio local nao equivale a autorizacao.

.EXAMPLE
pwsh -NoProfile -File .\scripts\report-exclusion-coverage.ps1

.EXAMPLE
pwsh -NoProfile -File .\scripts\report-exclusion-coverage.ps1 -ExtraRoots 'C:\Repos'
#>
[CmdletBinding()]
param(
    [string[]]$ExtraRoots = @(),

    [switch]$SkipSizes,

    [AllowEmptyString()]
    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$corePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'lib\pressure-core.ps1'))
if (-not (Test-Path -LiteralPath $corePath -PathType Leaf)) {
    throw "Nucleo do painel ausente: $corePath"
}
. $corePath

function Measure-CoverageTarget {
    param([Parameter(Mandatory)][string]$Path)

    if ($SkipSizes -or -not (Test-Path -LiteralPath $Path -PathType Container)) {
        return [pscustomobject]@{ Files = $null; MB = $null; LastWrite = $null }
    }

    $files = @(
        Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue
    )
    $bytes = 0.0
    $last = [datetime]::MinValue
    foreach ($file in $files) {
        $bytes += [double]$file.Length
        if ($file.LastWriteTime -gt $last) {
            $last = $file.LastWriteTime
        }
    }

    [pscustomobject]@{
        Files = $files.Count
        MB = [math]::Round($bytes / 1MB, 0)
        LastWrite = if ($last -gt [datetime]::MinValue) { $last } else { $null }
    }
}

$preference = $null
$status = $null
try {
    $preference = Get-CimInstance `
        -Namespace root/Microsoft/Windows/Defender `
        -ClassName MSFT_MpPreference `
        -ErrorAction Stop |
        Select-Object -First 1 ExclusionPath, ExclusionProcess, ExclusionExtension,
            ScanScheduleDay, ScanScheduleTime, ScanOnlyIfIdleEnabled,
            DisableCatchupFullScan
} catch {
    $preference = $null
}
try {
    $status = Get-CimInstance `
        -Namespace root/Microsoft/Windows/Defender `
        -ClassName MSFT_MpComputerStatus `
        -ErrorAction Stop |
        Select-Object -First 1 RealTimeProtectionEnabled, FullScanStartTime, FullScanEndTime
} catch {
    $status = $null
}

if ($null -eq $preference) {
    throw 'O provedor do antimalware nao respondeu; nao ha lista de exclusoes para comparar.'
}

$roots = @(@($env:USERPROFILE) + @($ExtraRoots | Where-Object { $_ }))
$homes = @(
    Get-PressureCliHomeCandidates `
        -Roots $roots `
        -EnvironmentHomes @($env:CLAUDE_CONFIG_DIR, $env:CODEX_HOME)
)
$coverage = @(
    Get-PressureCliHomeCoverage `
        -Homes $homes `
        -ExclusionPath $preference.ExclusionPath `
        -ExclusionProcess $preference.ExclusionProcess
)
$defender = Get-PressureDefenderState `
    -Status $status `
    -Preference $preference `
    -CliHomes $homes

$now = Get-Date
$resolvedOutput = if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    [IO.Path]::GetFullPath(
        (Join-Path $PSScriptRoot ("..\reports\cobertura-exclusoes_{0:yyyy-MM-dd_HHmm}.md" -f $now))
    )
} else {
    [IO.Path]::GetFullPath($OutputPath)
}
$outputDirectory = [IO.Path]::GetDirectoryName($resolvedOutput)
if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

$linhas = [Collections.Generic.List[string]]::new()
$linhas.Add(("# Cobertura das exclusoes do antimalware — {0:dd/MM/yyyy HH:mm}" -f $now))
$linhas.Add('')
$linhas.Add('> Dado local. Contem caminhos completos e nomes de sistemas internos.')
$linhas.Add('> **Nao versionar.** `reports\` e ignorado pelo Git.')
$linhas.Add('')
$linhas.Add('## Configuracao vigente')
$linhas.Add('')
$linhas.Add(('- Exclusoes: {0} caminhos, {1} processos, {2} extensoes' -f
    @($preference.ExclusionPath).Count,
    @($preference.ExclusionProcess).Count,
    @($preference.ExclusionExtension).Count))
$linhas.Add(('- Protecao em tempo real: {0}' -f $defender.RealtimeEnabled))
$linhas.Add(('- Varredura completa agendada: {0} -> {1}' -f $defender.ScheduleDayName, $defender.NextScheduledScan))
$linhas.Add(('- ScanOnlyIfIdle: {0} | catch-up desligado: {1}' -f $defender.ScanOnlyIfIdle, $defender.CatchupDisabled))
$linhas.Add(('- Varredura em andamento: {0}' -f $defender.ScanInProgress))
$linhas.Add('')

$linhas.Add('## Perfis de CLI de IA')
$linhas.Add('')
$linhas.Add('| Caminho completo | Arquivos | MB | Ultima escrita | Cobertura |')
$linhas.Add('|---|---:|---:|---|---|')

$totalFiles = 0
$totalMB = 0
$expostos = [Collections.Generic.List[string]]::new()
foreach ($entry in $coverage) {
    # $home e variavel automatica somente-leitura do PowerShell.
    $cliHome = @($homes | Where-Object { $_.Label -eq $entry.Label } | Select-Object -First 1)
    $path = if ($cliHome.Count -gt 0) { [string]$cliHome[0].Path } else { [string]$entry.Label }
    $medida = Measure-CoverageTarget -Path $path
    if ($null -ne $medida.Files) {
        $totalFiles += $medida.Files
        $totalMB += $medida.MB
    }
    $situacao = if ($entry.Covered) { "coberto por $($entry.CoveredBy)" } else { '**exposto**' }
    if (-not $entry.Covered) {
        $expostos.Add($path)
    }
    $linhas.Add(('| `{0}` | {1} | {2} | {3} | {4} |' -f
        $path,
        $(if ($null -ne $medida.Files) { $medida.Files } else { '-' }),
        $(if ($null -ne $medida.MB) { $medida.MB } else { '-' }),
        $(if ($null -ne $medida.LastWrite) { $medida.LastWrite.ToString('dd/MM HH:mm') } else { 'vazio' }),
        $situacao))
}
$linhas.Add('')
if (-not $SkipSizes) {
    $linhas.Add(('Total medido: **{0} arquivos, {1} MB**.' -f $totalFiles, $totalMB))
    $linhas.Add('')
}

$linhas.Add('## Caminhos do toolchain')
$linhas.Add('')
if (@($defender.ToolchainGaps).Count -eq 0) {
    $linhas.Add('Nenhuma lacuna: runtime, pacotes globais e cache estao cobertos por caminho ou por processo.')
} else {
    $linhas.Add('| Item | Situacao |')
    $linhas.Add('|---|---|')
    foreach ($gap in $defender.ToolchainGaps) {
        $linhas.Add(('| {0} | **exposto** |' -f $gap.Label))
    }
}
$linhas.Add('')

if ($expostos.Count -gt 0) {
    $linhas.Add('## Bloco para o chamado')
    $linhas.Add('')
    $linhas.Add('Caminhos sem cobertura, para incluir em `ExclusionPath`:')
    $linhas.Add('')
    $linhas.Add('```')
    foreach ($path in $expostos) {
        $linhas.Add($path)
    }
    $linhas.Add('```')
    $linhas.Add('')
    $linhas.Add('Ressalva a declarar: excluir caminhos que executam codigo de terceiros')
    $linhas.Add('reduz a cobertura real do antivirus. E troca de risco, nao ganho sem custo.')
    $linhas.Add('A decisao cabe a area de seguranca.')
    $linhas.Add('')
}

$linhas.Add('## Metodo')
$linhas.Add('')
$linhas.Add('Leitura por classes CIM nativas (`MSFT_MpPreference`, `MSFT_MpComputerStatus`).')
$linhas.Add('Cobertura avaliada por contencao de caminho, com curinga valendo um unico')
$linhas.Add('segmento; exclusao de processo considerada apenas para o binario correspondente.')
$linhas.Add('Nenhuma configuracao foi alterada.')

[IO.File]::WriteAllLines(
    $resolvedOutput,
    [string[]]$linhas.ToArray(),
    [Text.UTF8Encoding]::new($false)
)

[pscustomobject]@{
    Status = 'completed'
    Report = $resolvedOutput
    ProfilesFound = @($coverage).Count
    ProfilesExposed = $expostos.Count
    ToolchainGaps = @($defender.ToolchainGaps).Count
    MeasuredFiles = $(if ($SkipSizes) { $null } else { $totalFiles })
    MeasuredMB = $(if ($SkipSizes) { $null } else { $totalMB })
    NextScheduledScan = $defender.NextScheduledScan
}
