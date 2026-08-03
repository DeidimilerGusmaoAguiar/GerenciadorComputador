<#
.SYNOPSIS
Relatorio pontual de pressao do Docker/WSL2 no terminal.

.DESCRIPTION
Somente leitura. Usa o mesmo coletor do painel (Update-PressureDockerState):
motor que nao responde dentro do prazo aparece como AFOGADO, nunca como zero
containers — em 03/08/2026 o silencio do docker ps era o proprio sintoma do
travamento. Com o motor de pe, faz uma segunda sondagem para medir os nucleos
da VM por delta de CPU; uma leitura unica nao tem delta, e essa ausencia e
informada, nao zerada.

Nada e iniciado, parado ou removido: encerrar a VM, recriar containers ou
compactar VHDX seguem exigindo aprovacao nominal fora deste script.

.EXAMPLE
pwsh -NoProfile -File .\scripts\report-docker-pressure.ps1

.EXAMPLE
pwsh -NoProfile -File .\scripts\report-docker-pressure.ps1 -SampleSeconds 10 -AsJson
#>
[CmdletBinding()]
param(
    [ValidateRange(3, 60)]
    [int]$SampleSeconds = 6,

    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$corePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'lib\pressure-core.ps1'))
if (-not (Test-Path -LiteralPath $corePath -PathType Leaf)) {
    throw "Nucleo do painel ausente: $corePath"
}
. $corePath

$state = New-PressureMonitorState
Update-PressureDockerState -State $state
$docker = $state.DockerState

# Segunda sondagem so quando ha motor respondendo: e ela que da o delta de CPU
# da VM. Motor afogado nao ganha segunda chance aqui — cada tentativa custa o
# prazo inteiro, e o estado ja esta provado.
if ($null -ne $docker -and $docker.EngineState -in @('ocioso', 'ativo')) {
    Start-Sleep -Seconds $SampleSeconds
    $state.DockerRefreshAt = [datetime]::MinValue
    Update-PressureDockerState -State $state
    $docker = $state.DockerState
}

if ($AsJson) {
    $docker | ConvertTo-Json -Depth 5
    return
}

Write-Output ("Estado do motor : {0}" -f $docker.EngineState.ToUpperInvariant())
Write-Output ("Detalhe         : {0}" -f $docker.Detail)
if ($docker.VmmemPresent) {
    $nucleos = if ($null -ne $docker.VmmemCores) {
        '{0:N2} nucleo(s) ocupados' -f $docker.VmmemCores
    } else {
        'sem delta nesta janela'
    }
    Write-Output (
        'VM do WSL2      : vmmem PID {0} — {1}, {2:N0} MB residentes, {3:N0} MB privados' -f
        $docker.VmmemPid, $nucleos, $docker.VmmemWorkingSetMB, $docker.VmmemPrivateMB
    )
}
$wsl = $docker.WslConfig
if ($null -ne $wsl -and $wsl.Present) {
    $reclaim = if ($wsl.ReclaimActive -eq $true) {
        'reclaim {0} ativo' -f $wsl.ReclaimMode
    } elseif (-not [string]::IsNullOrEmpty($wsl.ReclaimMode)) {
        'ATENCAO: autoMemoryReclaim fora de [experimental] — o WSL ignora a chave'
    } else {
        'sem autoMemoryReclaim declarado'
    }
    Write-Output (
        '.wslconfig      : memoria {0} GB, {1} CPUs, swap {2} GB — {3}' -f
        $wsl.MemoryGB, $wsl.Processors, $wsl.SwapGB, $reclaim
    )
}
Write-Output (
    'VHDX de dados   : {0:N1} GB no disco do host (so encolhe com compactacao aprovada)' -f
    $docker.VhdxSizeGB
)

if ($docker.RunningCount -gt 0) {
    Write-Output ''
    Write-Output ("Containers em execucao ({0}), ordenados por CPU:" -f $docker.RunningCount)
    foreach ($container in ($docker.Containers | Sort-Object -Property CpuPercent -Descending)) {
        $teto = if ($container.Unbounded -eq $true) {
            '  [SEM TETO de memoria]'
        } elseif ($null -ne $container.MemoryLimitMB) {
            ' / {0:N0} MB' -f $container.MemoryLimitMB
        } else {
            ''
        }
        Write-Output (
            '  {0,-30} {1,6:N1}% CPU  {2,8:N0} MB{3}' -f
            $container.Name, ($container.CpuPercent ?? 0), ($container.MemoryMB ?? 0), $teto
        )
    }
}

if ($docker.TestcontainersCount -gt 0) {
    Write-Output ''
    if ($docker.RyukPresent) {
        Write-Output ("SUITE EM ANDAMENTO: {0} efemero(s) de Testcontainers com o reaper (ryuk) vivo:" -f $docker.TestcontainersCount)
    } else {
        Write-Output ("VAZAMENTO CONFIRMADO: {0} efemero(s) de Testcontainers SEM reaper (ryuk ausente):" -f $docker.TestcontainersCount)
    }
    foreach ($tc in $docker.Testcontainers) {
        Write-Output ('  {0}  (ha {1})' -f $tc.Name, $tc.RunningFor)
    }
    if (-not $docker.RyukPresent) {
        Write-Output 'A sessao de teste que os criou morreu; a remocao e decisao aprovada, fora deste script.'
    }
    Write-Output 'Detalhe e limiar: pwsh -NoProfile -File .\scripts\report-testcontainers-leak.ps1'
} elseif ($docker.RyukPresent) {
    Write-Output ''
    Write-Output 'Reaper (ryuk) vivo sem efemeros: sessao de Testcontainers ativa, entre containers.'
}

if ($null -ne $docker.DanglingVolumes -and $docker.DanglingVolumes -gt 0) {
    Write-Output ("Volumes sem dono: {0} — remocao e decisao aprovada, fora deste script." -f $docker.DanglingVolumes)
}
