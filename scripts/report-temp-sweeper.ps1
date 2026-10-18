<#
.SYNOPSIS
Mostra se a varredura do %TEMP% esta funcionando e se o residuo esta diminuindo.

.DESCRIPTION
Le reports\temp-sweeper\historico.jsonl, gravado por sweep-temp-residue.ps1, e
responde tres perguntas:

1. A varredura completa? Quantas execucoes terminaram ok, quantas abortaram e
   por que, e ha quanto tempo foi a ultima bem-sucedida.
2. O residuo esta diminuindo na origem? Pastas criadas por dia, por prefixo,
   nos ultimos -Days dias contra os -Days anteriores. E essa taxa que mostra se
   a correcao no codigo que cria as pastas funcionou.
3. O %TEMP% fica estavel? Numero de entradas depois de cada execucao.

So le o historico; nao toca o %TEMP%.

.EXAMPLE
pwsh -NoProfile -File .\scripts\report-temp-sweeper.ps1

.EXAMPLE
pwsh -NoProfile -File .\scripts\report-temp-sweeper.ps1 -Days 3 -Last 20
#>
[CmdletBinding()]
param(
    [AllowEmptyString()]
    [string]$StateDirectory = '',

    [ValidateRange(1, 90)]
    [int]$Days = 7,

    [ValidateRange(1, 500)]
    [int]$Last = 10,

    [ValidateRange(1, 50)]
    [int]$Top = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $StateDirectory) { $StateDirectory = Join-Path $PSScriptRoot '..\reports\temp-sweeper' }
$historyPath = Join-Path ([IO.Path]::GetFullPath($StateDirectory)) 'historico.jsonl'
if (-not (Test-Path -LiteralPath $historyPath)) {
    Write-Output "Sem historico em $historyPath. A varredura ainda nao rodou."
    return
}

$records = @(Get-Content -LiteralPath $historyPath | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json } |
    Where-Object { $_.modo -eq 'execute' })
if ($records.Count -eq 0) {
    Write-Output 'O historico so tem simulacoes; nenhuma execucao real ainda.'
    return
}

$now = Get-Date
$recentStart = $now.AddDays(-$Days)
$previousStart = $now.AddDays(-2 * $Days)
$recent = @($records | Where-Object { [datetime]$_.inicio -ge $recentStart })
$previous = @($records | Where-Object { [datetime]$_.inicio -ge $previousStart -and [datetime]$_.inicio -lt $recentStart })

# 1. A varredura completa?
$lastOk = $records | Where-Object { $_.status -eq 'ok' } | Select-Object -Last 1
Write-Output "== Execucoes (ultimos $Days dias)"
$recent | Group-Object status | Sort-Object Count -Descending | ForEach-Object {
    $reason = ($_.Group | Where-Object { $_.motivo } | Group-Object motivo | Sort-Object Count -Descending | Select-Object -First 1)
    '  {0,-15} {1,3}{2}' -f $_.Name, $_.Count, $(if ($reason) { "   mais comum: $($reason.Name)" } else { '' })
}
if ($null -eq $lastOk) {
    Write-Output '  ATENCAO: nenhuma execucao bem-sucedida no historico.'
} else {
    $hours = ($now - [datetime]$lastOk.inicio).TotalHours
    Write-Output ('  Ultima bem-sucedida: {0:dd/MM HH:mm}, ha {1:N0} h, {2} pastas removidas' -f [datetime]$lastOk.inicio, $hours, $lastOk.removidas)
    if ($hours -gt 48) { Write-Output '  ATENCAO: a varredura nao completa ha mais de 2 dias; veja os motivos acima.' }
}
if ($recent | Where-Object { $_.status -eq 'excesso' }) {
    Write-Output '  ATENCAO: houve grupo acima de maxPorManifesto; o acumulo pede limpeza assistida em lotes.'
}

# 2. O residuo esta diminuindo?
function Get-RatePerDay {
    param([object[]]$Window)

    $hours = if ($Window.Count -gt 0) { [double](($Window | Measure-Object horasJanela -Sum).Sum) } else { 0 }
    $byPrefix = @{}
    foreach ($record in $Window) {
        foreach ($property in $record.criadasNaJanela.PSObject.Properties) {
            $byPrefix[$property.Name] = [double]$byPrefix[$property.Name] + [double]$property.Value
        }
    }
    $rates = @{}
    if ($hours -gt 0) { foreach ($key in $byPrefix.Keys) { $rates[$key] = $byPrefix[$key] * 24 / $hours } }
    return [pscustomobject]@{ Hours = $hours; Rates = $rates; Total = $(if ($hours -gt 0) { ($byPrefix.Values | Measure-Object -Sum).Sum * 24 / $hours } else { $null }) }
}

$recentRate = Get-RatePerDay $recent
$previousRate = Get-RatePerDay $previous
Write-Output ''
Write-Output "== Pastas criadas por dia (ultimos $Days dias x $Days dias antes)"
$fmt = { param($v) if ($null -eq $v) { '-' } else { '{0:N0}' -f $v } }
Write-Output ('  {0,-18} {1,10} {2,12} {3,10}' -f 'prefixo', 'agora/dia', 'antes/dia', 'variacao')
Write-Output ('  {0,-18} {1,10} {2,12} {3,10}' -f 'TOTAL', (& $fmt $recentRate.Total), (& $fmt $previousRate.Total),
    $(if ($recentRate.Total -and $previousRate.Total) { '{0:+0;-0}%' -f (100 * ($recentRate.Total / $previousRate.Total - 1)) } else { '-' }))
$recentRate.Rates.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First $Top | ForEach-Object {
    $before = if ($previousRate.Rates.ContainsKey($_.Key)) { $previousRate.Rates[$_.Key] } else { $null }
    $change = if ($before) { '{0:+0;-0}%' -f (100 * ($_.Value / $before - 1)) } else { '-' }
    '  {0,-18} {1,10} {2,12} {3,10}' -f $_.Key, (& $fmt $_.Value), (& $fmt $before), $change
}
if ($previous.Count -eq 0) { Write-Output "  (sem execucoes no periodo anterior para comparar)" }

# 3. O %TEMP% fica estavel?
Write-Output ''
Write-Output "== Ultimas $Last execucoes"
Write-Output ('  {0,-12} {1,-14} {2,9} {3,9} {4,8} {5,9}' -f 'inicio', 'status', 'criadas', 'janela h', 'removid', '%TEMP%')
$records | Select-Object -Last $Last | ForEach-Object {
    '  {0,-12:dd/MM HH:mm} {1,-14} {2,9} {3,9:N1} {4,8} {5,9}' -f [datetime]$_.inicio, $_.status, $_.criadasTotal, $_.horasJanela, $_.removidas, $_.entradasDepois
}
