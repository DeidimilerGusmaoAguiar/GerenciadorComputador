<#
.SYNOPSIS
Valida regras, integração e travas determinísticas do painel de pressão.
#>
[CmdletBinding()]
param(
    [switch]$SkipIntegration
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$corePath = Join-Path $repoRoot 'scripts\lib\pressure-core.ps1'
$failures = [Collections.Generic.List[string]]::new()
$checks = 0

function Assert-PressureCondition {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    $script:checks++
    if (-not $Condition) {
        $script:failures.Add($Message)
    }
}

. $corePath

function New-TestMetrics {
    param([hashtable]$Overrides = @{})

    $values = @{
        CpuPercent = 20
        AvailableMB = 8192
        AvailablePercent = 40
        CommitPercent = 35
        DiskPercent = 10
        DiskQueue = 0
        DiskLatencyMs = 4
        LowestFreeGB = 60
        GpuPercent = 5
        GpuEngine = '3D'
        NetworkPercent = 2
        NetworkMBps = 0.1
    }
    foreach ($key in $Overrides.Keys) {
        $values[$key] = $Overrides[$key]
    }
    return [pscustomobject]$values
}

$highCpu = New-TestMetrics -Overrides @{ CpuPercent = 91 }
$cpuAssessment = Get-PressureAssessment `
    -Metrics $highCpu `
    -History @($highCpu, $highCpu) `
    -GpuAvailable $true
Assert-PressureCondition `
    -Condition ($cpuAssessment.DominantResource -eq 'cpu') `
    -Message 'CPU sustentada deve ser o recurso dominante'
Assert-PressureCondition `
    -Condition ($cpuAssessment.Level -eq 3) `
    -Message 'CPU acima de 85% por tres ciclos deve ser CRITICO'

$memoryEmergency = New-TestMetrics -Overrides @{
        AvailableMB = 700
        AvailablePercent = 2
        CommitPercent = 98
}
$memoryAssessment = Get-PressureAssessment `
    -Metrics $memoryEmergency `
    -GpuAvailable $true
Assert-PressureCondition `
    -Condition ($memoryAssessment.DominantResource -eq 'memory') `
    -Message 'Memoria em emergencia deve ser dominante'
Assert-PressureCondition `
    -Condition ($memoryAssessment.Level -eq 4) `
    -Message 'Menos de 750 MB ou commit de 97% deve ser EMERGENCIA'

$diskCritical = New-TestMetrics -Overrides @{ LowestFreeGB = 1.8 }
$diskAssessment = Get-PressureAssessment `
    -Metrics $diskCritical `
    -GpuAvailable $true
Assert-PressureCondition `
    -Condition ($diskAssessment.DominantResource -eq 'disk') `
    -Message 'Volume abaixo de 2 GB deve tornar disco dominante'
Assert-PressureCondition `
    -Condition ($diskAssessment.Level -eq 3) `
    -Message 'Volume abaixo de 2 GB deve ser CRITICO'

$unsupportedGpu = Get-PressureAssessment `
    -Metrics (New-TestMetrics) `
    -GpuAvailable $false
$gpuResource = @($unsupportedGpu.Resources | Where-Object Key -eq 'gpu')[0]
Assert-PressureCondition `
    -Condition (-not $gpuResource.Available) `
    -Message 'GPU sem WDDM deve aparecer como indisponivel'

$cliContext = Get-PressureProcessContext `
    -Name 'node.exe' `
    -ParentName 'codex.exe' `
    -CommandLine 'node helper.js'
Assert-PressureCondition `
    -Condition ($cliContext.Category -eq 'Runtime de desenvolvimento') `
    -Message 'Runtime filho de CLI deve ser categorizado como desenvolvimento'
Assert-PressureCondition `
    -Condition ($cliContext.Purpose -match 'CLI') `
    -Message 'Runtime filho de CLI deve explicar o processo pai'
Assert-PressureCondition `
    -Condition (Test-PressureProtectedProcess -Name 'pwsh.exe') `
    -Message 'pwsh deve ser tratado como processo protegido'

$packageCli = Get-PressureCliIdentity `
    -Name 'node.exe' `
    -CommandLine 'node C:\portable\node_modules\@google\gemini-cli\dist\index.js'
Assert-PressureCondition `
    -Condition ($packageCli.Name -eq 'Gemini') `
    -Message 'CLI empacotada em node deve ser reconhecida sem expor a linha de comando'

function New-TestProcessMetadata {
    param(
        [uint32]$Id,
        [string]$Name,
        [uint32]$ParentId,
        [datetime]$CreationDate,
        [string]$CliName = ''
    )

    [pscustomobject]@{
        Id = $Id
        Name = $Name
        ParentId = $ParentId
        ParentName = ''
        CreationDate = $CreationDate
        SessionId = [uint32]1
        ServiceNames = @()
        Protected = Test-PressureProtectedProcess -Name $Name
        IsTerminalHost = (
            (Get-PressureBaseProcessName -Name $Name) -in
            @('windowsterminal', 'openconsole', 'conhost')
        )
        CliName = $CliName
        CliDetectionConfidence = if ($CliName) { 'alta' } else { 'nenhuma' }
        Workload = 'Processo de teste'
        TerminalHosted = $false
        TerminalId = [uint32]0
        TerminalName = ''
        TerminalSessionRootId = [uint32]0
        TerminalSessionRootName = ''
        OwningCliId = [uint32]0
        OwningCliName = ''
        RootCliId = [uint32]0
        RootCliName = ''
        Lineage = @()
    }
}

$topologyStart = [datetime]'2026-01-01T10:00:00Z'
$topology = @{
    '100' = New-TestProcessMetadata `
        -Id 100 -Name 'WindowsTerminal.exe' -ParentId 1 `
        -CreationDate $topologyStart
    '110' = New-TestProcessMetadata `
        -Id 110 -Name 'pwsh.exe' -ParentId 100 `
        -CreationDate $topologyStart.AddSeconds(1)
    '120' = New-TestProcessMetadata `
        -Id 120 -Name 'claude.exe' -ParentId 110 `
        -CreationDate $topologyStart.AddSeconds(2) -CliName 'Claude'
    '130' = New-TestProcessMetadata `
        -Id 130 -Name 'node.exe' -ParentId 120 `
        -CreationDate $topologyStart.AddSeconds(3)
}
Resolve-PressureProcessMetadataTopology -MetadataByPid $topology
$nodeTopology = $topology['130']
Assert-PressureCondition `
    -Condition (
        $nodeTopology.TerminalHosted -and
        $nodeTopology.TerminalId -eq 100 -and
        $nodeTopology.TerminalSessionRootId -eq 110
    ) `
    -Message 'Descendente deve ser atribuido ao Terminal e ao shell raiz corretos'
Assert-PressureCondition `
    -Condition (
        $nodeTopology.OwningCliId -eq 120 -and
        $nodeTopology.OwningCliName -eq 'Claude'
    ) `
    -Message 'Descendente deve ser atribuido a CLI ancestral correta'
Assert-PressureCondition `
    -Condition (@($nodeTopology.Lineage).Count -eq 4) `
    -Message 'Linhagem segura deve preservar Terminal, shell, CLI e processo'

$reusedPidTopology = @{
    '200' = New-TestProcessMetadata `
        -Id 200 -Name 'WindowsTerminal.exe' -ParentId 1 `
        -CreationDate $topologyStart.AddMinutes(2)
    '210' = New-TestProcessMetadata `
        -Id 210 -Name 'pwsh.exe' -ParentId 200 `
        -CreationDate $topologyStart.AddMinutes(1)
}
Resolve-PressureProcessMetadataTopology -MetadataByPid $reusedPidTopology
Assert-PressureCondition `
    -Condition (-not $reusedPidTopology['210'].TerminalHosted) `
    -Message 'PID pai reutilizado e criado depois do filho deve ser rejeitado'

$orphanTopology = @{
    '300' = New-TestProcessMetadata `
        -Id 300 -Name 'claude.exe' -ParentId 299 `
        -CreationDate $topologyStart -CliName 'Claude'
    '301' = New-TestProcessMetadata `
        -Id 301 -Name 'node.exe' -ParentId 300 `
        -CreationDate $topologyStart.AddSeconds(1)
}
Resolve-PressureProcessMetadataTopology -MetadataByPid $orphanTopology
$orphanMembers = @(
    Get-PressureProcessTreeMembers -RootId 300 -MetadataByPid $orphanTopology
)
$orphanDisposition = Get-PressureCliTerminationDisposition `
    -RootId 300 `
    -HostedByTerminal $false `
    -IdentityMembers $orphanMembers `
    -MetadataByPid $orphanTopology
Assert-PressureCondition `
    -Condition (
        $orphanDisposition.Eligible -and
        $orphanDisposition.Code -eq 'orphan_candidate' -and
        $orphanDisposition.ProcessCount -eq 2 -and
        $orphanDisposition.Fingerprint -match '^[a-f0-9]{64}$'
    ) `
    -Message 'CLI sem pai vivo deve virar candidata com identidade deterministica'

$managedTopology = @{
    '400' = New-TestProcessMetadata `
        -Id 400 -Name 'ChatGPT.exe' -ParentId 1 `
        -CreationDate $topologyStart
    '410' = New-TestProcessMetadata `
        -Id 410 -Name 'codex.exe' -ParentId 400 `
        -CreationDate $topologyStart.AddSeconds(1) -CliName 'Codex'
    '420' = New-TestProcessMetadata `
        -Id 420 -Name 'conhost.exe' -ParentId 410 `
        -CreationDate $topologyStart.AddSeconds(2)
}
Resolve-PressureProcessMetadataTopology -MetadataByPid $managedTopology
$managedMembers = @(
    Get-PressureProcessTreeMembers -RootId 410 -MetadataByPid $managedTopology
)
$managedDisposition = Get-PressureCliTerminationDisposition `
    -RootId 410 `
    -HostedByTerminal $false `
    -IdentityMembers $managedMembers `
    -MetadataByPid $managedTopology
Assert-PressureCondition `
    -Condition (
        -not $managedDisposition.Eligible -and
        $managedDisposition.Code -eq 'managed_parent' -and
        $managedDisposition.ParentId -eq 400
    ) `
    -Message 'CLI filha de gerenciador vivo deve ser explicada e nunca oferecida como orfa'

$dashboardTopology = @{
    '500' = New-TestProcessMetadata `
        -Id 500 -Name 'claude.exe' -ParentId 499 `
        -CreationDate $topologyStart -CliName 'Claude'
    '510' = New-TestProcessMetadata `
        -Id 510 -Name 'pwsh.exe' -ParentId 500 `
        -CreationDate $topologyStart.AddSeconds(1)
}
Resolve-PressureProcessMetadataTopology -MetadataByPid $dashboardTopology
$dashboardMembers = @(
    Get-PressureProcessTreeMembers -RootId 500 -MetadataByPid $dashboardTopology
)
$dashboardDisposition = Get-PressureCliTerminationDisposition `
    -RootId 500 `
    -HostedByTerminal $false `
    -IdentityMembers $dashboardMembers `
    -MetadataByPid $dashboardTopology `
    -ProtectedProcessIds @(510)
Assert-PressureCondition `
    -Condition (
        -not $dashboardDisposition.Eligible -and
        $dashboardDisposition.Code -eq 'protected_dashboard'
    ) `
    -Message 'Arvore que contem o PID do dashboard deve ser recusada antes de qualquer acao'

$terminalDisposition = Get-PressureCliTerminationDisposition `
    -RootId 120 `
    -HostedByTerminal $true `
    -IdentityMembers @($topology.Values) `
    -MetadataByPid $topology
Assert-PressureCondition `
    -Condition (
        -not $terminalDisposition.Eligible -and
        $terminalDisposition.Code -eq 'protected_terminal'
    ) `
    -Message 'Sessao do Windows Terminal nunca pode receber encerramento pela interface'

$changedFingerprintTopology = @{
    '300' = New-TestProcessMetadata `
        -Id 300 -Name 'claude.exe' -ParentId 299 `
        -CreationDate $topologyStart -CliName 'Claude'
    '301' = New-TestProcessMetadata `
        -Id 301 -Name 'node.exe' -ParentId 300 `
        -CreationDate $topologyStart.AddMinutes(1)
}
$changedFingerprint = Get-PressureProcessIdentityFingerprint `
    -Processes @($changedFingerprintTopology.Values)
Assert-PressureCondition `
    -Condition ($changedFingerprint -cne $orphanDisposition.Fingerprint) `
    -Message 'Mudanca de horario ou composicao deve invalidar a impressao da arvore'

$healthyAssessment = Get-PressureAssessment `
    -Metrics (New-TestMetrics) `
    -GpuAvailable $true
$terminalCritical = Get-PressureCliSeverity `
    -CpuPercent 5 `
    -PrivateMB (9 * 1024) `
    -IoTotalMBps 0 `
    -GpuPercent 0 `
    -ProcessCount 180 `
    -Assessment $healthyAssessment `
    -TerminalAggregate
Assert-PressureCondition `
    -Condition ($terminalCritical.Level -eq 3 -and $terminalCritical.CriticalNow) `
    -Message 'Arvore total do Terminal acima de 8 GB privados deve ser critica'

$heavySession = Get-PressureCliSeverity `
    -CpuPercent 5 `
    -PrivateMB (3.5 * 1024) `
    -IoTotalMBps 0 `
    -GpuPercent 0 `
    -ProcessCount 80 `
    -Assessment $healthyAssessment
Assert-PressureCondition `
    -Condition ($heavySession.Level -eq 2 -and -not $heavySession.CriticalNow) `
    -Message 'Sessao entre 2 e 4 GB deve ficar em atencao, sem fingir crise do host'

$criticalSession = Get-PressureCliSeverity `
    -CpuPercent 5 `
    -PrivateMB (4.1 * 1024) `
    -IoTotalMBps 0 `
    -GpuPercent 0 `
    -ProcessCount 80 `
    -Assessment $healthyAssessment
Assert-PressureCondition `
    -Condition ($criticalSession.Level -eq 3 -and $criticalSession.CriticalNow) `
    -Message 'Sessao individual acima de 4 GB privados deve ser critica'

foreach ($relativePath in @(
    'scripts\start-pressure-dashboard.ps1',
    'scripts\stop-pressure-cli-session.ps1',
    'dashboard\pressure\index.html',
    'dashboard\pressure\styles.css',
    'dashboard\pressure\app.js',
    'docs\PRESSURE-DASHBOARD.md'
)) {
    Assert-PressureCondition `
        -Condition (Test-Path -LiteralPath (Join-Path $repoRoot $relativePath) -PathType Leaf) `
        -Message "Arquivo do painel ausente: $relativePath"
}

$serverContent = [IO.File]::ReadAllText(
    (Join-Path $repoRoot 'scripts\start-pressure-dashboard.ps1')
)
Assert-PressureCondition `
    -Condition ($serverContent.Contains('http://127.0.0.1:')) `
    -Message 'Servidor deve escutar explicitamente em 127.0.0.1'
Assert-PressureCondition `
    -Condition (-not $serverContent.Contains('http://*:')) `
    -Message 'Servidor nao pode usar wildcard de host'
Assert-PressureCondition `
    -Condition (-not $serverContent.Contains('http://+:')) `
    -Message 'Servidor nao pode usar wildcard forte de host'
Assert-PressureCondition `
    -Condition (-not $serverContent.Contains('Stop-Process')) `
    -Message 'Servidor HTTP nao pode encerrar processos diretamente'
foreach ($serverActionMarker in @(
    '[switch]$EnableProcessTermination',
    '/api/action-token',
    '/api/cli-sessions/terminate',
    'X-Pressure-Action-Token',
    'AdditionalProtectedProcessIds'
)) {
    Assert-PressureCondition `
        -Condition $serverContent.Contains($serverActionMarker) `
        -Message "Servidor nao contem a trava de acao: $serverActionMarker"
}
Assert-PressureCondition `
    -Condition (
        $serverContent.Contains('[switch]$Background') -and
        $serverContent.Contains('-WindowStyle Hidden')
    ) `
    -Message 'Modo em segundo plano deve iniciar somente o servidor em janela oculta'

$terminationScriptContent = [IO.File]::ReadAllText(
    (Join-Path $repoRoot 'scripts\stop-pressure-cli-session.ps1')
)
foreach ($terminationMarker in @(
    'SupportsShouldProcess',
    '[switch]$Execute',
    '$PSCmdlet.ShouldProcess',
    'ExpectedFingerprint',
    'Get-PressureProcessLineageIds',
    'selfLineageIds',
    'Stop-Process -Id'
)) {
    Assert-PressureCondition `
        -Condition $terminationScriptContent.Contains($terminationMarker) `
        -Message "Executor nao contem a trava nominal: $terminationMarker"
}

$htmlContent = [IO.File]::ReadAllText(
    (Join-Path $repoRoot 'dashboard\pressure\index.html')
)
$javaScriptContent = [IO.File]::ReadAllText(
    (Join-Path $repoRoot 'dashboard\pressure\app.js')
)
Assert-PressureCondition `
    -Condition (-not ($htmlContent -match 'https?://')) `
    -Message 'Painel deve funcionar sem assets externos'
Assert-PressureCondition `
    -Condition (-not ($javaScriptContent -match 'https?://')) `
    -Message 'JavaScript deve funcionar sem chamadas externas'
foreach ($cliUiMarker in @(
    'terminal-family',
    'cli-session-grid',
    'Quais CLIs estão pesando na máquina',
    'termination-dialog',
    'termination-consent'
)) {
    Assert-PressureCondition `
        -Condition $htmlContent.Contains($cliUiMarker) `
        -Message "HTML deve conter a visao de arvores de CLI: $cliUiMarker"
}
foreach ($areaUiMarker in @(
    'sticky-shell',
    'pulse-strip',
    'strip-meters',
    'area-nav',
    'role="tablist"',
    'id="area-visao"',
    'id="area-clis"',
    'id="area-processos"',
    'id="area-diagnostico"',
    'role="tabpanel"',
    'aria-controls="area-clis"'
)) {
    Assert-PressureCondition `
        -Condition $htmlContent.Contains($areaUiMarker) `
        -Message "HTML deve dividir a tela em areas com faixa viva: $areaUiMarker"
}
foreach ($exclusionUiMarker in @(
    'exclusion-grid',
    'exclusion-schedule',
    'Quem fica exposto à varredura',
    'exclusion-count'
)) {
    Assert-PressureCondition `
        -Condition $htmlContent.Contains($exclusionUiMarker) `
        -Message "HTML deve mostrar a exposicao dos perfis de CLI: $exclusionUiMarker"
}
Assert-PressureCondition `
    -Condition $javaScriptContent.Contains('renderExclusions') `
    -Message 'JavaScript deve renderizar a exposicao dos perfis de CLI'
foreach ($areaScriptMarker in @(
    'activateArea',
    'areaOrder',
    'pulso-area',
    'setTabBadge',
    'hashchange',
    'strip-score',
    'strip-${key}'
)) {
    Assert-PressureCondition `
        -Condition $javaScriptContent.Contains($areaScriptMarker) `
        -Message "JavaScript deve controlar as areas e a faixa viva: $areaScriptMarker"
}
# A faixa viva só cumpre a função se todo recurso tiver espelho no topo.
foreach ($stripId in @('strip-cpu', 'strip-memory', 'strip-disk', 'strip-gpu', 'strip-network')) {
    Assert-PressureCondition `
        -Condition $htmlContent.Contains("id=`"$stripId`"") `
        -Message "Faixa viva deve espelhar o recurso: $stripId"
}
foreach ($cliScriptMarker in @(
    'TerminalSummary',
    'CliSessions',
    'OwningCliName',
    'renderCliPressure',
    'ExpectedFingerprint',
    'X-Pressure-Action-Token',
    'terminatePendingSession'
)) {
    Assert-PressureCondition `
        -Condition $javaScriptContent.Contains($cliScriptMarker) `
        -Message "JavaScript deve renderizar atribuicao de CLI: $cliScriptMarker"
}

function New-TestProcessRow {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][uint32]$IDProcess,
        [double]$PercentProcessorTime = 0,
        [double]$PrivateBytes = 0
    )

    [pscustomobject]@{
        Name = $Name
        IDProcess = $IDProcess
        PercentProcessorTime = $PercentProcessorTime
        PrivateBytes = $PrivateBytes
    }
}

