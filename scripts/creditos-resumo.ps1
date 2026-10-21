<#
.SYNOPSIS
Mostra lado a lado as tres fontes que pagam o Claude: plano, credito de API
e credito de sessao na nuvem. Somente leitura.

.DESCRIPTION
Cada fonte paga uma coisa diferente e nao cobre a outra:

- PLANO: sessao interativa e "claude -p" sem chave, rodando no PC. Limite
  por janela de 5 h e por semana, lido do /usage de cada conta (custo zero).
- API: so o que roda com a chave de API da organizacao vinculada ao plano
  (ApiPessoal/ApiDev). Orcamento em local\creditos-api.
- NUVEM: so sessao na nuvem (claude.ai/code, rotinas). Valor unico com
  validade; acabado ou vencido, a sessao na nuvem passa a gastar o PLANO.
  Orcamento em local\creditos-nuvem.

As contas e os diretorios de estado vem de local\creditos-nuvem\orcamento.json
(campo "estado" de cada lado).

.EXAMPLE
pwsh -NoProfile -File .\scripts\creditos-resumo.ps1
#>
[CmdletBinding()]
param(
    [ValidateRange(30, 600)]
    [int]$PrazoSegundos = 90
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$orcNuvem = Join-Path $repoRoot 'local\creditos-nuvem\orcamento.json'

function Get-UsoPlano {
    # /usage e' comando local da CLI: nao gasta limite. Chave de API fora, senao mostraria a API.
    param([string]$Estado)
    $exe = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $exe) { return 'CLI claude nao encontrada no PATH.' }
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $exe.Source
    foreach ($a in @('-p', '/usage', '--output-format', 'json')) { $psi.ArgumentList.Add($a) }
    $psi.WorkingDirectory = [IO.Path]::GetTempPath()
    $psi.UseShellExecute = $false
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.CreateNoWindow = $true
    $psi.Environment['CLAUDE_CONFIG_DIR'] = $Estado
    foreach ($v in @('ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN')) { $null = $psi.Environment.Remove($v) }
    $p = [Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    $saida = $p.StandardOutput.ReadToEndAsync()
    $null = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($PrazoSegundos * 1000)) {
        try { $p.Kill($true) } catch { }
        return "sem resposta em $PrazoSegundos s"
    }
    $p.WaitForExit()
    try { return [string](([string]$saida.Result | ConvertFrom-Json).result) } catch { return [string]$saida.Result }
}

if (-not (Test-Path -LiteralPath $orcNuvem)) { throw "Orcamento de nuvem nao encontrado: $orcNuvem" }
$orc = Get-Content -LiteralPath $orcNuvem -Raw -Encoding UTF8 | ConvertFrom-Json

Write-Host ''
Write-Host '  ===== PLANO (sessao interativa e claude -p sem chave, no PC) =====' -ForegroundColor White
foreach ($lado in @($orc.lados.PSObject.Properties.Name | Sort-Object)) {
    $cfg = $orc.lados.$lado
    if (-not ($cfg.PSObject.Properties.Name -contains 'estado')) { continue }
    Write-Host ''
    Write-Host ("  {0}  ({1})" -f $lado, [string]$cfg.conta)
    $texto = Get-UsoPlano -Estado ([string]$cfg.estado)
    $linhas = @($texto -split "`r?`n" | Where-Object { $_ -match '^(Current session|Current week)' })
    if ($linhas.Count -eq 0) {
        Write-Host ('     leitura falhou: ' + (($texto -replace '\s+', ' ').Trim())) -ForegroundColor Red
        continue
    }
    foreach ($l in $linhas) {
        $cor = 'DarkGray'
        if ($l -match '(\d+)% used' -and [int]$Matches[1] -ge 90) { $cor = 'Red' } elseif ($l -match '(\d+)% used' -and [int]$Matches[1] -ge 75) { $cor = 'Yellow' }
        Write-Host ('     ' + $l.Trim()) -ForegroundColor $cor
    }
}

Write-Host ''
Write-Host '  ===== CREDITO DE API (so ApiPessoal/ApiDev, com a chave) =====' -ForegroundColor White
# ApiSaldo vem do perfil do PowerShell gerado por sync-cli-profiles.ps1.
$api = & pwsh -NoLogo -Command 'if (Get-Command ApiSaldo -ErrorAction SilentlyContinue) { ApiSaldo } else { Write-Output "  ApiSaldo nao existe neste perfil." }' 2>&1
$api | ForEach-Object { Write-Host $_ }

Write-Host '  ===== CREDITO DE NUVEM (so sessao na nuvem; acabado, gasta o PLANO) =====' -ForegroundColor White
& (Join-Path $PSScriptRoot 'nuvem-credito.ps1') -Saldo
