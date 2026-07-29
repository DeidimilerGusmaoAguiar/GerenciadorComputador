<#
.SYNOPSIS
Planeja ou cria um ponto de restauracao antes de uma limpeza.

.DESCRIPTION
Opera em dry-run por padrao. A criacao real exige -Execute, elevacao e
confirmacao de ShouldProcess. Antes de alterar a configuracao do System
Restore, exporta a chave correspondente para o diretorio de relatorios.

.EXAMPLE
pwsh -NoProfile -File .\scripts\new-cleanup-checkpoint.ps1

.EXAMPLE
pwsh -NoProfile -File .\scripts\new-cleanup-checkpoint.ps1 `
    -Reason 'pre-cleanup_builds' -Execute
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string]$Reason = "pre-cleanup_$(Get-Date -Format 'yyyyMMdd_HHmmss')",
    [string]$ReportsDir = (Join-Path $PSScriptRoot '..\reports'),
    [ValidatePattern('^[A-Za-z]:\\$')]
    [string]$Drive = "$env:SystemDrive\",
    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$reportsPath = [IO.Path]::GetFullPath($ReportsDir)
$drivePath = [IO.Path]::GetFullPath($Drive)
$description = "computer-cleanup: $Reason"

if (-not $Execute) {
    [pscustomobject]@{
        Mode = 'dry-run'
        Drive = $drivePath
        Description = $description
        ReportsDirectory = $reportsPath
        Actions = @(
            'Export System Restore registry configuration',
            'Enable System Restore for the selected drive',
            'Create a MODIFY_SETTINGS restore point',
            'Append the restore point metadata to a local report'
        )
    } | ConvertTo-Json -Depth 4
    return
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Execute este script em uma sessao elevada (Administrador).'
}
if (-not $PSCmdlet.ShouldProcess(
    $drivePath,
    "Criar ponto de restauracao '$description'"
)) {
    [pscustomobject]@{
        Mode = 'cancelled'
        Drive = $drivePath
        Description = $description
    } | ConvertTo-Json -Depth 3
    return
}
if (-not (Test-Path -LiteralPath $reportsPath -PathType Container)) {
    New-Item -ItemType Directory -Path $reportsPath | Out-Null
}

$now = Get-Date
$existing = @(
    Get-ComputerRestorePoint -ErrorAction SilentlyContinue |
        Where-Object { $_.Description -eq $description } |
        Sort-Object SequenceNumber -Descending
)
if ($existing.Count -gt 0) {
    $latestExisting = $existing[0]
    $existingTime = [Management.ManagementDateTimeConverter]::ToDateTime(
        [string]$latestExisting.CreationTime
    )
    if (($now - $existingTime).TotalMinutes -lt 30) {
        [pscustomobject]@{
            SequenceNumber = [int]$latestExisting.SequenceNumber
            Timestamp = $existingTime.ToString('o')
            Description = $latestExisting.Description
            Reused = $true
            LogPath = (Join-Path $reportsPath 'restore-points.log')
        } | ConvertTo-Json -Depth 3
        exit 0
    }
}

$stamp = $now.ToString('yyyyMMdd_HHmmss')
$registryBackup = Join-Path $reportsPath "reg-systemrestore_$stamp.reg"
$registryKey = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
& reg.exe export $registryKey $registryBackup /y | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Falha ao exportar $registryKey para $registryBackup."
}

Enable-ComputerRestore -Drive $drivePath

$registryProviderPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
if (-not (Test-Path -LiteralPath $registryProviderPath)) {
    New-Item -Path $registryProviderPath | Out-Null
}
$frequencyName = 'SystemRestorePointCreationFrequency'
$frequency = Get-ItemProperty `
    -LiteralPath $registryProviderPath `
    -Name $frequencyName `
    -ErrorAction SilentlyContinue
if ($null -eq $frequency) {
    New-ItemProperty `
        -LiteralPath $registryProviderPath `
        -Name $frequencyName `
        -Value 0 `
        -PropertyType DWord | Out-Null
} else {
    Set-ItemProperty `
        -LiteralPath $registryProviderPath `
        -Name $frequencyName `
        -Value 0
}

Checkpoint-Computer `
    -Description $description `
    -RestorePointType MODIFY_SETTINGS `
    -ErrorAction Stop

$created = Get-ComputerRestorePoint |
    Where-Object { $_.Description -eq $description } |
    Sort-Object SequenceNumber -Descending |
    Select-Object -First 1
if (-not $created) {
    throw "Checkpoint nao encontrado apos a criacao: $description"
}

$createdTime = [Management.ManagementDateTimeConverter]::ToDateTime(
    [string]$created.CreationTime
)
$logPath = Join-Path $reportsPath 'restore-points.log'
$logLine = '{0}  SEQ={1}  {2}  invoker=new-cleanup-checkpoint' -f `
    $createdTime.ToString('yyyy-MM-dd HH:mm:ss'), `
    $created.SequenceNumber, `
    $Reason
Add-Content -LiteralPath $logPath -Value $logLine -Encoding utf8

[pscustomobject]@{
    SequenceNumber = [int]$created.SequenceNumber
    Timestamp = $createdTime.ToString('o')
    Description = $created.Description
    Reused = $false
    RegistryBackup = $registryBackup
    LogPath = $logPath
} | ConvertTo-Json -Depth 3