# Oito núcleos: o contador bruto é dividido pela contagem lógica, como no snapshot.
$selfCostRows = @(
    New-TestProcessRow -Name 'pwsh' -IDProcess 4242 -PercentProcessorTime 80 -PrivateBytes (150MB)
    New-TestProcessRow -Name 'WmiPrvSE' -IDProcess 900 -PercentProcessorTime 40
    New-TestProcessRow -Name 'WmiPrvSE#3' -IDProcess 901 -PercentProcessorTime 24
    New-TestProcessRow -Name 'chrome' -IDProcess 902 -PercentProcessorTime 160
)
$selfCost = Get-PressureSelfCost `
    -ProcessRows $selfCostRows `
    -DashboardProcessId 4242 `
    -LastCollectionMs 500 `
    -CollectionCount 4 `
    -CollectionMsTotal 1200 `
    -CollectionMsMax 700 `
    -LogicalProcessorCount 8 `
    -RefreshSeconds 5

Assert-PressureCondition `
    -Condition ($selfCost.SelfCpuPercent -eq 10) `
    -Message 'Custo proprio deve normalizar a CPU pela contagem de nucleos logicos'
Assert-PressureCondition `
    -Condition ($selfCost.SelfPrivateMB -eq 150) `
    -Message 'Custo proprio deve reportar a memoria privada do painel'
