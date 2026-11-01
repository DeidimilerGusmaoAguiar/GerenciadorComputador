<#
.SYNOPSIS
Mede commit, RAM disponivel, espaco livre do disco do sistema e memoria do
Windows Terminal para a faixa de saude do mod saude-maquina. Somente leitura.

.DESCRIPTION
Usa as mesmas fontes do painel de pressao (scripts\lib\pressure-core.ps1):
Win32_PerfFormattedData_PerfOS_Memory para AvailableMBytes e
PercentCommittedBytesInUse. Leitura que falha sai como null, nunca como zero:
leitura ausente nao e recurso zerado.

Grava a leitura em -Cache por troca atomica, para as outras sessoes lerem sem
medir de novo, e a imprime em uma linha JSON.

.EXAMPLE
pwsh -NoProfile -File .\coletar.ps1 -Cache $env:TEMP\gerenciador-saude-maquina.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Cache
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$Cache = [IO.Path]::GetFullPath($Cache)
if (-not $Cache.StartsWith($temp + '\', [StringComparison]::OrdinalIgnoreCase) -or
    [IO.Path]::GetExtension($Cache) -ne '.json') {
    throw "O cache tem de ser um .json dentro de $temp"
}

function Measure-Seguro {
    param([Parameter(Mandatory)][scriptblock]$Bloco)
    try { & $Bloco } catch { $null }
}

$memoria = Measure-Seguro {
    Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -Property AvailableMBytes, PercentCommittedBytesInUse
}
$disco = Measure-Seguro { [IO.DriveInfo]::new($env:SystemDrive) }
$terminal = Measure-Seguro { , @(Get-Process -Name WindowsTerminal -ErrorAction SilentlyContinue) }

$leitura = [ordered]@{
    v = 1
    em = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    commitPct = if ($memoria) { [math]::Round([double]$memoria.PercentCommittedBytesInUse, 1) } else { $null }
    ramLivreGB = if ($memoria) { [math]::Round([double]$memoria.AvailableMBytes / 1024, 2) } else { $null }
    disco = [string]$env:SystemDrive
    discoLivreGB = if ($disco) { [math]::Round($disco.AvailableFreeSpace / 1GB, 1) } else { $null }
    terminalPrivGB = if ($null -ne $terminal) { [math]::Round(($terminal | Measure-Object PrivateMemorySize64 -Sum).Sum / 1GB, 2) } else { $null }
    terminalWsGB = if ($null -ne $terminal) { [math]::Round(($terminal | Measure-Object WorkingSet64 -Sum).Sum / 1GB, 2) } else { $null }
}
$json = $leitura | ConvertTo-Json -Compress

$temporario = '{0}.{1}.tmp' -f $Cache, $PID
[IO.File]::WriteAllText($temporario, $json, [Text.UTF8Encoding]::new($false))
Move-Item -LiteralPath $temporario -Destination $Cache -Force
$json
