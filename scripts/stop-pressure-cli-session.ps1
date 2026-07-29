<#
.SYNOPSIS
Revalida e encerra uma árvore de CLI órfã identificada pelo painel Pulso.

.DESCRIPTION
Opera em dry-run por padrão. A execução exige -Execute, confirmação de
ShouldProcess e uma identidade completa composta por PID raiz, horário de
criação, quantidade de processos e impressão SHA-256 da árvore.

O script recusa sessões do Windows Terminal, árvores com pai vivo, serviços,
hosts de terminal e qualquer árvore que contenha o próprio processo que o
executa ou um PID protegido adicional.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidateRange(1, [uint32]::MaxValue)]
    [uint32]$RootId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$RootStartedAt,

    [Parameter(Mandatory)]
    [ValidatePattern('(?i)^[a-f0-9]{64}$')]
    [string]$ExpectedFingerprint,

    [Parameter(Mandatory)]
    [ValidateRange(1, 512)]
    [int]$ExpectedProcessCount,

    [uint32[]]$AdditionalProtectedProcessIds = @(),

    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$corePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'lib\pressure-core.ps1'))
if (-not (Test-Path -LiteralPath $corePath -PathType Leaf)) {
    throw "Núcleo do painel ausente: $corePath"
}
. $corePath

function New-PressureTerminationResult {
    param(
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$Message,
        $Plan = $null
    )

    [pscustomobject]@{
        Status = $Status
        Code = $Code
        Message = $Message
        Plan = $Plan
    }
}