Assert-PressureCondition `
    -Condition ($selfCost.WmiProviderCpuPercent -eq 8 -and $selfCost.WmiProviderCount -eq 2) `
    -Message 'Custo proprio deve somar todas as instancias WmiPrvSE, inclusive as numeradas'
Assert-PressureCondition `
    -Condition (-not $selfCost.WmiProviderAttributable) `
    -Message 'O provedor WMI atende todo o computador e nao pode ser atribuido ao painel'
Assert-PressureCondition `
    -Condition ($selfCost.AverageCollectionMs -eq 300 -and $selfCost.MaxCollectionMs -eq 700) `
    -Message 'Custo proprio deve reportar media e pico acumulados de coleta'
Assert-PressureCondition `
    -Condition ($selfCost.DutyPercent -eq 10) `
    -Message 'Custo proprio deve informar quanto do intervalo foi gasto coletando'

$selfCostAbsent = Get-PressureSelfCost `
    -ProcessRows $selfCostRows `
    -DashboardProcessId 7777 `
    -LogicalProcessorCount 8 `
    -RefreshSeconds 0
Assert-PressureCondition `
    -Condition ($selfCostAbsent.SelfCpuPercent -eq 0 -and $selfCostAbsent.DutyPercent -eq 0) `
    -Message 'Custo proprio deve degradar para zero sem PID conhecido ou intervalo valido'

