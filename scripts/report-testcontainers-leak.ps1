<#
.SYNOPSIS
Detecta containers de Testcontainers vazados no Docker local.

.DESCRIPTION
Somente leitura. Runs de teste abortadas podem deixar containers efemeros
(label org.testcontainers=true) rodando sem reaper: em 03/08/2026 foram 15
SQL Servers vivos por mais de duas horas, enchendo a VM do WSL2 e travando a
maquina. Este script denuncia:

- containers de Testcontainers RODANDO ha mais que o limiar (vazamento ativo);
- containers de Testcontainers parados (lixo residual; remocao e manual);
- motor Docker que nao responde dentro do timeout, estado que ja foi o proprio
  sintoma de afogamento e que NAO pode ser lido como "zero vazamentos".

Nada e alterado: nenhum container e parado ou removido por este script.

.EXAMPLE
pwsh -NoProfile -File .\scripts\report-testcontainers-leak.ps1

.EXAMPLE
pwsh -NoProfile -File .\scripts\report-testcontainers-leak.ps1 -ThresholdMinutes 10
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 1440)]
    [int]$ThresholdMinutes = 30,

    [ValidateRange(5, 120)]
    [int]$EngineTimeoutSeconds = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$docker = Get-Command -Name docker -CommandType Application -ErrorAction SilentlyContinue
if (-not $docker) {
    Write-Output 'Docker indisponivel: CLI nao encontrada. Nada a auditar (estado distinto de "zero vazamentos").'
    return
}

# O docker CLI pode PENDURAR quando o motor esta afogado (visto em 03/08/2026).
# Toda chamada vai para um job com timeout, e o estouro do timeout vira um
# estado proprio no relatorio; leitura ausente nunca vira contagem zero.
$job = Start-Job -ScriptBlock {
    $ids = @(docker ps -aq --filter 'label=org.testcontainers=true' 2>$null)
    if ($LASTEXITCODE -ne 0) { return $null }
    if ($ids.Count -eq 0) { return @() }
    docker inspect --format '{{.Id}}|{{.Name}}|{{.State.Status}}|{{.State.StartedAt}}|{{.Config.Image}}' @ids 2>$null
}

$done = Wait-Job -Job $job -Timeout $EngineTimeoutSeconds
if (-not $done) {
    Stop-Job -Job $job
    Remove-Job -Job $job -Force
    Write-Output ("ALERTA: o motor Docker nao respondeu em {0} s. Isso NAO significa ausencia " -f $EngineTimeoutSeconds)
    Write-Output 'de vazamento: em 03/08/2026 o silencio do motor ERA o sintoma do afogamento.'
    Write-Output 'Conferir vmmemWSL no host e considerar inspecao manual quando o motor voltar.'
    return
}

try {
    $raw = @(Receive-Job -Job $job -ErrorAction Stop)
}
catch {
    Remove-Job -Job $job -Force
    Write-Output "Docker respondeu com erro ($($_.Exception.Message)). Conferir o estado do Docker Desktop."
    return
}
Remove-Job -Job $job -Force

if ($raw.Count -eq 1 -and $null -eq $raw[0]) {
    Write-Output 'Docker respondeu com erro na listagem. Conferir o estado do Docker Desktop.'
    return
}

$agora = [datetimeoffset]::UtcNow
$itens = @(
    foreach ($linha in $raw) {
        if ([string]::IsNullOrWhiteSpace([string]$linha)) { continue }
        $parte = [string]$linha -split '\|', 5
        if ($parte.Count -lt 5) { continue }
        $rodando = $parte[2] -eq 'running'
        $idadeMin = $null
        if ($rodando) {
            $inicio = [datetimeoffset]::Parse($parte[3], [Globalization.CultureInfo]::InvariantCulture)
            $idadeMin = [math]::Round(($agora - $inicio.ToUniversalTime()).TotalMinutes, 1)
        }
        [pscustomobject]@{
            Nome     = $parte[1].TrimStart('/')
            Situacao = $parte[2]
            IdadeMin = $idadeMin
            Imagem   = $parte[4]
            Vazado   = $rodando -and $idadeMin -gt $ThresholdMinutes
        }
    }
)

if ($itens.Count -eq 0) {
    Write-Output "Nenhum container de Testcontainers no motor (limiar de vazamento: $ThresholdMinutes min)."
    return
}

$vazados = @($itens | Where-Object -Property Vazado)
$parados = @($itens | Where-Object { $_.Situacao -ne 'running' })
$emTeste = @($itens | Where-Object { $_.Situacao -eq 'running' -and -not $_.Vazado })

if ($vazados.Count -gt 0) {
    Write-Output "VAZAMENTO ATIVO: $($vazados.Count) container(s) de Testcontainers rodando ha mais de $ThresholdMinutes min."
    $vazados | Sort-Object -Property IdadeMin -Descending |
        Format-Table -Property Nome, IdadeMin, Imagem -AutoSize | Out-String -Width 200 | Write-Output
    Write-Output 'Encerramento e remocao sao decisoes do dono da suite; este script nao executa nada.'
}
else {
    Write-Output "Nenhum vazamento ativo (limiar: $ThresholdMinutes min)."
}

if ($emTeste.Count -gt 0) {
    Write-Output "Em teste dentro do limiar: $($emTeste.Count) container(s) recentes, presumidos legitimos."
}

if ($parados.Count -gt 0) {
    Write-Output "Lixo residual: $($parados.Count) container(s) de Testcontainers parados aguardando remocao manual."
}