function Get-PressureTerminationHostSafety {
    $windowsRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
    $systemDrive = [IO.Path]::GetPathRoot($windowsRoot).TrimEnd('\')
    if ([string]::IsNullOrWhiteSpace($systemDrive)) {
        $systemDrive = 'C:'
    }

    $volume = Get-CimInstance `
        -ClassName Win32_LogicalDisk `
        -Filter "DeviceID='$systemDrive'" `
        -Property FreeSpace `
        -ErrorAction Stop
    $memory = Get-CimInstance `
        -ClassName Win32_PerfFormattedData_PerfOS_Memory `
        -Property AvailableMBytes, PercentCommittedBytesInUse `
        -ErrorAction Stop
    $terminals = @(Get-Process -Name WindowsTerminal -ErrorAction SilentlyContinue)

    $freeGB = [math]::Round([double]$volume.FreeSpace / 1GB, 2)
    $availableGB = [math]::Round([double]$memory.AvailableMBytes / 1024, 2)
    $commitPercent = [math]::Round([double]$memory.PercentCommittedBytesInUse, 1)
    $terminalPrivateGB = [math]::Round(
        [double](($terminals | Measure-Object PrivateMemorySize64 -Sum).Sum) / 1GB,
        2
    )
    $terminalWorkingSetGB = [math]::Round(
        [double](($terminals | Measure-Object WorkingSet64 -Sum).Sum) / 1GB,
        2
    )

    $level = 0
    $state = 'SAUDÁVEL'
    if (
        $freeGB -lt 0.5 -or
        $availableGB -lt 0.75 -or
        $commitPercent -ge 97 -or
        $terminalPrivateGB -ge 12 -or
        $terminalWorkingSetGB -ge 3.5
    ) {
        $level = 4
        $state = 'EMERGÊNCIA'
    } elseif (
        $freeGB -lt 2 -or
        $availableGB -lt 1.5 -or
        $commitPercent -ge 92 -or
        $terminalPrivateGB -ge 8 -or
        $terminalWorkingSetGB -ge 3
    ) {
        $level = 3
        $state = 'CRÍTICO'
    } elseif (
        $freeGB -lt 5 -or
        $availableGB -lt 4 -or
        $commitPercent -ge 80 -or
        $terminalPrivateGB -ge 4 -or
        $terminalWorkingSetGB -ge 2
    ) {
        $level = 2
        $state = 'ATENÇÃO'
    }

    [pscustomobject]@{
        Allowed = $level -lt 4
        Level = $level
        State = $state
        SystemDrive = $systemDrive
        FreeGB = $freeGB
        AvailableRAMGB = $availableGB
        CommitPercent = $commitPercent
        TerminalPrivateGB = $terminalPrivateGB
        TerminalWorkingSetGB = $terminalWorkingSetGB
    }
}

function Test-PressureLiveIdentity {
    param(
        [Parameter(Mandatory)]$LiveProcess,
        [Parameter(Mandatory)]$ExpectedMetadata
    )

    try {
        $liveName = Get-PressureBaseProcessName -Name ([string]$LiveProcess.ProcessName)
        $expectedName = Get-PressureBaseProcessName -Name ([string]$ExpectedMetadata.Name)
        $liveTicks = ([datetime]$LiveProcess.StartTime).ToUniversalTime().Ticks
        $expectedTicks = ([datetime]$ExpectedMetadata.CreationDate).ToUniversalTime().Ticks
    } catch {
        return $false
    }

    if ($liveName -ne $expectedName) {
        return $false
    }
    return [math]::Abs($liveTicks - $expectedTicks) -le [timespan]::FromSeconds(2).Ticks
}

try {
    $expectedRootStartedAt = [datetime]::Parse(
        $RootStartedAt,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind
    )
} catch {
    return New-PressureTerminationResult `
        -Status 'refused' `
        -Code 'invalid_start_time' `
        -Message 'O horário de início informado não é uma identidade válida.'
}

$rootKey = [string]$RootId
$rootProbe = Get-CimInstance `
    -ClassName Win32_Process `
    -Filter "ProcessId=$RootId" `
    -Property ProcessId `
    -ErrorAction SilentlyContinue
if ($null -eq $rootProbe) {
    return New-PressureTerminationResult `
        -Status 'completed' `
        -Code 'already_exited' `
        -Message "A árvore PID $RootId já não existe."
}

$metadata = Get-PressureProcessMetadataSnapshot
if (-not $metadata.ContainsKey($rootKey)) {
    return New-PressureTerminationResult `
        -Status 'completed' `
        -Code 'already_exited' `
        -Message "A árvore PID $RootId já não existe."
}

$root = $metadata[$rootKey]
$rootCliName = [string]$root.CliName
if ([string]::IsNullOrWhiteSpace($rootCliName)) {
    return New-PressureTerminationResult `
        -Status 'refused' `
        -Code 'not_a_cli_root' `
        -Message 'O PID raiz não é uma CLI reconhecida pelo contrato do painel.'
}

if (
    [math]::Abs(
        ([datetime]$root.CreationDate).ToUniversalTime().Ticks -
        $expectedRootStartedAt.ToUniversalTime().Ticks
    ) -gt [timespan]::FromSeconds(1).Ticks
) {
    return New-PressureTerminationResult `
        -Status 'refused' `
        -Code 'root_identity_changed' `
        -Message 'O PID raiz foi reutilizado ou reiniciado; nenhum processo foi encerrado.'
}

$treeMembers = @(
    Get-PressureProcessTreeMembers -RootId $RootId -MetadataByPid $metadata
)
$selfLineageIds = @(
    Get-PressureProcessLineageIds -ProcessId ([uint32]$PID) -MetadataByPid $metadata
)
$protectedProcessIds = @(
    @($selfLineageIds) + @($AdditionalProtectedProcessIds) |
        Sort-Object -Unique
)
$disposition = Get-PressureCliTerminationDisposition `
    -RootId $RootId `
    -HostedByTerminal ([bool]$root.TerminalHosted) `
    -IdentityMembers $treeMembers `
    -MetadataByPid $metadata `
    -ProtectedProcessIds $protectedProcessIds

if (-not $disposition.Eligible) {
    return New-PressureTerminationResult `
        -Status 'refused' `
        -Code ([string]$disposition.Code) `
        -Message ([string]$disposition.Reason) `
        -Plan $disposition
}
if ($treeMembers.Count -ne $ExpectedProcessCount) {
    return New-PressureTerminationResult `
        -Status 'refused' `
        -Code 'tree_count_changed' `
        -Message 'A quantidade de processos mudou desde a confirmação; nenhum PID foi encerrado.' `
        -Plan $disposition
}
if ([string]$disposition.Fingerprint -cne $ExpectedFingerprint.ToLowerInvariant()) {
    return New-PressureTerminationResult `
        -Status 'refused' `
        -Code 'tree_identity_changed' `
        -Message 'A composição da árvore mudou desde a confirmação; nenhum PID foi encerrado.' `
        -Plan $disposition
}

$hostSafety = Get-PressureTerminationHostSafety
if (-not $hostSafety.Allowed) {
    return New-PressureTerminationResult `
        -Status 'refused' `
        -Code 'host_emergency' `
        -Message 'O host está em nível de emergência; novas alterações foram bloqueadas.' `
        -Plan ([pscustomobject]@{
            Disposition = $disposition
            HostSafety = $hostSafety
        })
}

$plan = [pscustomobject]@{
    RootId = $RootId
    RootName = [string]$root.Name
    RootStartedAt = ([datetime]$root.CreationDate).ToString('o')
    ProcessCount = $treeMembers.Count
    Fingerprint = [string]$disposition.Fingerprint
    ProcessIds = @($treeMembers | ForEach-Object { [uint32]$_.Id })
    HostSafety = $hostSafety
}

if (-not $Execute) {
    return New-PressureTerminationResult `
        -Status 'dry_run' `
        -Code 'approval_required' `
        -Message 'Dry-run concluído; use -Execute após aprovação explícita da árvore exata.' `
        -Plan $plan
}

$targetDescription = (
    "$rootCliName PID $RootId, iniciado em $($plan.RootStartedAt), " +
    "$($treeMembers.Count) processos"
)
if (-not $PSCmdlet.ShouldProcess($targetDescription, 'Encerrar a árvore de CLI órfã')) {
    return New-PressureTerminationResult `
        -Status 'cancelled' `
        -Code 'should_process_declined' `
        -Message 'A confirmação de ShouldProcess não autorizou o encerramento.' `
        -Plan $plan
}

# A segunda captura fecha a janela entre a apresentação do plano e o primeiro
# encerramento. Qualquer alteração invalida integralmente a operação.
$freshMetadata = Get-PressureProcessMetadataSnapshot
if (-not $freshMetadata.ContainsKey($rootKey)) {
    return New-PressureTerminationResult `
        -Status 'completed' `
        -Code 'already_exited' `
        -Message "A árvore PID $RootId encerrou antes da execução." `
        -Plan $plan
}
$freshRoot = $freshMetadata[$rootKey]
$freshTreeMembers = @(
    Get-PressureProcessTreeMembers -RootId $RootId -MetadataByPid $freshMetadata
)
$freshDisposition = Get-PressureCliTerminationDisposition `
    -RootId $RootId `
    -HostedByTerminal ([bool]$freshRoot.TerminalHosted) `
    -IdentityMembers $freshTreeMembers `
    -MetadataByPid $freshMetadata `
    -ProtectedProcessIds $protectedProcessIds
if (
    -not $freshDisposition.Eligible -or
    $freshTreeMembers.Count -ne $ExpectedProcessCount -or
    [string]$freshDisposition.Fingerprint -cne $ExpectedFingerprint.ToLowerInvariant()
) {
    return New-PressureTerminationResult `
        -Status 'refused' `
        -Code 'tree_changed_during_confirmation' `
        -Message 'A árvore mudou durante a confirmação; nenhum PID foi encerrado.' `
        -Plan $freshDisposition
}

$targetIdSet = @{}
foreach ($member in $freshTreeMembers) {
    $targetIdSet[[string][uint32]$member.Id] = $true
}
$protectedBaseline = @(
    $freshMetadata.Values |
        Where-Object {
            -not $targetIdSet.ContainsKey([string][uint32]$_.Id) -and
            (Test-PressureProtectedProcess -Name ([string]$_.Name))
        } |
        ForEach-Object {
            [pscustomobject]@{
                Id = [uint32]$_.Id
                Name = [string]$_.Name
                CreationDate = [datetime]$_.CreationDate
            }
        }
)

$stoppedPids = [Collections.Generic.List[uint32]]::new()
$alreadyExitedPids = [Collections.Generic.List[uint32]]::new()
$identityChangedPids = [Collections.Generic.List[uint32]]::new()
foreach ($member in $freshTreeMembers) {
    $memberId = [uint32]$member.Id
    $liveProcess = Get-Process -Id $memberId -ErrorAction SilentlyContinue
    if ($null -eq $liveProcess) {
        $alreadyExitedPids.Add($memberId)
        continue
    }
    if (-not (Test-PressureLiveIdentity -LiveProcess $liveProcess -ExpectedMetadata $member)) {
        $identityChangedPids.Add($memberId)
        continue
    }

    try {
        Stop-Process -Id $memberId -ErrorAction Stop
        $stoppedPids.Add($memberId)
    } catch {
        if ($null -eq (Get-Process -Id $memberId -ErrorAction SilentlyContinue)) {
            $alreadyExitedPids.Add($memberId)
            continue
        }
        throw
    }
}

Start-Sleep -Milliseconds 800
$remainingPids = [Collections.Generic.List[uint32]]::new()
foreach ($member in $freshTreeMembers) {
    $liveProcess = Get-Process -Id ([uint32]$member.Id) -ErrorAction SilentlyContinue
    if (
        $null -ne $liveProcess -and
        (Test-PressureLiveIdentity -LiveProcess $liveProcess -ExpectedMetadata $member)
    ) {
        $remainingPids.Add([uint32]$member.Id)
    }
}

$missingProtectedPids = [Collections.Generic.List[uint32]]::new()
foreach ($protected in $protectedBaseline) {
    $liveProcess = Get-Process -Id ([uint32]$protected.Id) -ErrorAction SilentlyContinue
    if (
        $null -eq $liveProcess -or
        -not (Test-PressureLiveIdentity -LiveProcess $liveProcess -ExpectedMetadata $protected)
    ) {
        $missingProtectedPids.Add([uint32]$protected.Id)
    }
}

$finalHostSafety = try {
    Get-PressureTerminationHostSafety
} catch {
    $null
}
$completed = (
    $remainingPids.Count -eq 0 -and
    $identityChangedPids.Count -eq 0 -and
    $missingProtectedPids.Count -eq 0
)
$status = if ($completed) { 'completed' } else { 'partial' }
$code = if ($completed) { 'tree_terminated' } else { 'tree_not_fully_terminated' }
$message = if ($completed) {
    "A árvore $rootCliName PID $RootId foi encerrada."
} else {
    'A árvore mudou ou manteve PIDs ativos; nenhum processo adicional foi inferido como alvo.'
}

[pscustomobject]@{
    Status = $status
    Code = $code
    Message = $message
    RootId = $RootId
    StoppedPids = @($stoppedPids)
    AlreadyExitedPids = @($alreadyExitedPids)
    IdentityChangedPids = @($identityChangedPids)
    RemainingPids = @($remainingPids)
    MissingProtectedPids = @($missingProtectedPids)
    ProtectedProcessesHealthy = $missingProtectedPids.Count -eq 0
    HostSafetyBefore = $hostSafety
    HostSafetyAfter = $finalHostSafety
}