$historyRoot = Join-Path ([IO.Path]::GetTempPath()) ("pressure-history-test-" + [Guid]::NewGuid().ToString('n'))
try {
    $now = [datetime]'2026-07-29T12:00:00'
    $writer = New-PressureHistoryWriter `
        -Directory $historyRoot `
        -RetentionDays 7 `
        -MaxMB 1 `
        -FlushSeconds 60 `
        -Tag 'teste' `
        -Now $now
    Assert-PressureCondition `
        -Condition ((Split-Path (Get-PressureHistoryFilePath -Writer $writer -Now $now) -Leaf) -eq 'pressure_2026-07-29_teste.jsonl') `
        -Message 'Arquivo de historico deve carregar a identidade do coletor'

    $semTag = New-PressureHistoryWriter -Directory $historyRoot -Now $now
    Assert-PressureCondition `
        -Condition ((Split-Path (Get-PressureHistoryFilePath -Writer $semTag -Now $now) -Leaf) -eq 'pressure_2026-07-29.jsonl') `
        -Message 'Sem identidade declarada o nome do arquivo permanece o antigo'

    $comFallback = New-PressureHistoryWriter -Directory $historyRoot -Tag 'painel' -Now $now
    $comFallback.FallbackTag = 'painel-p4242'
    Assert-PressureCondition `
        -Condition ((Split-Path (Get-PressureHistoryFilePath -Writer $comFallback -Now $now) -Leaf) -eq 'pressure_2026-07-29_painel-p4242.jsonl') `
        -Message 'Disputa de handle deve redirecionar para arquivo com sufixo de PID'

    $fakeSnapshot = [pscustomobject]@{
        GeneratedAt = $now.ToString('o')
        CollectionDurationMs = 6942
        RefreshSeconds = 5
        Overall = [pscustomobject]@{
            Level = 2
            State = 'ATENÇÃO'
            Score = 61
            DominantResource = 'disk'
        }
        Metrics = New-TestMetrics -Overrides @{
            PagesOutputPerSec = 0
            DiskReadMBps = 1.5
            DiskWriteMBps = 0.4
        }
        SelfCost = [pscustomobject]@{
            SelfCpuPercent = 1.2
            DutyPercent = 138.8
            WmiProviderCpuPercent = 8
        }
        Defender = [pscustomobject]@{
            ScanInProgress = $true
            EngineIoMBps = 12.5
            EngineCpuPercent = 30
        }
        Consumers = [ordered]@{
            cpu = @(
                [pscustomobject]@{ Name = 'chrome'; CpuPercent = 20; PrivateMB = 1500; IoTotalMBps = 0.3 }
                [pscustomobject]@{ Name = 'node'; CpuPercent = 10; PrivateMB = 300; IoTotalMBps = 0.1 }
            )
        }
    }

    $record = ConvertTo-PressureHistoryRecord -Snapshot $fakeSnapshot
    Assert-PressureCondition `
        -Condition ($record.kind -eq 'sample' -and $record.dominant -eq 'disk') `
        -Message 'Registro de historico deve preservar o recurso dominante'
    Assert-PressureCondition `
        -Condition ($record.selfDuty -eq 138.8 -and $record.collectMs -eq 6942) `
        -Message 'Registro de historico deve preservar o custo do proprio painel'
    Assert-PressureCondition `
        -Condition (@($record.top).Count -eq 2 -and $record.top[0].n -eq 'chrome') `
        -Message 'Registro de historico deve listar os maiores consumidores por nome'
    Assert-PressureCondition `
        -Condition ($record.scanning -and $record.avIoMBps -eq 12.5) `
        -Message 'Registro de historico deve dizer se havia varredura em curso'

    $recordJson = $record | ConvertTo-Json -Depth 6 -Compress
    foreach ($forbidden in @('CommandLine', 'ExecutablePath', 'Lineage', 'ParentName')) {
        Assert-PressureCondition `
            -Condition (-not $recordJson.Contains($forbidden)) `
            -Message "Historico nao pode conter $forbidden"
    }

    $flushed = Add-PressureHistoryRecord -Writer $writer -Record $record -Now $now
    Assert-PressureCondition `
        -Condition ($flushed -eq 0 -and $writer.Buffer.Count -eq 1) `
        -Message 'Historico deve acumular em memoria ate o lote vencer'
    Assert-PressureCondition `
        -Condition (-not (Test-Path -LiteralPath $historyRoot)) `
        -Message 'Historico nao pode tocar o disco antes do primeiro flush'

    $flushed = Add-PressureHistoryRecord `
        -Writer $writer `
        -Record $record `
        -Now $now.AddSeconds(120)
    Assert-PressureCondition `
        -Condition ($flushed -eq 2 -and $writer.Buffer.Count -eq 0) `
        -Message 'Historico deve descarregar o lote inteiro de uma vez'

    $historyFile = Get-PressureHistoryFilePath -Writer $writer -Now $now.AddSeconds(120)
    Assert-PressureCondition `
        -Condition (Test-Path -LiteralPath $historyFile) `
        -Message 'Historico deve criar o arquivo diario no diretorio declarado'
    Assert-PressureCondition `
        -Condition (@(Get-Content -LiteralPath $historyFile).Count -eq 2) `
        -Message 'Cada amostra deve ocupar exatamente uma linha JSONL'

    $staleFile = Join-Path $historyRoot 'pressure_2020-01-01.jsonl'
    Set-Content -LiteralPath $staleFile -Value '{"kind":"sample"}' -Encoding utf8
    (Get-Item -LiteralPath $staleFile).LastWriteTime = $now.AddDays(-30)

    $expired = Get-PressureHistoryExpired `
        -Directory $historyRoot `
        -RetentionDays 7 `
        -MaxBytes 1MB `
        -Now $now.AddSeconds(120)
    Assert-PressureCondition `
        -Condition (@($expired).Count -eq 1 -and $expired[0].Reason -eq 'idade') `
        -Message 'Plano de retencao deve marcar arquivos alem da janela de dias'
    Assert-PressureCondition `
        -Condition (Test-Path -LiteralPath $staleFile) `
        -Message 'O nucleo do painel nunca pode apagar; ele apenas planeja'
    Assert-PressureCondition `
        -Condition (
            @($expired | Where-Object { $_.Name -eq (Split-Path $historyFile -Leaf) }).Count -eq 0
        ) `
        -Message 'Plano de retencao nunca pode incluir o arquivo do dia corrente'

    $sizePlan = Get-PressureHistoryExpired `
        -Directory $historyRoot `
        -RetentionDays 365 `
        -MaxBytes 1 `
        -Now $now.AddSeconds(120)
    Assert-PressureCondition `
        -Condition (@($sizePlan | Where-Object Reason -eq 'tamanho').Count -ge 1) `
        -Message 'Plano de retencao deve acionar o teto de tamanho quando a idade nao basta'

    $cleanupScript = Join-Path $repoRoot 'scripts\remove-pressure-history.ps1'
    $dryRun = & $cleanupScript -Directory $historyRoot -RetentionDays 7 -MaxMB 1
    Assert-PressureCondition `
        -Condition ($dryRun.Status -eq 'dry_run' -and @($dryRun.RemovedFiles).Count -eq 0) `
        -Message 'Remocao de historico deve ser dry-run por padrao'
    Assert-PressureCondition `
        -Condition (Test-Path -LiteralPath $staleFile) `
        -Message 'Dry-run de historico nao pode apagar nada'

    $applied = & $cleanupScript `
        -Directory $historyRoot `
        -RetentionDays 7 `
        -MaxMB 1 `
        -Execute `
        -Confirm:$false
    Assert-PressureCondition `
        -Condition ($applied.Status -eq 'completed' -and @($applied.RemovedFiles).Count -eq 1) `
        -Message 'Remocao de historico com -Execute deve aplicar o plano'
    Assert-PressureCondition `
        -Condition (-not (Test-Path -LiteralPath $staleFile)) `
        -Message 'Arquivo expirado deve sumir apos -Execute'
    Assert-PressureCondition `
        -Condition (Test-Path -LiteralPath $historyFile) `
        -Message 'Remocao nunca pode levar o arquivo do dia corrente'

    # Disputa real de handle: o arquivo alvo fica travado por outro processo e a
    # amostra nao pode ser descartada em silencio.
    $disputaWriter = New-PressureHistoryWriter `
        -Directory $historyRoot `
        -FlushSeconds 60 `
        -Tag 'disputa' `
        -Now $now
    $alvoDisputa = Get-PressureHistoryFilePath -Writer $disputaWriter -Now $now
    Set-Content -LiteralPath $alvoDisputa -Value '{"kind":"sample"}' -Encoding utf8
    $trava = [IO.File]::Open(
        $alvoDisputa,
        [IO.FileMode]::Open,
        [IO.FileAccess]::ReadWrite,
        [IO.FileShare]::None
    )
    try {
        $gravadas = Add-PressureHistoryRecord `
            -Writer $disputaWriter `
            -Record $record `
            -Now $now `
            -Flush
        Assert-PressureCondition `
            -Condition ($gravadas -eq 1) `
            -Message 'Disputa de handle deve gravar no arquivo alternativo, nao descartar'
        Assert-PressureCondition `
            -Condition ($disputaWriter.DroppedLines -eq 0) `
            -Message 'Nenhuma amostra pode ser contada como descartada apos o desvio'
        Assert-PressureCondition `
            -Condition ($disputaWriter.FallbackTag -like 'disputa-p*') `
            -Message 'O desvio deve registrar a identidade alternativa usada'
        $alternativo = Get-PressureHistoryFilePath -Writer $disputaWriter -Now $now
        Assert-PressureCondition `
            -Condition ((Test-Path -LiteralPath $alternativo) -and $alternativo -ne $alvoDisputa) `
            -Message 'O arquivo alternativo deve existir e ser distinto do disputado'
    } finally {
        $trava.Dispose()
    }

    $disabledWriter = New-PressureHistoryWriter -Directory $historyRoot -Disabled
    $disabledFlush = Add-PressureHistoryRecord `
        -Writer $disabledWriter `
        -Record $record `
        -Now $now `
        -Flush
    Assert-PressureCondition `
        -Condition ($disabledFlush -eq 0 -and $disabledWriter.Buffer.Count -eq 0) `
        -Message '-NoHistory deve impedir qualquer acumulo ou escrita'
} finally {
    # A limpeza usa o mesmo script com gate, em vez de um Remove-Item solto no teste.
    if (Test-Path -LiteralPath $historyRoot) {
        $null = & (Join-Path $repoRoot 'scripts\remove-pressure-history.ps1') `
            -Directory $historyRoot `
            -All `
            -Execute `
            -Confirm:$false
        [IO.Directory]::Delete($historyRoot)
    }
}

Assert-PressureCondition `
    -Condition (
        (Get-PressureAdaptiveRefreshSeconds -Level 0 -Current 5 -Min 5 -Max 30) -eq 10
    ) `
    -Message 'Cadencia saudavel deve subir um degrau por vez'
Assert-PressureCondition `
    -Condition (
        (Get-PressureAdaptiveRefreshSeconds -Level 0 -Current 28 -Min 5 -Max 30) -eq 30
    ) `
    -Message 'Cadencia saudavel nao pode ultrapassar o teto declarado'
foreach ($pressureLevel in 1..4) {
    Assert-PressureCondition `
        -Condition (
            (Get-PressureAdaptiveRefreshSeconds -Level $pressureLevel -Current 30 -Min 5 -Max 30) -eq 5
        ) `
        -Message "Nivel $pressureLevel deve derrubar a cadencia para o minimo de uma vez"
}
Assert-PressureCondition `
    -Condition (
        (Get-PressureAdaptiveRefreshSeconds -Level 0 -Current 5 -Min 5 -Max 5) -eq 5
    ) `
    -Message 'Teto igual ao minimo deve manter cadencia fixa'

$adaptiveState = New-PressureMonitorState -RefreshSeconds 5 -MaxRefreshSeconds 30
Assert-PressureCondition `
    -Condition (
        $adaptiveState.AdaptiveCadence -and
        $adaptiveState.MinRefreshSeconds -eq 5 -and
        $adaptiveState.MaxRefreshSeconds -eq 30
    ) `
    -Message 'Estado deve nascer com cadencia adaptativa e limites declarados'

$fixedState = New-PressureMonitorState -RefreshSeconds 5 -FixedCadence
Assert-PressureCondition `
    -Condition (-not $fixedState.AdaptiveCadence) `
    -Message '-FixedCadence deve desligar o recuo automatico'

# 29/07/2026 e uma quarta-feira; 5 significa quinta-feira em MSFT_MpPreference.
$wednesday = [datetime]'2026-07-29T11:00:00'
$nextThursday = Get-PressureNextScheduledScan `
    -ScheduleDay 5 `
    -ScheduleTimeOfDay ([timespan]'13:00:00') `
    -Now $wednesday
Assert-PressureCondition `
    -Condition ($nextThursday -eq [datetime]'2026-07-30T13:00:00') `
    -Message 'Varredura de quinta vista na quarta deve cair no dia seguinte'

$thursdayBefore = Get-PressureNextScheduledScan `
    -ScheduleDay 5 `
    -ScheduleTimeOfDay ([timespan]'13:00:00') `
    -Now ([datetime]'2026-07-30T12:59:00')
Assert-PressureCondition `
    -Condition ($thursdayBefore -eq [datetime]'2026-07-30T13:00:00') `
    -Message 'Um minuto antes do horario a varredura ainda e a de hoje'

$thursdayAfter = Get-PressureNextScheduledScan `
    -ScheduleDay 5 `
    -ScheduleTimeOfDay ([timespan]'13:00:00') `
    -Now ([datetime]'2026-07-30T13:00:01')
Assert-PressureCondition `
    -Condition ($thursdayAfter -eq [datetime]'2026-08-06T13:00:00') `
    -Message 'Passado o horario a varredura deve pular para a semana seguinte'

$everyDay = Get-PressureNextScheduledScan `
    -ScheduleDay 0 `
    -ScheduleTimeOfDay ([timespan]'02:00:00') `
    -Now ([datetime]'2026-07-29T03:00:00')
Assert-PressureCondition `
    -Condition ($everyDay -eq [datetime]'2026-07-30T02:00:00') `
    -Message 'Agenda diaria vencida hoje deve apontar para amanha'

Assert-PressureCondition `
    -Condition (
        $null -eq (
            Get-PressureNextScheduledScan `
                -ScheduleDay 8 `
                -ScheduleTimeOfDay ([timespan]'13:00:00') `
                -Now $wednesday
        )
    ) `
    -Message 'Agenda desligada nao pode inventar uma proxima varredura'

$gaps = Get-PressureToolchainExclusionGaps `
    -ExclusionPath @('C:\Repos\legado', 'C:\Program Files (x86)\Microsoft Visual Studio') `
    -ExclusionProcess @('devenv.exe', 'msbuild.exe')
Assert-PressureCondition `
    -Condition (@($gaps).Count -eq 3) `
    -Message 'Lista voltada ao toolchain antigo deve acusar todas as lacunas do toolchain Node'

# ExclusionProcess vale para os arquivos abertos pelo processo, nao so para o
# executavel: node.exe cobre npm-cache.
$processoNode = Get-PressureToolchainExclusionGaps `
    -ExclusionPath @() `
    -ExclusionProcess @('node.exe', 'node_repl.exe')
Assert-PressureCondition `
    -Condition (@($processoNode | Where-Object Key -eq 'npm-cache').Count -eq 0) `
    -Message 'Exclusao de processo node.exe deve cobrir o cache do npm'

# --- contencao real de caminho ---
# A raiz sintetica e D:\perfis para nao introduzir caminho de perfil de usuario
# no repositorio; a logica exercitada e a mesma de C:\Users\<nome>.
$contencao = @(
    @{ Alvo = 'D:\perfis\ana\.claude-pessoal'; Excl = @('D:\perfis\ana\.claude'); Esperado = $false; Caso = 'irmao com prefixo comum nao pode contar como coberto' }
    @{ Alvo = 'D:\perfis\ana\.claude'; Excl = @('D:\perfis\ana\.claude'); Esperado = $true; Caso = 'caminho identico deve cobrir' }
    @{ Alvo = 'D:\perfis\ana\.claude\projects\x'; Excl = @('D:\perfis\ana\.claude'); Esperado = $true; Caso = 'ancestral deve cobrir descendente' }
    @{ Alvo = 'D:\perfis\ana\.claude'; Excl = @('D:\perfis\ana\.claude\projects'); Esperado = $false; Caso = 'descendente nao pode cobrir ancestral' }
    @{ Alvo = 'D:\perfis\ana\AppData\Roaming\npm'; Excl = @('D:\perfis\*\AppData\Roaming\npm'); Esperado = $true; Caso = 'curinga de um segmento deve casar o perfil'  }
    @{ Alvo = 'D:\perfis\ana\sub\AppData\Roaming\npm'; Excl = @('D:\perfis\*\AppData\Roaming\npm'); Esperado = $false; Caso = 'curinga nao pode atravessar barra' }
    @{ Alvo = 'D:\perfis\ana\.m2'; Excl = @('%VariavelQueNaoExiste%\.m2'); Esperado = $false; Caso = 'variavel inexistente nao expande e nao cobre nada' }
    @{ Alvo = 'D:\Ferramenta7\Bin'; Excl = @('D:\Ferramenta*'); Esperado = $true; Caso = 'curinga parcial no fim do nome deve casar' }
    @{ Alvo = 'C:\Pacote\sub'; Excl = @('C:\Pacote\*'); Esperado = $true; Caso = 'padrao terminado em barra-curinga deve cobrir o conteudo' }
    @{ Alvo = 'C:\PacoteOutro'; Excl = @('C:\Pacote\*'); Esperado = $false; Caso = 'pasta com nome estendido nao pode ser coberta' }
)
foreach ($caso in $contencao) {
    $r = Test-PressureExclusionCoverage -Path $caso.Alvo -ExclusionPath $caso.Excl
    Assert-PressureCondition `
        -Condition ($r.Covered -eq $caso.Esperado) `
        -Message ('Cobertura de exclusao: ' + $caso.Caso)
}

# --- raizes de descoberta dos perfis de CLI ---
# Perfil guardado fora do diretorio do usuario nao aparece na descoberta por
# convencao, e a exposicao sai subcontada. O mapa local existe para corrigir isso.
$mapaRoot = Join-Path ([IO.Path]::GetTempPath()) ("pressure-map-test-" + [Guid]::NewGuid().ToString('n'))
try {
    $null = New-Item -ItemType Directory -Path $mapaRoot
    $mapaPath = Join-Path $mapaRoot 'perfis-cli.json'
    @{
        version = 1
        profiles = @(
            @{ cli = 'claude'; alias = 'cc-a'; label = 'A'; color = 'Cyan'; home = 'D:\perfis\ana\.claude' }
            @{ cli = 'claude'; alias = 'cc-b'; label = 'B'; color = 'Green'; home = 'D:\repos\.claude-ce' }
        )
        ignore = @('D:\outro\.gemini')
    } |
        ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath $mapaPath -Encoding utf8

    $raizesDoMapa = @(Get-PressureCliHomeRoots -ProfileMapPath $mapaPath)
    foreach ($esperada in @('D:\perfis\ana', 'D:\repos', 'D:\outro')) {
        Assert-PressureCondition `
            -Condition ($raizesDoMapa -contains $esperada) `
            -Message "Raiz declarada no mapa deve entrar na descoberta: $esperada"
    }
    Assert-PressureCondition `
        -Condition ($raizesDoMapa -contains ([IO.Path]::GetFullPath($env:USERPROFILE))) `
        -Message 'Raiz do usuario deve continuar valendo junto com o mapa'

    # Raiz explicita e decisao de quem chamou: o mapa nao pode acrescentar nada.
    $raizesExplicitas = @(
        Get-PressureCliHomeRoots -ExplicitRoot @('D:\somente') -ProfileMapPath $mapaPath
    )
    Assert-PressureCondition `
        -Condition (@($raizesExplicitas).Count -eq 1 -and $raizesExplicitas[0] -eq 'D:\somente') `
        -Message 'Raiz explicita deve vencer o mapa'

    # Mapa corrompido nao pode derrubar a coleta.
    $mapaQuebrado = Join-Path $mapaRoot 'quebrado.json'
    'isto nao e json' | Set-Content -LiteralPath $mapaQuebrado -Encoding utf8
    $raizesQuebradas = @(
        Get-PressureCliHomeRoots -ProfileMapPath $mapaQuebrado -WarningAction SilentlyContinue
    )
    Assert-PressureCondition `
        -Condition ($raizesQuebradas -contains ([IO.Path]::GetFullPath($env:USERPROFILE))) `
        -Message 'Mapa ilegivel deve degradar para a raiz do usuario'

    $raizesSemMapa = @(
        Get-PressureCliHomeRoots -ProfileMapPath (Join-Path $mapaRoot 'ausente.json')
    )
    Assert-PressureCondition `
        -Condition (@($raizesSemMapa).Count -ge 1) `
        -Message 'Mapa ausente nao e erro: a raiz do usuario continua valendo'
} finally {
    # Limpeza do proprio temp por API do .NET: Remove-Item solto num teste
    # exigiria o gate de execucao que a superficie publica cobra dos scripts.
    if (Test-Path -LiteralPath $mapaRoot) {
        [IO.Directory]::Delete($mapaRoot, $true)
    }
}

# --- cobertura por perfil de CLI ---
$homesFake = @(
    [pscustomobject]@{ Path = 'D:\perfis\ana\.claude'; Label = '.claude'; Source = 'convenção' }
    [pscustomobject]@{ Path = 'D:\perfis\ana\.claude-pessoal'; Label = '.claude-pessoal'; Source = 'convenção' }
    [pscustomobject]@{ Path = 'D:\perfis\ana\.codex'; Label = '.codex'; Source = 'convenção' }
)
$porCaminho = Get-PressureCliHomeCoverage `
    -Homes $homesFake `
    -ExclusionPath @('D:\perfis\ana\.claude')
Assert-PressureCondition `
    -Condition (@($porCaminho | Where-Object { -not $_.Covered }).Count -eq 2) `
    -Message 'Excluir um perfil nao pode marcar os demais como cobertos'
Assert-PressureCondition `
    -Condition (@($porCaminho | Where-Object { $_.Label -eq '.claude' }).CoveredBy -eq 'caminho') `
    -Message 'Perfil coberto por caminho deve declarar a origem da cobertura'

$porProcesso = Get-PressureCliHomeCoverage `
    -Homes $homesFake `
    -ExclusionPath @() `
    -ExclusionProcess @('claude.exe')
Assert-PressureCondition `
    -Condition (
        @($porProcesso | Where-Object { $_.Label -like '.claude*' -and $_.Covered }).Count -eq 2 -and
        @($porProcesso | Where-Object { $_.Label -eq '.codex' -and -not $_.Covered }).Count -eq 1
    ) `
    -Message 'Exclusao do binario claude.exe cobre os perfis do Claude e nenhum do Codex'
Assert-PressureCondition `
    -Condition (@($porProcesso | Where-Object { $_.Label -eq '.claude' }).CoveredBy -eq 'processo') `
    -Message 'Perfil coberto por processo deve declarar a origem da cobertura'

$semNada = Get-PressureCliHomeCoverage -Homes $homesFake
Assert-PressureCondition `
    -Condition (@($semNada | Where-Object { $_.Covered }).Count -eq 0) `
    -Message 'Sem exclusao alguma nenhum perfil pode aparecer como coberto'

$coveredGaps = Get-PressureToolchainExclusionGaps `
    -ExclusionPath @(
        'D:\ferramentas\nodejs',
        'D:\ferramentas\npm',
        'D:\ferramentas\npm-cache',
        'D:\ferramentas\.claude'
    ) `
    -ExclusionProcess @('node.exe')
Assert-PressureCondition `
    -Condition (@($coveredGaps).Count -eq 0) `
    -Message 'Toolchain Node inteiramente excluido nao pode gerar lacuna'

$scanningState = Get-PressureDefenderState `
    -Status ([pscustomobject]@{
        RealTimeProtectionEnabled = $true
        FullScanStartTime = [datetime]'2026-07-30T13:00:00'
        FullScanEndTime = [datetime]'2026-07-24T11:09:00'
    }) `
    -Preference ([pscustomobject]@{
        ExclusionPath = @('C:\Repos\legado')
        ExclusionProcess = @('devenv.exe')
        ScanScheduleDay = 5
        ScanScheduleTime = [datetime]'2026-01-01T13:00:00'
        ScanOnlyIfIdleEnabled = $false
        DisableCatchupFullScan = $false
    }) `
    -EngineIoMBps 14.2 `
    -Now ([datetime]'2026-07-30T14:00:00')
Assert-PressureCondition `
    -Condition $scanningState.ScanInProgress `
    -Message 'Inicio posterior ao termino registrado deve indicar varredura em andamento'
Assert-PressureCondition `
    -Condition ($scanningState.ScheduleDayName -eq 'quinta-feira') `
    -Message 'Estado do antimalware deve traduzir o dia agendado'
Assert-PressureCondition `
    -Condition (@($scanningState.ToolchainGaps).Count -eq 3) `
    -Message 'Estado do antimalware deve carregar as lacunas de exclusao'

# O provedor real desta plataforma devolve TimeSpan; outras devolvem DateTime.
$timeSpanState = Get-PressureDefenderState `
    -Status $null `
    -Preference ([pscustomobject]@{
        ExclusionPath = @()
        ExclusionProcess = @()
        ScanScheduleDay = 5
        ScanScheduleTime = [timespan]'13:00:00'
        ScanOnlyIfIdleEnabled = $false
        DisableCatchupFullScan = $false
    }) `
    -Now $wednesday
Assert-PressureCondition `
    -Condition ($timeSpanState.NextScheduledScan -eq '2026-07-30 13:00') `
    -Message 'Agenda entregue como TimeSpan deve produzir o mesmo horario que DateTime'

$idleState = Get-PressureDefenderState `
    -Status ([pscustomobject]@{
        RealTimeProtectionEnabled = $true
        FullScanStartTime = [datetime]'2026-07-23T14:52:00'
        FullScanEndTime = [datetime]'2026-07-24T11:09:00'
    }) `
    -Preference $null `
    -Now $wednesday
Assert-PressureCondition `
    -Condition (-not $idleState.ScanInProgress) `
    -Message 'Termino posterior ao inicio significa varredura concluida'

$absentState = Get-PressureDefenderState -Status $null -Preference $null -Now $wednesday
Assert-PressureCondition `
    -Condition (-not $absentState.Available -and @($absentState.ToolchainGaps).Count -eq 0) `
    -Message 'Sem o provedor do antimalware a capacidade deve ficar indisponivel, nao falsa'

$scanInsights = Get-PressureInsights `
    -Assessment (
        Get-PressureAssessment `
            -Metrics (New-TestMetrics -Overrides @{ DiskPercent = 99; DiskQueue = 5; DiskLatencyMs = 60 }) `
            -History @() `
            -GpuAvailable $true
    ) `
    -Metrics (New-TestMetrics -Overrides @{ DiskPercent = 99; DiskQueue = 5; DiskLatencyMs = 60 }) `
    -Consumers ([ordered]@{
        cpu = @(); memory = @(); io = @(); gpu = @(); network = @()
    }) `
    -Defender $scanningState
Assert-PressureCondition `
    -Condition (
        @($scanInsights | Where-Object { $_.Title -match 'Varredura completa' }).Count -eq 1
    ) `
    -Message 'Varredura em curso sob pressao de disco deve virar o primeiro insight'

$quietInsights = Get-PressureInsights `
    -Assessment (Get-PressureAssessment -Metrics (New-TestMetrics) -History @() -GpuAvailable $true) `
    -Metrics (New-TestMetrics) `
    -Consumers ([ordered]@{ cpu = @(); memory = @(); io = @(); gpu = @(); network = @() }) `
    -Defender $scanningState
Assert-PressureCondition `
    -Condition (
        @($quietInsights | Where-Object { $_.Title -match 'Varredura completa' }).Count -eq 0
    ) `
    -Message 'Sem pressao de disco a varredura nao pode ser apresentada como problema'

$disabledWatch = [pscustomobject]@{
    Enabled = $false
    ParentId = [uint32]0
    ParentName = ''
    StartedAt = [datetime]::MinValue
}
Assert-PressureCondition `
    -Condition (Test-PressureParentAlive -Watch $disabledWatch) `
    -Message 'Sem vigia configurado o painel nao pode se autoencerrar'

$liveWatch = Get-PressureParentWatch
Assert-PressureCondition `
    -Condition (
        -not $liveWatch.Enabled -or
        (Test-PressureParentAlive -Watch $liveWatch)
    ) `
    -Message 'O pai vivo do processo de teste deve ser reconhecido como vivo'

if ($liveWatch.Enabled) {
    $recycledWatch = [pscustomobject]@{
        Enabled = $true
        ParentId = $liveWatch.ParentId
        ParentName = $liveWatch.ParentName
        StartedAt = ([datetime]$liveWatch.StartedAt).AddHours(-1)
    }
    Assert-PressureCondition `
        -Condition (-not (Test-PressureParentAlive -Watch $recycledWatch)) `
        -Message 'PID reciclado com outro horario de criacao nao pode passar por pai vivo'

    $renamedWatch = [pscustomobject]@{
        Enabled = $true
        ParentId = $liveWatch.ParentId
        ParentName = 'processo-que-nao-existe'
        StartedAt = $liveWatch.StartedAt
    }
    Assert-PressureCondition `
        -Condition (-not (Test-PressureParentAlive -Watch $renamedWatch)) `
        -Message 'PID com nome divergente nao pode passar por pai vivo'
}

$ghostWatch = [pscustomobject]@{
    Enabled = $true
    ParentId = [uint32]4294967293
    ParentName = 'pwsh.exe'
    StartedAt = (Get-Date)
}
Assert-PressureCondition `
    -Condition (-not (Test-PressureParentAlive -Watch $ghostWatch)) `
    -Message 'Pai inexistente deve ser reportado como ausente'

$recorderContent = [IO.File]::ReadAllText(
    (Join-Path $repoRoot 'scripts\record-pressure.ps1')
)
Assert-PressureCondition `
    -Condition (-not ($recorderContent -match 'HttpListener')) `
    -Message 'O gravador de fundo nao pode abrir porta nem servir interface'
Assert-PressureCondition `
    -Condition $recorderContent.Contains('Test-PressureParentAlive') `
    -Message 'O gravador deve encerrar quando o processo que o iniciou desaparece'
Assert-PressureCondition `
    -Condition $recorderContent.Contains('ConvertTo-PressureHistoryRecord') `
    -Message 'O gravador deve usar o mesmo formato de historico do painel'
# Casamento por texto acusaria ate a mencao em comentario. O que importa e se
# existe chamada de fato, entao a verificacao usa a arvore sintatica.
$recorderTokens = $null
$recorderErrors = $null
$recorderAst = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $repoRoot 'scripts\record-pressure.ps1'),
    [ref]$recorderTokens,
    [ref]$recorderErrors
)
Assert-PressureCondition `
    -Condition (@($recorderErrors).Count -eq 0) `
    -Message 'O gravador deve ter sintaxe PowerShell valida'
$recorderCommands = @(
    $recorderAst.FindAll(
        { param($node) $node -is [Management.Automation.Language.CommandAst] },
        $true
    ) |
        ForEach-Object { $_.GetCommandName() } |
        Where-Object { $_ }
)
Assert-PressureCondition `
    -Condition ('Stop-Process' -notin $recorderCommands) `
    -Message 'O gravador nao pode encerrar processo algum'
Assert-PressureCondition `
    -Condition ('Remove-Item' -notin $recorderCommands) `
    -Message 'O gravador nao pode remover arquivo algum'
Assert-PressureCondition `
    -Condition ($recorderContent -match 'parar-gravacao\.flag') `
    -Message 'O gravador deve oferecer parada por sinalizador, sem encerrar processo'
Assert-PressureCondition `
    -Condition ($recorderContent -match '\$sinalizadoEm -ge \$startedAt') `
    -Message 'Sinalizador anterior ao inicio nao pode impedir uma nova gravacao'

$serverContent = [IO.File]::ReadAllText(
    (Join-Path $repoRoot 'scripts\start-pressure-dashboard.ps1')
)
Assert-PressureCondition `
    -Condition $serverContent.Contains('GetContextAsync') `
    -Message 'O laco do painel deve usar espera interrompivel para checar o ciclo de vida'
Assert-PressureCondition `
    -Condition (-not ($serverContent -match '\$listener\.GetContext\(\)')) `
    -Message 'O laco do painel nao pode voltar a bloquear indefinidamente'
Assert-PressureCondition `
    -Condition ($serverContent -match "-NoParentWatch") `
    -Message 'O modo -Background deve destacar o filho do vigia de pai'

$integrationDurationMs = $null
if (-not $SkipIntegration) {
    $state = New-PressureMonitorState -RefreshSeconds 5
    $snapshot = Get-PressureSnapshot -State $state
    $integrationDurationMs = $snapshot.CollectionDurationMs

    Assert-PressureCondition `
        -Condition ($snapshot.SchemaVersion -eq 2) `
        -Message 'Snapshot deve usar schema version 2'
    Assert-PressureCondition `
        -Condition (
            $null -ne $snapshot.SelfCost -and
            $snapshot.SelfCost.CollectionCount -ge 1 -and
            $snapshot.SelfCost.LastCollectionMs -ge 0
        ) `
        -Message 'Snapshot deve declarar o custo do proprio painel'
    Assert-PressureCondition `
        -Condition (@($snapshot.Resources).Count -eq 5) `
        -Message 'Snapshot deve conter CPU, memoria, disco, GPU e rede'
    Assert-PressureCondition `
        -Condition (@($snapshot.Consumers.cpu).Count -gt 0) `
        -Message 'Snapshot deve atribuir CPU a processos'
    Assert-PressureCondition `
        -Condition ($null -ne $snapshot.TerminalSummary) `
        -Message 'Snapshot deve incluir resumo agregado do Windows Terminal'
    Assert-PressureCondition `
        -Condition ($null -ne $snapshot.CliSessions) `
        -Message 'Snapshot deve incluir sessoes de CLI e suas arvores'
    Assert-PressureCondition `
        -Condition (
            @(
                $snapshot.CliSessions |
                    Where-Object { $null -eq $_.Termination }
            ).Count -eq 0
        ) `
        -Message 'Cada sessao deve explicar deterministicamente sua elegibilidade'
    Assert-PressureCondition `
        -Condition (
            $null -ne $snapshot.Actions -and
            -not $snapshot.Actions.ProcessTerminationEnabled -and
            $snapshot.Actions.DashboardSelfProtection
        ) `
        -Message 'Snapshot padrao deve manter encerramento desativado e autoprotecao ativa'
    Assert-PressureCondition `
        -Condition (
            @($snapshot.CliSessions | Where-Object HostedByTerminal | Where-Object RootId -eq 0).Count -eq 0
        ) `
        -Message 'Sessao atribuida ao Terminal deve preservar o PID do shell raiz'
    Assert-PressureCondition `
        -Condition (
            @(
                $snapshot.CliSessions |
                    Where-Object { @($_.TopProcesses).Count -gt 5 }
            ).Count -eq 0
        ) `
        -Message 'Cada sessao deve limitar a lista de ofensores para manter o payload pequeno'
    Assert-PressureCondition `
        -Condition (-not $snapshot.Privacy.RawCommandLinesExposed) `
        -Message 'Snapshot nao pode expor linhas de comando brutas'
    Assert-PressureCondition `
        -Condition (-not $snapshot.Privacy.ExecutablePathsExposed) `
        -Message 'Snapshot nao pode expor caminhos de executaveis'

    $snapshotJson = $snapshot | ConvertTo-Json -Depth 10 -Compress
    Assert-PressureCondition `
        -Condition (-not $snapshotJson.Contains('"CommandLine"')) `
        -Message 'JSON nao pode conter CommandLine'
    Assert-PressureCondition `
        -Condition (-not $snapshotJson.Contains('"ExecutablePath"')) `
        -Message 'JSON nao pode conter ExecutablePath'

    $currentMetadata = $state.MetadataByPid[[string]$PID]
    Assert-PressureCondition `
        -Condition ($null -ne $currentMetadata -and $currentMetadata.Protected) `
        -Message 'O pwsh que executa o teste deve permanecer marcado como protegido'
}

if ($failures.Count -gt 0) {
    Write-Host "Falharam $($failures.Count) verificacoes:" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host " - $failure" -ForegroundColor Red
    }
    exit 1
}

[pscustomobject]@{
    Status = 'passed'
    Checks = $checks
    IntegrationExecuted = -not $SkipIntegration
    IntegrationDurationMs = $integrationDurationMs
} | ConvertTo-Json -Depth 3
