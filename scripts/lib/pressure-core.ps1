Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:PressureProtectedProcessNames = @(
    'WindowsTerminal',
    'OpenConsole',
    'conhost',
    'powershell',
    'pwsh',
    'cmd',
    'bash',
    'wsl',
    'codex',
    'claude',
    'gemini',
    'grok',
    'opencode'
)

$script:PressureTerminalHostProcessNames = @(
    'windowsterminal',
    'openconsole',
    'conhost'
)

$script:PressureShellProcessNames = @(
    'powershell',
    'pwsh',
    'cmd',
    'bash',
    'wsl',
    'wslhost',
    'nu',
    'zsh',
    'fish'
)

$script:PressureCliDisplayNames = @{
    codex = 'Codex'
    claude = 'Claude'
    gemini = 'Gemini'
    grok = 'Grok'
    opencode = 'OpenCode'
}

function Get-PressureBaseProcessName {
    param([AllowEmptyString()][string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return ''
    }

    return [IO.Path]::GetFileNameWithoutExtension($Name).ToLowerInvariant()
}

function Get-PressureCliIdentity {
    param(
        [AllowEmptyString()][string]$Name,
        [AllowEmptyString()][string]$CommandLine = ''
    )

    $baseName = Get-PressureBaseProcessName -Name $Name
    if ($script:PressureCliDisplayNames.ContainsKey($baseName)) {
        return [pscustomobject]@{
            Name = [string]$script:PressureCliDisplayNames[$baseName]
            DetectedBy = 'process-name'
            Confidence = 'alta'
        }
    }

    $safeCommandHint = if ($null -eq $CommandLine) { '' } else { $CommandLine }
    $packagePatterns = [ordered]@{
        Codex = '(?i)[\\/]@openai[\\/]codex(?:[\\/]|$)'
        Claude = '(?i)[\\/]@anthropic-ai[\\/]claude-code(?:[\\/]|$)'
        Gemini = '(?i)[\\/]@google[\\/]gemini-cli(?:[\\/]|$)'
        OpenCode = '(?i)(?:[\\/]sst[\\/]opencode|[\\/]opencode[\\/]bin)(?:[\\/]|$)'
    }
    foreach ($entry in $packagePatterns.GetEnumerator()) {
        if ($safeCommandHint -match $entry.Value) {
            return [pscustomobject]@{
                Name = [string]$entry.Key
                DetectedBy = 'package-signature'
                Confidence = 'alta'
            }
        }
    }

    return [pscustomobject]@{
        Name = ''
        DetectedBy = 'none'
        Confidence = 'nenhuma'
    }
}

function Get-PressureWorkloadLabel {
    param(
        [Parameter(Mandatory)][string]$Name,
        [AllowEmptyString()][string]$CommandLine = '',
        [AllowEmptyString()][string]$CliName = ''
    )

    $baseName = Get-PressureBaseProcessName -Name $Name
    $safeCommandHint = if ($null -eq $CommandLine) { '' } else { $CommandLine }

    if (-not [string]::IsNullOrWhiteSpace($CliName)) {
        return "$CliName CLI"
    }
    if (
        $baseName -match '(semgrep|eslint|stylelint|sonar|scanner)' -or
        $safeCommandHint -match '(?i)(semgrep|eslint|stylelint|sonar|scanner)'
    ) {
        return 'Análise de código'
    }
    if (
        $baseName -match '(testhost|vstest|pytest)' -or
        $safeCommandHint -match '(?i)(playwright|cypress|jest|vitest|pytest|vstest)'
    ) {
        return 'Testes e validação'
    }
    if ($safeCommandHint -match '(?i)(webpack|vite|rollup|next\s+build|dotnet\s+build|msbuild)') {
        return 'Build ou compilação'
    }
    if (
        $baseName -match '(^|[-_.])mcp($|[-_.])' -or
        $safeCommandHint -match '(?i)(?:^|[\\/\s._-])mcp(?:$|[\\/\s._-])'
    ) {
        return 'Servidor MCP'
    }
    if ($baseName -in $script:PressureShellProcessNames) {
        return 'Shell da sessão'
    }
    if ($baseName -in @('node', 'python', 'pythonw', 'dotnet', 'java', 'ruby')) {
        return 'Runtime auxiliar'
    }
    if ($baseName -in $script:PressureTerminalHostProcessNames) {
        return 'Host do terminal'
    }

    return 'Processo auxiliar'
}

function Test-PressureProtectedProcess {
    param([AllowEmptyString()][string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }

    $baseName = [IO.Path]::GetFileNameWithoutExtension($Name)
    return $baseName -in $script:PressureProtectedProcessNames
}

function Get-PressureProcessTreeMembers {
    param(
        [Parameter(Mandatory)][uint32]$RootId,
        [Parameter(Mandatory)][hashtable]$MetadataByPid
    )

    $rootKey = [string]$RootId
    if (-not $MetadataByPid.ContainsKey($rootKey)) {
        return @()
    }

    $childrenByParent = @{}
    foreach ($candidate in $MetadataByPid.Values) {
        $parentKey = [string][uint32]$candidate.ParentId
        if (-not $childrenByParent.ContainsKey($parentKey)) {
            $childrenByParent[$parentKey] = [Collections.Generic.List[object]]::new()
        }
        $childrenByParent[$parentKey].Add($candidate)
    }

    $pending = [Collections.Generic.Queue[object]]::new()
    $visited = [Collections.Generic.HashSet[uint32]]::new()
    $members = [Collections.Generic.List[object]]::new()
    $pending.Enqueue($MetadataByPid[$rootKey])

    while ($pending.Count -gt 0) {
        $current = $pending.Dequeue()
        $currentId = [uint32]$current.Id
        if (-not $visited.Add($currentId)) {
            continue
        }
        $members.Add($current)

        $currentKey = [string]$currentId
        if (-not $childrenByParent.ContainsKey($currentKey)) {
            continue
        }

        foreach ($child in $childrenByParent[$currentKey]) {
            $parentCreated = [datetime]$current.CreationDate
            $childCreated = [datetime]$child.CreationDate
            if (
                $parentCreated -ne [datetime]::MinValue -and
                $childCreated -ne [datetime]::MinValue -and
                $childCreated -lt $parentCreated
            ) {
                continue
            }
            $pending.Enqueue($child)
        }
    }

    return @($members)
}

function Get-PressureProcessLineageIds {
    param(
        [Parameter(Mandatory)][uint32]$ProcessId,
        [Parameter(Mandatory)][hashtable]$MetadataByPid
    )

    $lineage = [Collections.Generic.List[uint32]]::new()
    $visited = [Collections.Generic.HashSet[uint32]]::new()
    $cursorKey = [string]$ProcessId

    while ($MetadataByPid.ContainsKey($cursorKey) -and $lineage.Count -lt 64) {
        $cursor = $MetadataByPid[$cursorKey]
        $cursorId = [uint32]$cursor.Id
        if (-not $visited.Add($cursorId)) {
            break
        }
        $lineage.Add($cursorId)

        $parentId = [uint32]$cursor.ParentId
        $parentKey = [string]$parentId
        if ($parentId -eq 0 -or -not $MetadataByPid.ContainsKey($parentKey)) {
            break
        }

        $parent = $MetadataByPid[$parentKey]
        $cursorCreated = [datetime]$cursor.CreationDate
        $parentCreated = [datetime]$parent.CreationDate
        if (
            $cursorCreated -ne [datetime]::MinValue -and
            $parentCreated -ne [datetime]::MinValue -and
            $parentCreated -gt $cursorCreated
        ) {
            break
        }
        $cursorKey = $parentKey
    }

    return @($lineage)
}

function Get-PressureProcessIdentityFingerprint {
    param([Parameter(Mandatory)][object[]]$Processes)

    if ($Processes.Count -eq 0) {
        return ''
    }

    $identityLines = [Collections.Generic.List[string]]::new()
    foreach ($process in $Processes | Sort-Object Id) {
        $created = [datetime]$process.CreationDate
        if ($created -eq [datetime]::MinValue) {
            return ''
        }
        $identityLines.Add(
            (
                '{0}|{1}|{2}|{3}' -f
                    [uint32]$process.Id,
                    (Get-PressureBaseProcessName -Name ([string]$process.Name)),
                    [uint32]$process.ParentId,
                    $created.ToUniversalTime().Ticks
            )
        )
    }

    $payload = [Text.Encoding]::UTF8.GetBytes(($identityLines -join "`n"))
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha256.ComputeHash($payload)
        return ([Convert]::ToHexString($hash)).ToLowerInvariant()
    } finally {
        $sha256.Dispose()
    }
}

function Get-PressureCliTerminationDisposition {
    param(
        [Parameter(Mandatory)][uint32]$RootId,
        [Parameter(Mandatory)][bool]$HostedByTerminal,
        [Parameter(Mandatory)][object[]]$IdentityMembers,
        [Parameter(Mandatory)][hashtable]$MetadataByPid,
        [uint32[]]$ProtectedProcessIds = @()
    )

    $root = @($IdentityMembers | Where-Object { [uint32]$_.Id -eq $RootId } | Select-Object -First 1)
    $fingerprint = Get-PressureProcessIdentityFingerprint -Processes $IdentityMembers
    $rootStartedAt = if (
        $root.Count -gt 0 -and
        [datetime]$root[0].CreationDate -ne [datetime]::MinValue
    ) {
        ([datetime]$root[0].CreationDate).ToString('o')
    } else {
        $null
    }
    $parentId = if ($root.Count -gt 0) { [uint32]$root[0].ParentId } else { [uint32]0 }
    $parentName = if ($root.Count -gt 0) { [string]$root[0].ParentName } else { '' }

    $result = [ordered]@{
        Eligible = $false
        Code = 'identity_unverified'
        Label = 'NÃO VERIFICADA'
        Reason = 'A identidade completa da árvore não está disponível nesta amostra.'
        RootId = $RootId
        RootStartedAt = $rootStartedAt
        ParentId = $parentId
        ParentName = $parentName
        ProcessCount = $IdentityMembers.Count
        Fingerprint = $fingerprint
    }

    if ($root.Count -eq 0 -or [string]::IsNullOrWhiteSpace($fingerprint)) {
        return [pscustomobject]$result
    }
    if ($IdentityMembers.Count -gt 512) {
        $result.Code = 'tree_too_large'
        $result.Label = 'REVISÃO MANUAL'
        $result.Reason = 'A árvore passou do limite seguro de 512 PIDs para uma ação pela interface.'
        return [pscustomobject]$result
    }

    if ($HostedByTerminal) {
        $result.Code = 'protected_terminal'
        $result.Label = 'PROTEGIDA'
        $result.Reason = 'A árvore pertence a uma sessão viva do Windows Terminal.'
        return [pscustomobject]$result
    }

    $protectedIdSet = @{}
    foreach ($protectedId in $ProtectedProcessIds) {
        $protectedIdSet[[string][uint32]$protectedId] = $true
    }
    if (
        @(
            $IdentityMembers |
                Where-Object { $protectedIdSet.ContainsKey([string][uint32]$_.Id) }
        ).Count -gt 0
    ) {
        $result.Code = 'protected_dashboard'
        $result.Label = 'PAINEL PROTEGIDO'
        $result.Reason = 'A árvore contém o dashboard ou um processo da linhagem que o mantém vivo.'
        return [pscustomobject]$result
    }

    if (
        @(
            $IdentityMembers |
                Where-Object {
                    (Get-PressureBaseProcessName -Name ([string]$_.Name)) -in
                        @('windowsterminal', 'openconsole')
                }
        ).Count -gt 0
    ) {
        $result.Code = 'protected_terminal_host'
        $result.Label = 'PROTEGIDA'
        $result.Reason = 'A árvore contém um host de terminal protegido.'
        return [pscustomobject]$result
    }

    if (
        @(
            $IdentityMembers |
                Where-Object {
                    $null -ne $_.PSObject.Properties['ServiceNames'] -and
                    @($_.ServiceNames).Count -gt 0
                }
        ).Count -gt 0
    ) {
        $result.Code = 'protected_service'
        $result.Label = 'SERVIÇO PROTEGIDO'
        $result.Reason = 'A árvore contém um processo associado a serviço do Windows.'
        return [pscustomobject]$result
    }

    if ($parentId -gt 0 -and $MetadataByPid.ContainsKey([string]$parentId)) {
        $parent = $MetadataByPid[[string]$parentId]
        $rootCreated = [datetime]$root[0].CreationDate
        $parentCreated = [datetime]$parent.CreationDate
        if ($parentCreated -eq [datetime]::MinValue) {
            $result.Code = 'parent_unverified'
            $result.Reason = 'O processo pai existe, mas seu horário de criação não pôde ser validado.'
            return [pscustomobject]$result
        }
        if ($parentCreated -le $rootCreated) {
            $result.Code = 'managed_parent'
            $result.Label = 'GERENCIADA'
            $result.ParentName = [string]$parent.Name
            $result.Reason = (
                "O processo pai $([IO.Path]::GetFileNameWithoutExtension([string]$parent.Name)) " +
                "[PID $parentId] continua vivo e pode recriar esta CLI."
            )
            return [pscustomobject]$result
        }
    }

    $result.Eligible = $true
    $result.Code = 'orphan_candidate'
    $result.Label = 'ÓRFÃ CONFIRMADA'
    $result.Reason = (
        'O pai original não existe mais ou o PID dele foi reutilizado; ' +
        'a árvore não pertence ao Terminal nem contém o dashboard.'
    )
    return [pscustomobject]$result
}

function Test-PressureCimClass {
    param(
        [Parameter(Mandatory)][string]$ClassName,
        [string]$Namespace = 'root/cimv2'
    )

    try {
        return [bool](Get-CimClass -Namespace $Namespace -ClassName $ClassName -ErrorAction Stop)
    } catch {
        return $false
    }
}

function Get-PressureProcessContext {
    param(
        [Parameter(Mandatory)][string]$Name,
        [AllowEmptyString()][string]$ParentName = '',
        [AllowEmptyString()][string]$CommandLine = '',
        [string[]]$ServiceNames = @()
    )

    $baseName = [IO.Path]::GetFileNameWithoutExtension($Name).ToLowerInvariant()
    $parentBase = if ([string]::IsNullOrWhiteSpace($ParentName)) {
        ''
    } else {
        [IO.Path]::GetFileNameWithoutExtension($ParentName).ToLowerInvariant()
    }
    $safeCommandHint = if ($null -eq $CommandLine) { '' } else { $CommandLine }

    $category = 'Aplicativo'
    $purpose = 'Aplicativo em execução; a finalidade exata não é exposta pelos contadores.'

    if ($baseName -in @('windowsterminal', 'openconsole', 'conhost')) {
        $category = 'Terminal'
        $purpose = 'Hospeda janelas e sessões de terminal ativas.'
    } elseif ($baseName -in @(
        'powershell', 'pwsh', 'cmd', 'bash', 'wsl',
        'codex', 'claude', 'gemini', 'grok', 'opencode'
    )) {
        $category = 'CLI e automação'
        $purpose = 'Sessão de linha de comando, automação ou assistência de desenvolvimento.'
    } elseif ($baseName -in @('chrome', 'msedge', 'firefox', 'brave', 'opera')) {
        $category = 'Navegador'
        $purpose = 'Navegador multiprocesso; pode representar aba, extensão, GPU, rede ou renderização.'
    } elseif (
        $parentBase -in @('chrome', 'msedge', 'firefox', 'brave', 'opera') -or
        $baseName -match '^(chrome|msedge|firefox|brave|opera)_'
    ) {
        $category = 'Navegador'
        $purpose = 'Processo auxiliar de navegador; o PID isolado não identifica a aba ou extensão.'
    } elseif ($baseName -in @('code', 'devenv', 'rider64', 'idea64', 'webstorm64')) {
        $category = 'Desenvolvimento'
        $purpose = 'Editor ou IDE, incluindo extensões, análise de código e indexação.'
    } elseif ($baseName -in @(
        'node', 'npm', 'npx', 'yarn', 'pnpm', 'dotnet', 'msbuild',
        'vstest.console', 'testhost', 'java', 'javac', 'python', 'pythonw'
    )) {
        $category = 'Runtime de desenvolvimento'
        if ($safeCommandHint -match '(?i)(test|vstest|jest|vitest|playwright|cypress)') {
            $purpose = 'Runtime executando testes ou validações de desenvolvimento.'
        } elseif ($safeCommandHint -match '(?i)(build|webpack|vite|next|rollup|compile)') {
            $purpose = 'Runtime executando build, compilação ou servidor de desenvolvimento.'
        } elseif ($parentBase -in @('codex', 'claude', 'gemini', 'grok', 'opencode')) {
            $purpose = 'Runtime auxiliar iniciado por uma CLI de assistência de desenvolvimento.'
        } else {
            $purpose = 'Runtime de aplicação, build, teste ou ferramenta de desenvolvimento.'
        }
    } elseif ($baseName -in @('vmmem', 'vmmemwsl', 'wslservice')) {
        $category = 'Virtualização'
        $purpose = 'Representa memória e trabalho de máquinas virtuais, WSL ou contêineres.'
    } elseif ($baseName -match '^(docker desktop|com\.docker|dockerd)$') {
        $category = 'Contêineres'
        $purpose = 'Gerencia contêineres, imagens, redes e máquinas virtuais do Docker.'
    } elseif ($baseName -eq 'system') {
        $category = 'Windows e drivers'
        $purpose = 'Trabalho do kernel e de drivers, frequentemente ligado a disco, rede, interrupções ou DPCs.'
    } elseif ($baseName -eq 'idle') {
        $category = 'Windows'
        $purpose = 'Tempo ocioso do processador; não é um consumidor real.'
    } elseif ($baseName -eq 'dwm') {
        $category = 'Interface gráfica'
        $purpose = 'Compõe janelas, animações, monitores e superfícies gráficas do desktop.'
    } elseif ($baseName -in @('csrss', 'wininit', 'winlogon', 'lsass', 'services')) {
        $category = 'Windows'
        $purpose = 'Componente central do Windows; deve ser interpretado no contexto do subsistema que hospeda.'
    } elseif ($baseName -eq 'svchost') {
        $category = 'Serviços do Windows'
        if ($ServiceNames.Count -gt 0) {
            $shownServices = @($ServiceNames | Select-Object -First 3)
            $suffix = if ($ServiceNames.Count -gt 3) { ' e outros' } else { '' }
            $purpose = "Hospeda serviços do Windows: $($shownServices -join ', ')$suffix."
        } else {
            $purpose = 'Hospeda um ou mais serviços do Windows.'
        }
    } elseif ($baseName -in @('msmpeng', 'msmpengcp', 'nissrv')) {
        $category = 'Segurança'
        $purpose = 'Microsoft Defender verificando arquivos, processos ou tráfego em tempo real.'
    } elseif ($baseName -in @(
        'tiworker', 'trustedinstaller', 'mousocoreworker', 'usoclient'
    )) {
        $category = 'Manutenção do Windows'
        $purpose = 'Instala, verifica ou mantém componentes e atualizações do Windows.'
    } elseif ($baseName -in @('searchindexer', 'searchhost', 'searchprotocolhost')) {
        $category = 'Pesquisa'
        $purpose = 'Indexa ou consulta conteúdo para a pesquisa do Windows.'
    } elseif ($baseName -eq 'memory compression') {
        $category = 'Memória do Windows'
        $purpose = 'Comprime páginas em RAM para reduzir paginação em disco.'
    } elseif ($baseName -eq 'explorer') {
        $category = 'Interface do Windows'
        $purpose = 'Shell do Windows, área de trabalho e navegação de arquivos.'
    } elseif ($baseName -in @('onedrive', 'dropbox', 'googledrivefs')) {
        $category = 'Sincronização'
        $purpose = 'Sincroniza arquivos locais com armazenamento remoto.'
    } elseif ($baseName -in @('teams', 'ms-teams', 'slack', 'discord')) {
        $category = 'Comunicação'
        $purpose = 'Comunicação em tempo real, mídia, notificações e interface baseada em web.'
    } elseif ($baseName -in @('obs64', 'ffmpeg', 'handbrake', 'vlc')) {
        $category = 'Mídia'
        $purpose = 'Captura, codifica, decodifica ou reproduz áudio e vídeo.'
    }

    [pscustomobject]@{
        Category = $category
        Purpose = $purpose
    }
}

function New-PressureMonitorState {
    [CmdletBinding()]
    param(
        [ValidateRange(2, 60)]
        [int]$RefreshSeconds = 5,

        [ValidateRange(15, 300)]
        [int]$MetadataRefreshSeconds = 45,

        [ValidateRange(15, 3600)]
        [int]$DefenderRefreshSeconds = 60,

        # Ler o log do antimalware custa mais que uma amostra comum, e a resposta
        # muda devagar. Só vale reler quando o motor está de fato trabalhando.
        [ValidateRange(60, 86400)]
        [int]$ScanCostRefreshSeconds = 600,

        # A sondagem do Docker chama CLI externa em processo filho; a cadência
        # própria limita esse custo e o prazo duro impede que um motor afogado
        # pendure a coleta do painel.
        [ValidateRange(10, 3600)]
        [int]$DockerRefreshSeconds = 30,

        [ValidateRange(2, 600)]
        [int]$MaxRefreshSeconds = 30,

        [switch]$FixedCadence,

        [string[]]$CliHomeRoots = @(),

        # Mapa declarado dos perfis de CLI. Perfil fora do diretorio do usuario
        # nao apareceria na descoberta por convencao, e a exposicao seria
        # subcontada sem aviso. Vazio mantem apenas a raiz do usuario.
        [AllowEmptyString()]
        [string]$CliProfileMapPath = '',

        [switch]$ProcessTerminationEnabled,

        [uint32]$DashboardProcessId = [uint32]$PID
    )

    if (-not $IsWindows) {
        throw 'O coletor deste MVP requer Windows 10 ou Windows 11.'
    }

    $computer = Get-CimInstance `
        -ClassName Win32_ComputerSystem `
        -Property NumberOfLogicalProcessors, TotalPhysicalMemory
    $gpuEngineAvailable = Test-PressureCimClass `
        -ClassName 'Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine'
    $gpuMemoryAvailable = Test-PressureCimClass `
        -ClassName 'Win32_PerfFormattedData_GPUPerformanceCounters_GPUProcessMemory'
    $gpuAdapterMemoryAvailable = Test-PressureCimClass `
        -ClassName 'Win32_PerfFormattedData_GPUPerformanceCounters_GPUAdapterMemory'
    $tcpConnectionAvailable = Test-PressureCimClass `
        -Namespace 'root/StandardCimv2' `
        -ClassName 'MSFT_NetTCPConnection'

    [pscustomobject]@{
        StartedAt = Get-Date
        RefreshSeconds = $RefreshSeconds
        MinRefreshSeconds = $RefreshSeconds
        MaxRefreshSeconds = [math]::Max($RefreshSeconds, $MaxRefreshSeconds)
        AdaptiveCadence = -not [bool]$FixedCadence
        CadenceRelaxed = $false
        MetadataRefreshSeconds = $MetadataRefreshSeconds
        ProcessTerminationEnabled = [bool]$ProcessTerminationEnabled
        DashboardProcessId = $DashboardProcessId
        LogicalProcessorCount = [math]::Max(1, [int]$computer.NumberOfLogicalProcessors)
        TotalPhysicalMemoryBytes = [double]$computer.TotalPhysicalMemory
        MetadataByPid = @{}
        MetadataRefreshAt = [datetime]::MinValue
        ProcessIdentityCache = @{}
        ConnectionCountsByPid = @{}
        ConnectionRefreshAt = (Get-Date).AddSeconds(10)
        DiskCapacities = @()
        DiskCapacityRefreshAt = [datetime]::MinValue
        PreviousDiskRawByName = @{}
        PreviousCpuRaw = $null
        History = [Collections.Generic.List[object]]::new()
        CollectionCount = 0
        CollectionMsTotal = 0.0
        CollectionMsMax = 0.0
        DefenderRefreshSeconds = $DefenderRefreshSeconds
        DefenderRefreshAt = [datetime]::MinValue
        DefenderStatus = $null
        DefenderPreference = $null
        DefenderScanProcess = $null
        ScanCost = $null
        ScanCostRefreshAt = [datetime]::MinValue
        ScanCostRefreshSeconds = $ScanCostRefreshSeconds
        ScanCostEngineThreshold = 10
        DockerRefreshSeconds = $DockerRefreshSeconds
        DockerRefreshAt = [datetime]::MinValue
        DockerState = $null
        DockerPreviousVmmem = $null
        CliHomeRoots = @(
            Get-PressureCliHomeRoots `
                -ExplicitRoot $CliHomeRoots `
                -ProfileMapPath $CliProfileMapPath
        )
        CliHomes = @()
        Capabilities = [ordered]@{
            GpuEngine = $gpuEngineAvailable
            GpuProcessMemory = $gpuMemoryAvailable
            GpuAdapterMemory = $gpuAdapterMemoryAvailable
            TcpConnections = $tcpConnectionAvailable
            HttpListener = [System.Net.HttpListener]::IsSupported
            VendorHardwareSensors = $false
            EtwRootCause = $false
            Defender = $false
            Docker = $false
        }
    }
}

function Resolve-PressureProcessMetadataTopology {
    param([Parameter(Mandatory)][hashtable]$MetadataByPid)

    foreach ($entry in $MetadataByPid.Values) {
        $path = [Collections.Generic.List[object]]::new()
        $seen = @{}
        $cursor = $entry

        while ($null -ne $cursor -and $path.Count -lt 64) {
            $cursorKey = [string]$cursor.Id
            if ($seen.ContainsKey($cursorKey)) {
                break
            }
            $seen[$cursorKey] = $true
            $path.Add($cursor)

            $parentKey = [string]$cursor.ParentId
            if (
                [uint32]$cursor.ParentId -eq 0 -or
                -not $MetadataByPid.ContainsKey($parentKey)
            ) {
                break
            }

            $parent = $MetadataByPid[$parentKey]
            $childCreated = [datetime]$cursor.CreationDate
            $parentCreated = [datetime]$parent.CreationDate
            if (
                $childCreated -ne [datetime]::MinValue -and
                $parentCreated -ne [datetime]::MinValue -and
                $parentCreated -gt $childCreated
            ) {
                break
            }
            $cursor = $parent
        }

        $terminalIndex = -1
        for ($index = 0; $index -lt $path.Count; $index++) {
            if (
                (Get-PressureBaseProcessName -Name ([string]$path[$index].Name)) -eq
                'windowsterminal'
            ) {
                $terminalIndex = $index
                break
            }
        }

        $terminal = $null
        $sessionRoot = $null
        if ($terminalIndex -ge 0) {
            $terminal = $path[$terminalIndex]
            if ($terminalIndex -gt 0) {
                for ($index = $terminalIndex - 1; $index -ge 0; $index--) {
                    $candidate = $path[$index]
                    $candidateBase = Get-PressureBaseProcessName -Name ([string]$candidate.Name)
                    if ($candidateBase -notin $script:PressureTerminalHostProcessNames) {
                        $sessionRoot = $candidate
                        break
                    }
                }
            }
        }

        $owningCli = $null
        $rootCli = $null
        foreach ($candidate in $path) {
            if ([string]::IsNullOrWhiteSpace([string]$candidate.CliName)) {
                continue
            }
            if ($null -eq $owningCli) {
                $owningCli = $candidate
            }
            $rootCli = $candidate
        }

        $entry.TerminalHosted = $null -ne $terminal
        $entry.TerminalId = if ($null -ne $terminal) {
            [uint32]$terminal.Id
        } else {
            [uint32]0
        }
        $entry.TerminalName = if ($null -ne $terminal) {
            [string]$terminal.Name
        } else {
            ''
        }
        $entry.TerminalSessionRootId = if ($null -ne $sessionRoot) {
            [uint32]$sessionRoot.Id
        } else {
            [uint32]0
        }
        $entry.TerminalSessionRootName = if ($null -ne $sessionRoot) {
            [string]$sessionRoot.Name
        } else {
            ''
        }
        $entry.OwningCliId = if ($null -ne $owningCli) {
            [uint32]$owningCli.Id
        } else {
            [uint32]0
        }
        $entry.OwningCliName = if ($null -ne $owningCli) {
            [string]$owningCli.CliName
        } else {
            ''
        }
        $entry.RootCliId = if ($null -ne $rootCli) {
            [uint32]$rootCli.Id
        } else {
            [uint32]0
        }
        $entry.RootCliName = if ($null -ne $rootCli) {
            [string]$rootCli.CliName
        } else {
            ''
        }

        $lineage = [Collections.Generic.List[object]]::new()
        $lineageIds = @{}
        foreach ($candidate in @($terminal, $sessionRoot, $rootCli, $owningCli, $entry)) {
            if ($null -eq $candidate) {
                continue
            }
            $candidateKey = [string]$candidate.Id
            if ($lineageIds.ContainsKey($candidateKey)) {
                continue
            }
            $lineageIds[$candidateKey] = $true
            $lineage.Add([pscustomobject]@{
                Id = [uint32]$candidate.Id
                Name = if (-not [string]::IsNullOrWhiteSpace([string]$candidate.CliName)) {
                    [string]$candidate.CliName
                } else {
                    [IO.Path]::GetFileNameWithoutExtension([string]$candidate.Name)
                }
            })
        }
        $entry.Lineage = @($lineage)
    }
}

function Get-PressureProcessMetadataSnapshot {
    <#
        As duas consultas CIM abaixo custam ~0,85 s para ~418 processos. O laço
        de classificação custava ~4,2 s — cinco vezes mais que a coleta dos
        dados. As funções que ele chama são puras: dado o mesmo nome, pai,
        linha de comando e conjunto de serviços, devolvem sempre o mesmo
        resultado. Reaproveitá-las por processo elimina o recálculo de quem já
        estava vivo no ciclo anterior, que é a esmagadora maioria.
    #>
    [CmdletBinding()]
    param(
        # Tabela de reaproveitamento entre ciclos. Vazio recalcula tudo, que é
        # o comportamento original e o usado pelos testes.
        [hashtable]$Cache = $null
    )

    $processes = @(
        Get-CimInstance `
            -ClassName Win32_Process `
            -Property ProcessId, Name, ParentProcessId, CommandLine,
                CreationDate, SessionId `
            -ErrorAction Stop
    )
    $services = @(
        Get-CimInstance `
            -ClassName Win32_Service `
            -Property ProcessId, State, Name `
            -ErrorAction SilentlyContinue
    )
    $nameByPid = @{}
    foreach ($process in $processes) {
        $nameByPid[[string]$process.ProcessId] = [string]$process.Name
    }

    $serviceNamesByPid = @{}
    foreach ($service in $services) {
        $servicePid = [uint32]$service.ProcessId
        if ($servicePid -eq 0 -or [string]$service.State -ne 'Running') {
            continue
        }

        $serviceKey = [string]$servicePid
        if (-not $serviceNamesByPid.ContainsKey($serviceKey)) {
            $serviceNamesByPid[$serviceKey] = [Collections.Generic.List[string]]::new()
        }
        $serviceNamesByPid[$serviceKey].Add([string]$service.Name)
    }

    $metadata = @{}
    # Atribuição direta, não via `if` como expressão: uma coleção vazia escrita
    # no fluxo de saída não produz objeto algum, e o HashSet nasceria $null.
    $vistos = $null
    if ($null -ne $Cache) {
        $vistos = [Collections.Generic.HashSet[string]]::new()
    }
    foreach ($process in $processes) {
        $pidKey = [string]$process.ProcessId
        $parentKey = [string]$process.ParentProcessId
        $parentName = if ($nameByPid.ContainsKey($parentKey)) {
            [string]$nameByPid[$parentKey]
        } else {
            ''
        }
        $serviceNames = if ($serviceNamesByPid.ContainsKey($pidKey)) {
            @($serviceNamesByPid[$pidKey])
        } else {
            @()
        }
        $creationDate = if ($null -ne $process.CreationDate) {
            [datetime]$process.CreationDate
        } else {
            [datetime]::MinValue
        }

        # O instante de criação entra na chave porque o Windows recicla PID; os
        # nomes de serviço entram porque um mesmo svchost pode passar a
        # hospedar outro conjunto sem trocar de PID.
        $chaveIdentidade = '{0}|{1}|{2}|{3}' -f `
            $pidKey, $creationDate.Ticks, $parentName, ($serviceNames -join ',')
        $identidade = $null
        if ($null -ne $Cache) {
            $null = $vistos.Add($chaveIdentidade)
            if ($Cache.ContainsKey($chaveIdentidade)) {
                $identidade = $Cache[$chaveIdentidade]
            }
        }
        if ($null -eq $identidade) {
            $context = Get-PressureProcessContext `
                -Name ([string]$process.Name) `
                -ParentName $parentName `
                -CommandLine ([string]$process.CommandLine) `
                -ServiceNames $serviceNames
            $cliIdentity = Get-PressureCliIdentity `
                -Name ([string]$process.Name) `
                -CommandLine ([string]$process.CommandLine)
            $identidade = [pscustomobject]@{
                Category = $context.Category
                Purpose = $context.Purpose
                Protected = Test-PressureProtectedProcess -Name ([string]$process.Name)
                IsTerminalHost = (
                    (Get-PressureBaseProcessName -Name ([string]$process.Name)) -in
                    $script:PressureTerminalHostProcessNames
                )
                CliName = [string]$cliIdentity.Name
                CliDetectionConfidence = [string]$cliIdentity.Confidence
                Workload = Get-PressureWorkloadLabel `
                    -Name ([string]$process.Name) `
                    -CommandLine ([string]$process.CommandLine) `
                    -CliName ([string]$cliIdentity.Name)
            }
            if ($null -ne $Cache) {
                $Cache[$chaveIdentidade] = $identidade
            }
        }

        $metadata[$pidKey] = [pscustomobject]@{
            Id = [uint32]$process.ProcessId
            Name = [string]$process.Name
            ParentId = [uint32]$process.ParentProcessId
            ParentName = $parentName
            CreationDate = $creationDate
            SessionId = [uint32]$process.SessionId
            Category = $identidade.Category
            Purpose = $identidade.Purpose
            ServiceNames = $serviceNames
            Protected = $identidade.Protected
            IsTerminalHost = $identidade.IsTerminalHost
            CliName = $identidade.CliName
            CliDetectionConfidence = $identidade.CliDetectionConfidence
            Workload = $identidade.Workload
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

    # Sem a poda, a tabela acumularia uma entrada por processo já encerrado e
    # cresceria sem limite num painel que fica dias no ar.
    if ($null -ne $Cache) {
        foreach ($chave in @($Cache.Keys)) {
            if (-not $vistos.Contains($chave)) {
                $Cache.Remove($chave)
            }
        }
    }

    Resolve-PressureProcessMetadataTopology -MetadataByPid $metadata
    return $metadata
}

function Update-PressureProcessMetadata {
    param([Parameter(Mandatory)]$State)

    $now = Get-Date
    if ($now -lt $State.MetadataRefreshAt) {
        return
    }

    try {
        $State.MetadataByPid = Get-PressureProcessMetadataSnapshot `
            -Cache $State.ProcessIdentityCache
        $State.MetadataRefreshAt = $now.AddSeconds($State.MetadataRefreshSeconds)
    } catch {
        $State.MetadataRefreshAt = $now.AddSeconds(10)
    }
}

function Update-PressureConnectionCounts {
    param([Parameter(Mandatory)]$State)

    $now = Get-Date
    if (-not $State.Capabilities.TcpConnections -or $now -lt $State.ConnectionRefreshAt) {
        return
    }

    try {
        $connections = @(
            Get-CimInstance `
                -Namespace 'root/StandardCimv2' `
                -ClassName 'MSFT_NetTCPConnection' `
                -Property State, OwningProcess `
                -ErrorAction Stop
        )
        $counts = @{}
        foreach ($connection in $connections) {
            if ([uint32]$connection.State -ne 5) {
                continue
            }

            $pidKey = [string]$connection.OwningProcess
            if (-not $counts.ContainsKey($pidKey)) {
                $counts[$pidKey] = 0
            }
            $counts[$pidKey]++
        }
        $State.ConnectionCountsByPid = $counts
        $State.ConnectionRefreshAt = $now.AddSeconds(60)
    } catch {
        $State.ConnectionRefreshAt = $now.AddSeconds(20)
    }
}

function Update-PressureDiskCapacities {
    param([Parameter(Mandatory)]$State)

    $now = Get-Date
    if ($now -lt $State.DiskCapacityRefreshAt) {
        return
    }

    try {
        $volumes = @(
            Get-CimInstance `
                -ClassName Win32_LogicalDisk `
                -Filter 'DriveType=3' `
                -Property DeviceId, Size, FreeSpace `
                -ErrorAction Stop
        )
        $State.DiskCapacities = @(
            foreach ($volume in $volumes) {
                $size = [double]$volume.Size
                $free = [double]$volume.FreeSpace
                [pscustomobject]@{
                    Drive = [string]$volume.DeviceId
                    SizeGB = [math]::Round($size / 1GB, 1)
                    FreeGB = [math]::Round($free / 1GB, 2)
                    FreePercent = if ($size -gt 0) {
                        [math]::Round(100 * $free / $size, 1)
                    } else {
                        $null
                    }
                }
            }
        )
        $State.DiskCapacityRefreshAt = $now.AddSeconds(60)
    } catch {
        $State.DiskCapacityRefreshAt = $now.AddSeconds(20)
    }
}

function Get-PressureUnsignedDelta32 {
    param(
        [Parameter(Mandatory)][uint64]$Current,
        [Parameter(Mandatory)][uint64]$Previous
    )

    if ($Current -ge $Previous) {
        return [double]($Current - $Previous)
    }

    return [double](([uint32]::MaxValue - $Previous) + $Current + 1)
}

function Get-PressureCpuUtilization {
    <#
        Win32_PerfFormattedData_PerfOS_Processor entrega o percentual já cozido
        pelo provedor WMI, calculado contra uma amostra anterior que não é a
        nossa. Em consulta avulsa ele oscila sem relação com a carga real —
        medido nesta base, marcou 100% com a máquina em 43% e 7% com ela em 57%.
        Aqui derivamos o valor do contador bruto, com o intervalo que o próprio
        coletor controla.

        PercentProcessorTime da instância _Total é um PERF_100NSEC_TIMER_INV:
        acumula tempo ocioso, então a utilização é o complemento da fração
        ociosa do intervalo. Não se divide por núcleo — a instância _Total já
        vem normalizada, e dividir prende a leitura em 95-100%.

        Devolve $null quando ainda não há amostra anterior ou o contador foi
        reiniciado. Quem chama traduz isso em CpuAvailable = $false, porque
        leitura ausente não é máquina ociosa.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$RawRows,
        [Parameter(Mandatory)]$State
    )

    $row = $RawRows | Where-Object Name -eq '_Total' | Select-Object -First 1
    if ($null -eq $row) {
        $State.PreviousCpuRaw = $null
        return $null
    }

    $current = [pscustomobject]@{
        IdleTicks = [uint64]$row.PercentProcessorTime
        Timestamp = [uint64]$row.Timestamp_Sys100NS
    }
    $previous = $State.PreviousCpuRaw
    $State.PreviousCpuRaw = $current

    if ($null -eq $previous) {
        return $null
    }
    if ($current.Timestamp -le $previous.Timestamp -or
        $current.IdleTicks -lt $previous.IdleTicks) {
        return $null
    }

    $elapsed = [double]($current.Timestamp - $previous.Timestamp)
    $idle = [double]($current.IdleTicks - $previous.IdleTicks)
    $busy = 100 * (1 - ($idle / $elapsed))
    return [math]::Round([math]::Min(100, [math]::Max(0, $busy)), 1)
}

function Get-PressureDiskLatencies {
    param(
        [Parameter(Mandatory)][object[]]$RawRows,
        [Parameter(Mandatory)]$State
    )

    $latencies = @{}
    $nextRaw = @{}
    foreach ($row in $RawRows) {
        $name = [string]$row.Name
        $nextRaw[$name] = $row
        if (-not $State.PreviousDiskRawByName.ContainsKey($name)) {
            continue
        }

        $previous = $State.PreviousDiskRawByName[$name]
        $frequency = [double]$row.Frequency_PerfTime
        if ($frequency -le 0) {
            continue
        }

        $transferBaseDelta = Get-PressureUnsignedDelta32 `
            -Current ([uint64]$row.AvgDiskSecPerTransfer_Base) `
            -Previous ([uint64]$previous.AvgDiskSecPerTransfer_Base)
        $readBaseDelta = Get-PressureUnsignedDelta32 `
            -Current ([uint64]$row.AvgDiskSecPerRead_Base) `
            -Previous ([uint64]$previous.AvgDiskSecPerRead_Base)
        $writeBaseDelta = Get-PressureUnsignedDelta32 `
            -Current ([uint64]$row.AvgDiskSecPerWrite_Base) `
            -Previous ([uint64]$previous.AvgDiskSecPerWrite_Base)

        $transferMs = if ($transferBaseDelta -gt 0) {
            $counterDelta = Get-PressureUnsignedDelta32 `
                -Current ([uint64]$row.AvgDiskSecPerTransfer) `
                -Previous ([uint64]$previous.AvgDiskSecPerTransfer)
            1000 * (($counterDelta / $frequency) / $transferBaseDelta)
        } else {
            $null
        }
        $readMs = if ($readBaseDelta -gt 0) {
            $counterDelta = Get-PressureUnsignedDelta32 `
                -Current ([uint64]$row.AvgDiskSecPerRead) `
                -Previous ([uint64]$previous.AvgDiskSecPerRead)
            1000 * (($counterDelta / $frequency) / $readBaseDelta)
        } else {
            $null
        }
        $writeMs = if ($writeBaseDelta -gt 0) {
            $counterDelta = Get-PressureUnsignedDelta32 `
                -Current ([uint64]$row.AvgDiskSecPerWrite) `
                -Previous ([uint64]$previous.AvgDiskSecPerWrite)
            1000 * (($counterDelta / $frequency) / $writeBaseDelta)
        } else {
            $null
        }

        $latencies[$name] = [pscustomobject]@{
            TransferMs = if ($null -ne $transferMs) {
                [math]::Round([math]::Max(0, $transferMs), 2)
            } else {
                $null
            }
            ReadMs = if ($null -ne $readMs) {
                [math]::Round([math]::Max(0, $readMs), 2)
            } else {
                $null
            }
            WriteMs = if ($null -ne $writeMs) {
                [math]::Round([math]::Max(0, $writeMs), 2)
            } else {
                $null
            }
        }
    }

    $State.PreviousDiskRawByName = $nextRaw
    return $latencies
}

function Get-PressureGpuEngineData {
    param([object[]]$Rows = @())

    $byPid = @{}
    $overallPercent = 0.0
    $overallEngine = ''
    foreach ($row in $Rows) {
        $name = [string]$row.Name
        if ($name -notmatch '^pid_(?<pid>\d+)_.*_phys_(?<physical>\d+)_eng_\d+_engtype_(?<engine>.*)$') {
            continue
        }

        $pidKey = [string]$Matches.pid
        $engine = if ([string]::IsNullOrWhiteSpace($Matches.engine)) {
            'Outro'
        } else {
            [string]$Matches.engine
        }
        $utilization = [math]::Min(100, [math]::Max(
            0,
            [double]$row.UtilizationPercentage
        ))

        if (-not $byPid.ContainsKey($pidKey) -or $utilization -gt $byPid[$pidKey].Percent) {
            $byPid[$pidKey] = [pscustomobject]@{
                Percent = [math]::Round($utilization, 1)
                Engine = $engine
                PhysicalAdapter = [int]$Matches.physical
            }
        }

        if ($utilization -gt $overallPercent) {
            $overallPercent = $utilization
            $overallEngine = $engine
        }
    }

    [pscustomobject]@{
        ByPid = $byPid
        OverallPercent = [math]::Round($overallPercent, 1)
        OverallEngine = $overallEngine
    }
}

function Get-PressureGpuMemoryData {
    param([object[]]$Rows = @())

    $byPid = @{}
    foreach ($row in $Rows) {
        $name = [string]$row.Name
        if ($name -notmatch '^pid_(?<pid>\d+)_') {
            continue
        }

        $pidKey = [string]$Matches.pid
        if (-not $byPid.ContainsKey($pidKey)) {
            $byPid[$pidKey] = [pscustomobject]@{
                DedicatedBytes = 0.0
                SharedBytes = 0.0
                CommittedBytes = 0.0
            }
        }
        $byPid[$pidKey].DedicatedBytes += [double]$row.DedicatedUsage
        $byPid[$pidKey].SharedBytes += [double]$row.SharedUsage
        $byPid[$pidKey].CommittedBytes += [double]$row.TotalCommitted
    }

    return $byPid
}

function Get-PressureTrailingCount {
    param(
        [Parameter(Mandatory)][object[]]$Samples,
        [Parameter(Mandatory)][string]$Property,
        [Parameter(Mandatory)][double]$Threshold
    )

    $count = 0
    for ($index = $Samples.Count - 1; $index -ge 0; $index--) {
        $propertyValue = $Samples[$index].PSObject.Properties[$Property]
        if ($null -eq $propertyValue -or $null -eq $propertyValue.Value) {
            break
        }
        if ([double]$propertyValue.Value -lt $Threshold) {
            break
        }
        $count++
    }
    return $count
}

function Get-PressureLevelName {
    param([ValidateRange(0, 4)][int]$Level)

    return @('SAUDÁVEL', 'OBSERVAR', 'ATENÇÃO', 'CRÍTICO', 'EMERGÊNCIA')[$Level]
}

function Test-PressureMetricAvailable {
    <#
    .SYNOPSIS
    Diz se a leitura de um recurso chegou nesta amostra.

    .DESCRIPTION
    Amostras gravadas antes desta versão não trazem os campos de
    disponibilidade. Campo ausente significa "coletado normalmente", nunca
    falha: tratar ausência como falha reescreveria o histórico inteiro como
    indisponível.
    #>
    param(
        [Parameter(Mandatory)]$Metrics,
        [Parameter(Mandatory)][string]$Property
    )

    if ($null -eq $Metrics) {
        return $false
    }
    $field = $Metrics.PSObject.Properties[$Property]
    if ($null -eq $field) {
        return $true
    }
    return [bool]$field.Value
}

function New-PressureResourceAssessment {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Label,
        [ValidateRange(0, 4)][int]$Level,
        [ValidateRange(0, 100)][double]$Score,
        [AllowNull()]$Value,
        [Parameter(Mandatory)][string]$Unit,
        [Parameter(Mandatory)][string]$Detail,
        [Parameter(Mandatory)][string]$Basis,
        [bool]$Available = $true
    )

    [pscustomobject]@{
        Key = $Key
        Label = $Label
        Level = $Level
        State = Get-PressureLevelName -Level $Level
        Score = [math]::Round([math]::Min(100, [math]::Max(0, $Score)), 1)
        Value = $Value
        Unit = $Unit
        Detail = $Detail
        Basis = $Basis
        Available = $Available
    }
}

function Get-PressureAssessment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Metrics,
        [object[]]$History = @(),
        [bool]$GpuAvailable = $true
    )

    $samples = @($History) + @($Metrics)
    $cpuStreak = Get-PressureTrailingCount `
        -Samples $samples `
        -Property 'CpuPercent' `
        -Threshold 85
    $gpuStreak = Get-PressureTrailingCount `
        -Samples $samples `
        -Property 'GpuPercent' `
        -Threshold 85
    $diskStreak = Get-PressureTrailingCount `
        -Samples $samples `
        -Property 'DiskLatencyMs' `
        -Threshold 50
    $networkStreak = Get-PressureTrailingCount `
        -Samples $samples `
        -Property 'NetworkPercent' `
        -Threshold 80

    # Leitura ausente não é leitura zerada. Sem o contador, o recurso sai como
    # indisponível e fica fora do veredito: zero disponível significaria
    # pressão máxima e o painel anunciaria emergência por falha de coleta.
    $cpuAvailable = Test-PressureMetricAvailable -Metrics $Metrics -Property 'CpuAvailable'
    $cpuPercent = [double]$Metrics.CpuPercent
    $cpuLevel = if (-not $cpuAvailable) {
        0
    } elseif ($cpuPercent -ge 85 -and $cpuStreak -ge 3) {
        3
    } elseif ($cpuPercent -ge 85) {
        2
    } elseif ($cpuPercent -ge 65) {
        1
    } else {
        0
    }
    $cpuBasis = if (-not $cpuAvailable) {
        'O contador de processador não respondeu nesta amostra.'
    } elseif ($cpuStreak -ge 3) {
        "Uso acima de 85% por $cpuStreak ciclos consecutivos."
    } elseif ($cpuPercent -ge 85) {
        'Pico acima de 85%; ainda não é uma saturação sustentada.'
    } else {
        'Uso total do processador.'
    }
    $cpu = New-PressureResourceAssessment `
        -Key 'cpu' `
        -Label 'CPU' `
        -Level $cpuLevel `
        -Score $(if ($cpuAvailable) { $cpuPercent } else { 0.0 }) `
        -Value $(if ($cpuAvailable) { [math]::Round($cpuPercent, 1) } else { $null }) `
        -Unit '%' `
        -Detail $(if ($cpuAvailable) {
            "$([math]::Round($cpuPercent, 1))% da capacidade total"
        } else {
            'leitura indisponível nesta amostra'
        }) `
        -Basis $cpuBasis `
        -Available $cpuAvailable

    $memoryAvailable = Test-PressureMetricAvailable -Metrics $Metrics -Property 'MemoryAvailable'
    $availableMB = [double]$Metrics.AvailableMB
    $availableGB = $availableMB / 1024
    $availablePercent = [double]$Metrics.AvailablePercent
    $commitPercent = [double]$Metrics.CommitPercent
    $memoryUsedPercent = [math]::Min(100, [math]::Max(0, 100 - $availablePercent))
    $memoryLevel = if (-not $memoryAvailable) {
        0
    } elseif ($availableMB -lt 750 -or $commitPercent -ge 97) {
        4
    } elseif ($availableMB -lt 1536 -or $commitPercent -ge 92) {
        3
    } elseif ($availableMB -lt 4096 -or $commitPercent -ge 80) {
        2
    } elseif ($availablePercent -lt 15 -or $commitPercent -ge 65) {
        1
    } else {
        0
    }
    $memoryScore = if (-not $memoryAvailable) {
        0.0
    } else {
        [math]::Max(
            $commitPercent,
            [math]::Min(100, 100 - (100 * $availableGB / 8))
        )
    }
    $memory = New-PressureResourceAssessment `
        -Key 'memory' `
        -Label 'Memória' `
        -Level $memoryLevel `
        -Score $memoryScore `
        -Value $(if ($memoryAvailable) { [math]::Round($memoryUsedPercent, 1) } else { $null }) `
        -Unit '%' `
        -Detail $(if ($memoryAvailable) {
            "$([math]::Round($availableGB, 2)) GB disponíveis • commit $([math]::Round($commitPercent, 1))%"
        } else {
            'leitura indisponível nesta amostra'
        }) `
        -Basis $(if ($memoryAvailable) {
            'Disponível mede RAM reutilizável; commit mede a reserva total garantida por RAM ou page file.'
        } else {
            'O contador de memória não respondeu nesta amostra.'
        }) `
        -Available $memoryAvailable

    $diskPercent = [double]$Metrics.DiskPercent
    $diskLatencyMs = if ($null -eq $Metrics.DiskLatencyMs) {
        $null
    } else {
        [double]$Metrics.DiskLatencyMs
    }
    $lowestFreeGB = if ($null -eq $Metrics.LowestFreeGB) {
        $null
    } else {
        [double]$Metrics.LowestFreeGB
    }
    # Disco mistura duas fontes: espaço livre vem da capacidade dos volumes e
    # atividade vem dos contadores. Perder os contadores não pode calar o
    # alarme de espaço, que é o que impede uma limpeza de começar.
    $diskActivityAvailable = Test-PressureMetricAvailable `
        -Metrics $Metrics `
        -Property 'DiskActivityAvailable'
    $diskCapacityKnown = $null -ne $lowestFreeGB
    $diskAvailable = $diskActivityAvailable -or $diskCapacityKnown

    $diskLevel = 0
    $diskBasis = if ($diskActivityAvailable) {
        'Tempo ativo, fila, latência e espaço livre dos volumes locais.'
    } elseif ($diskCapacityKnown) {
        'Os contadores de disco não responderam; espaço livre segue medido.'
    } else {
        'Nem os contadores de disco nem a capacidade dos volumes responderam.'
    }
    if ($null -ne $lowestFreeGB -and $lowestFreeGB -lt 0.5) {
        $diskLevel = 4
        $diskBasis = 'Há um volume local com menos de 500 MB livres.'
    } elseif ($null -ne $lowestFreeGB -and $lowestFreeGB -lt 2) {
        $diskLevel = 3
        $diskBasis = 'Há um volume local com menos de 2 GB livres.'
    } elseif ($null -ne $lowestFreeGB -and $lowestFreeGB -lt 5) {
        $diskLevel = 2
        $diskBasis = 'Há um volume local com menos de 5 GB livres.'
    } elseif (-not $diskActivityAvailable) {
        $diskLevel = 0
    } elseif ($null -ne $diskLatencyMs -and $diskLatencyMs -ge 50 -and $diskStreak -ge 3) {
        $diskLevel = 3
        $diskBasis = "Latência acima de 50 ms por $diskStreak ciclos; confirme por uma janela de pelo menos um minuto."
    } elseif (
        ($null -ne $diskLatencyMs -and $diskLatencyMs -ge 25) -or
        $diskPercent -ge 90
    ) {
        $diskLevel = 2
        $diskBasis = 'Pico de latência ou tempo ativo elevado; correlação ainda não prova a origem física.'
    } elseif (
        ($null -ne $diskLatencyMs -and $diskLatencyMs -ge 15) -or
        $diskPercent -ge 70
    ) {
        $diskLevel = 1
    }
    $diskLatencyScore = if ($null -eq $diskLatencyMs) {
        0
    } else {
        [math]::Min(100, 2 * $diskLatencyMs)
    }
    $diskCapacityScore = if ($null -eq $lowestFreeGB) {
        0
    } elseif ($lowestFreeGB -lt 0.5) {
        100
    } elseif ($lowestFreeGB -lt 2) {
        95
    } elseif ($lowestFreeGB -lt 5) {
        80
    } else {
        0
    }
    $diskScore = if ($diskActivityAvailable) {
        [math]::Max(
            [math]::Min(100, $diskPercent),
            [math]::Max($diskLatencyScore, $diskCapacityScore)
        )
    } else {
        [double]$diskCapacityScore
    }
    $latencyDetail = if ($null -eq $diskLatencyMs) {
        'latência aquecendo'
    } else {
        "$([math]::Round($diskLatencyMs, 1)) ms"
    }
    $disk = New-PressureResourceAssessment `
        -Key 'disk' `
        -Label 'Disco' `
        -Level $diskLevel `
        -Score $diskScore `
        -Value $(if ($diskActivityAvailable) {
            [math]::Round([math]::Min(100, $diskPercent), 1)
        } else {
            $null
        }) `
        -Unit '%' `
        -Detail $(if ($diskActivityAvailable) {
            "$latencyDetail • fila $([math]::Round([double]$Metrics.DiskQueue, 2))"
        } elseif ($diskCapacityKnown) {
            "atividade indisponível • $([math]::Round($lowestFreeGB, 1)) GB livres no volume mais apertado"
        } else {
            'leitura indisponível nesta amostra'
        }) `
        -Basis $diskBasis `
        -Available $diskAvailable

    $gpuPercent = [double]$Metrics.GpuPercent
    $gpuLevel = if (-not $GpuAvailable) {
        0
    } elseif ($gpuPercent -ge 85 -and $gpuStreak -ge 3) {
        3
    } elseif ($gpuPercent -ge 85) {
        2
    } elseif ($gpuPercent -ge 60) {
        1
    } else {
        0
    }
    $gpuBasis = if (-not $GpuAvailable) {
        'Contadores WDDM 2.x não disponíveis.'
    } elseif ($gpuStreak -ge 3) {
        "Motor mais ocupado acima de 85% por $gpuStreak ciclos."
    } else {
        'Usa o motor WDDM mais ocupado, a mesma agregação adotada pelo Gerenciador de Tarefas.'
    }
    $gpu = New-PressureResourceAssessment `
        -Key 'gpu' `
        -Label 'GPU' `
        -Level $gpuLevel `
        -Score $gpuPercent `
        -Value $(if ($GpuAvailable) { [math]::Round($gpuPercent, 1) } else { $null }) `
        -Unit '%' `
        -Detail $(if ($GpuAvailable) {
            if ([string]::IsNullOrWhiteSpace([string]$Metrics.GpuEngine)) {
                'nenhum motor ativo'
            } else {
                "motor $($Metrics.GpuEngine)"
            }
        } else {
            'indisponível neste driver'
        }) `
        -Basis $gpuBasis `
        -Available $GpuAvailable

    $networkAvailable = Test-PressureMetricAvailable `
        -Metrics $Metrics `
        -Property 'NetworkAvailable'
    $networkPercent = [double]$Metrics.NetworkPercent
    $networkLevel = if (-not $networkAvailable) {
        0
    } elseif ($networkPercent -ge 80 -and $networkStreak -ge 3) {
        3
    } elseif ($networkPercent -ge 80) {
        2
    } elseif ($networkPercent -ge 50) {
        1
    } else {
        0
    }
    $networkBasis = if (-not $networkAvailable) {
        'Nenhuma interface respondeu nesta amostra.'
    } elseif ($networkStreak -ge 3) {
        "Interface mais ocupada acima de 80% por $networkStreak ciclos."
    } else {
        'Uso comparado à velocidade nominal informada pelo adaptador.'
    }
    $network = New-PressureResourceAssessment `
        -Key 'network' `
        -Label 'Rede' `
        -Level $networkLevel `
        -Score $(if ($networkAvailable) { $networkPercent } else { 0.0 }) `
        -Value $(if ($networkAvailable) { [math]::Round($networkPercent, 1) } else { $null }) `
        -Unit '%' `
        -Detail $(if ($networkAvailable) {
            "$([math]::Round([double]$Metrics.NetworkMBps, 2)) MB/s agregados"
        } else {
            'leitura indisponível nesta amostra'
        }) `
        -Basis $networkBasis `
        -Available $networkAvailable

    $resources = @($cpu, $memory, $disk, $gpu, $network)
    $measured = @(
        $resources |
            Where-Object Available |
            Sort-Object `
                @{ Expression = 'Level'; Descending = $true },
                @{ Expression = 'Score'; Descending = $true }
    )
    # Com CPU e memória podendo faltar, a lista de medidos pode ficar vazia.
    $dominant = if ($measured.Count -gt 0) { $measured[0] } else { $null }
    $overallLevel = if ($null -eq $dominant) { 0 } else { [int]$dominant.Level }
    $overallSummary = if ($null -eq $dominant) {
        'Nenhum recurso pôde ser medido nesta amostra; sem leitura o painel não emite veredito.'
    } elseif ($overallLevel -eq 0) {
        'Nenhum gargalo sustentado foi detectado nesta amostra.'
    } else {
        "$($dominant.Label) é a pressão dominante: $($dominant.Basis)"
    }

    [pscustomobject]@{
        Level = $overallLevel
        State = Get-PressureLevelName -Level $overallLevel
        Score = if ($null -eq $dominant) { 0.0 } else { [math]::Round([double]$dominant.Score, 1) }
        DominantResource = if ($null -eq $dominant) { '' } else { $dominant.Key }
        Summary = $overallSummary
        Resources = $resources
    }
}

function Get-PressureInsights {
    param(
        [Parameter(Mandatory)]$Assessment,
        [Parameter(Mandatory)]$Metrics,
        [Parameter(Mandatory)]$Consumers,
        $Defender = $null
    )

    $insights = [Collections.Generic.List[object]]::new()
    $resourceByKey = @{}
    foreach ($resource in $Assessment.Resources) {
        $resourceByKey[$resource.Key] = $resource
    }

    # As regras do Defender vêm primeiro: quando uma varredura está em curso, ela
    # é a explicação, e não mais um processo qualquer no topo de uma lista.
    if ($null -ne $Defender -and $Defender.Available) {
        $diskLevel = if ($resourceByKey.ContainsKey('disk')) {
            [int]$resourceByKey.disk.Level
        } else {
            0
        }
        $antimalwareIo = [double]$Defender.EngineIoMBps
        $diskUnderPressure = (
            $diskLevel -ge 2 -or
            [double]$Metrics.DiskQueue -ge 2
        )

        if ($Defender.ScanInProgress -and $diskUnderPressure) {
            $insights.Add([pscustomobject]@{
                Resource = 'disk'
                Level = [math]::Max(2, $diskLevel)
                Title = 'Varredura completa do Defender em andamento'
                Narrative = "A varredura começou em $($Defender.ScanStartedAt) e o disco está com fila $($Metrics.DiskQueue). O antimalware movimenta $([math]::Round($antimalwareIo, 2)) MB/s de E/S."
                Evidence = 'MSFT_MpComputerStatus indica início de varredura sem término correspondente; E/S por PID do antimalware medida no mesmo ciclo.'
                AttributionConfidence = 'alta'
                CauseConfidence = 'alta'
            })
        } elseif ($diskUnderPressure -and $antimalwareIo -ge 1) {
            $insights.Add([pscustomobject]@{
                Resource = 'disk'
                Level = [math]::Max(1, $diskLevel)
                Title = 'Antimalware é o maior movimentador de E/S sob pressão de disco'
                Narrative = "O antimalware movimenta $([math]::Round($antimalwareIo, 2)) MB/s com fila de disco em $($Metrics.DiskQueue). Fila alta com vazão baixa é assinatura de varredura em tempo real, não de build."
                Evidence = 'E/S por processo inclui arquivo e dispositivo; a correlação com a fila é observacional, não uma prova de causa.'
                AttributionConfidence = 'alta'
                CauseConfidence = 'média'
            })
        }

        if (
            $null -ne $Defender.MinutesUntilNextScan -and
            $Defender.MinutesUntilNextScan -ge 0 -and
            $Defender.MinutesUntilNextScan -le 60
        ) {
            $idleNote = if ($Defender.ScanOnlyIfIdle) {
                'A política atual espera a máquina ficar ociosa.'
            } else {
                'A política atual não espera a máquina ficar ociosa.'
            }
            $insights.Add([pscustomobject]@{
                Resource = 'disk'
                Level = 1
                Title = "Varredura agendada em $([math]::Round($Defender.MinutesUntilNextScan, 0)) min"
                Narrative = "Próxima varredura completa prevista para $($Defender.NextScheduledScan). $idleNote"
                Evidence = 'Agenda lida de MSFT_MpPreference; o horário previsto é calculado, não observado.'
                AttributionConfidence = 'alta'
                CauseConfidence = 'baixa'
            })
        }

        if (@($Defender.ToolchainGaps).Count -gt 0 -and $diskUnderPressure) {
            $gapLabels = (@($Defender.ToolchainGaps | ForEach-Object { $_.Label }) -join ', ')
            $insights.Add([pscustomobject]@{
                Resource = 'disk'
                Level = 1
                Title = 'Caminhos de desenvolvimento fora das exclusões do antimalware'
                Narrative = "Sem exclusão: $gapLabels. Cada arquivo tocado nesses caminhos passa por varredura em tempo real."
                Evidence = 'Comparação entre ExclusionPath/ExclusionProcess e os caminhos típicos do toolchain; a lista é política da organização.'
                AttributionConfidence = 'média'
                CauseConfidence = 'média'
            })
        }

        # Sem pressão de disco no momento a exposição continua valendo: quem
        # precisa saber disso precisa saber antes da varredura, não durante.
        if ([int]$Defender.ExposedCliHomeCount -gt 0) {
            $exposed = @($Defender.CliHomes | Where-Object { -not $_.Covered })
            $total = @($Defender.CliHomes).Count
            $rotulos = (@($exposed | Select-Object -First 6 | ForEach-Object { $_.Label }) -join ', ')
            $scanSoon = (
                $null -ne $Defender.MinutesUntilNextScan -and
                $Defender.MinutesUntilNextScan -ge 0 -and
                $Defender.MinutesUntilNextScan -le 120
            )
            $insights.Add([pscustomobject]@{
                Resource = 'disk'
                Level = if ($diskUnderPressure -or $Defender.ScanInProgress -or $scanSoon) { 2 } else { 1 }
                Title = "$($exposed.Count) de $total perfis de CLI fora das exclusões"
                Narrative = "Perfis expostos: $rotulos. Cada perfil mantém diretório próprio de estado, e a exclusão de um não cobre os outros."
                Evidence = 'Contenção real de caminho contra ExclusionPath, mais exclusão do binário em ExclusionProcess; nomes de pasta não revelam o caminho completo.'
                AttributionConfidence = 'alta'
                CauseConfidence = 'média'
            })
        }
    }

    $cpuTop = @($Consumers.cpu | Select-Object -First 1)
    if ($cpuTop.Count -gt 0 -and ($Metrics.CpuPercent -ge 35 -or $cpuTop[0].CpuPercent -ge 5)) {
        $process = $cpuTop[0]
        $insights.Add([pscustomobject]@{
            Resource = 'cpu'
            Level = [int]$resourceByKey.cpu.Level
            Title = "$($process.Name) lidera a CPU"
            Narrative = "$($process.Name) usa $($process.CpuPercent)% da capacidade total. $($process.Purpose)"
            Evidence = 'Consumo por PID medido; finalidade inferida por processo pai e categoria.'
            AttributionConfidence = 'alta'
            CauseConfidence = 'média'
        })
    }

    $memoryTop = @($Consumers.memory | Select-Object -First 1)
    if ($memoryTop.Count -gt 0 -and (
        $resourceByKey.memory.Level -gt 0 -or
        $memoryTop[0].PrivateMB -ge 512
    )) {
        $process = $memoryTop[0]
        $insights.Add([pscustomobject]@{
            Resource = 'memory'
            Level = [int]$resourceByKey.memory.Level
            Title = "$($process.Name) mantém mais memória privada"
            Narrative = "$($process.Name) tem $($process.PrivateMB) MB privados e $($process.WorkingSetMB) MB residentes. $($process.Purpose)"
            Evidence = 'Private Bytes atribui commit ao PID; Working Set mostra apenas páginas residentes.'
            AttributionConfidence = 'alta'
            CauseConfidence = 'média'
        })
    }

    $ioTop = @($Consumers.io | Select-Object -First 1)
    if ($ioTop.Count -gt 0 -and (
        $resourceByKey.disk.Level -gt 0 -or
        $ioTop[0].IoTotalMBps -ge 1
    )) {
        $process = $ioTop[0]
        $insights.Add([pscustomobject]@{
            Resource = 'disk'
            Level = [int]$resourceByKey.disk.Level
            Title = "$($process.Name) lidera a E/S de processos"
            Narrative = "$($process.Name) movimenta $($process.IoTotalMBps) MB/s de E/S. $($process.Purpose)"
            Evidence = 'O contador por processo inclui arquivo, dispositivo e outras E/S; a relação com o disco é correlação.'
            AttributionConfidence = 'média'
            CauseConfidence = 'baixa'
        })
    }

    $gpuTop = @($Consumers.gpu | Select-Object -First 1)
    if ($gpuTop.Count -gt 0 -and $gpuTop[0].GpuPercent -ge 1) {
        $process = $gpuTop[0]
        $insights.Add([pscustomobject]@{
            Resource = 'gpu'
            Level = [int]$resourceByKey.gpu.Level
            Title = "$($process.Name) lidera o motor $($process.GpuEngine)"
            Narrative = "$($process.Name) usa $($process.GpuPercent)% no motor WDDM mais ocupado e $($process.GpuMemoryMB) MB de memória GPU comprometida."
            Evidence = 'Uso por engine atribuído pelo PID; memória compartilhada pode aparecer em mais de um processo.'
            AttributionConfidence = 'alta'
            CauseConfidence = 'média'
        })
    }

    if ($resourceByKey.network.Level -gt 0 -or [double]$Metrics.NetworkMBps -ge 5) {
        $insights.Add([pscustomobject]@{
            Resource = 'network'
            Level = [int]$resourceByKey.network.Level
            Title = 'A rede está sendo medida no nível da interface'
            Narrative = "O tráfego agregado é $([math]::Round([double]$Metrics.NetworkMBps, 2)) MB/s. Conexões podem ser associadas a PIDs, mas bytes por processo exigem rastreamento ETW."
            Evidence = 'Não atribuímos throughput a um processo sem uma fonte que realmente o meça.'
            AttributionConfidence = 'baixa'
            CauseConfidence = 'baixa'
        })
    }

    if ($insights.Count -eq 0) {
        $insights.Add([pscustomobject]@{
            Resource = 'overall'
            Level = 0
            Title = 'O sistema está sem gargalo sustentado'
            Narrative = 'As métricas atuais permanecem abaixo dos limites de atenção.'
            Evidence = 'Uma amostra saudável não exclui picos anteriores; mantenha o painel aberto para observar tendência.'
            AttributionConfidence = 'alta'
            CauseConfidence = 'alta'
        })
    }

    return @($insights | Select-Object -First 5)
}

function Get-PressureResourceLevel {
    param(
        [Parameter(Mandatory)]$Assessment,
        [Parameter(Mandatory)][string]$Key
    )

    $resource = @(
        $Assessment.Resources |
            Where-Object Key -eq $Key |
            Select-Object -First 1
    )
    if ($resource.Count -eq 0) {
        return 0
    }
    return [int]$resource[0].Level
}

function Get-PressureCliSeverity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][double]$CpuPercent,
        [Parameter(Mandatory)][double]$PrivateMB,
        [Parameter(Mandatory)][double]$IoTotalMBps,
        [Parameter(Mandatory)][double]$GpuPercent,
        [Parameter(Mandatory)][int]$ProcessCount,
        [Parameter(Mandatory)]$Assessment,
        [switch]$TerminalAggregate
    )

    $privateGB = $PrivateMB / 1024
    $memoryLimitGB = if ($TerminalAggregate) { 8.0 } else { 4.0 }
    $processLimit = if ($TerminalAggregate) { 200.0 } else { 100.0 }
    $signalScores = [ordered]@{
        memory = [math]::Min(100, 100 * $privateGB / $memoryLimitGB)
        cpu = [math]::Min(100, $CpuPercent)
        io = [math]::Min(100, $IoTotalMBps)
        gpu = [math]::Min(100, $GpuPercent)
        processes = [math]::Min(100, 100 * $ProcessCount / $processLimit)
    }
    $signalLabels = @{
        memory = 'Memória privada'
        cpu = 'CPU'
        io = 'E/S'
        gpu = 'GPU'
        processes = 'Quantidade de processos'
    }
    $primaryEntry = @(
        $signalScores.GetEnumerator() |
            Sort-Object Value -Descending |
            Select-Object -First 1
    )[0]

    $level = 0
    $reasons = [Collections.Generic.List[string]]::new()
    if ($TerminalAggregate) {
        if ($privateGB -ge 12) {
            $level = [math]::Max($level, 4)
            $reasons.Add('A árvore completa do Windows Terminal passou de 12 GB privados.')
        } elseif ($privateGB -ge 8) {
            $level = [math]::Max($level, 3)
            $reasons.Add('A árvore completa do Windows Terminal passou de 8 GB privados.')
        } elseif ($privateGB -ge 4) {
            $level = [math]::Max($level, 2)
            $reasons.Add('A árvore completa do Windows Terminal passou de 4 GB privados.')
        } elseif ($privateGB -ge 2) {
            $level = [math]::Max($level, 1)
            $reasons.Add('A árvore completa do Windows Terminal passou de 2 GB privados.')
        }
    } else {
        if ($privateGB -ge 4) {
            $level = [math]::Max($level, 3)
            $reasons.Add('Esta sessão e seus filhos passaram de 4 GB privados.')
        } elseif ($privateGB -ge 2) {
            $level = [math]::Max($level, 2)
            $reasons.Add('Esta sessão e seus filhos passaram de 2 GB privados.')
        } elseif ($privateGB -ge 1) {
            $level = [math]::Max($level, 1)
            $reasons.Add('Esta sessão e seus filhos passaram de 1 GB privado.')
        }
    }

    $cpuLevel = Get-PressureResourceLevel -Assessment $Assessment -Key 'cpu'
    if ($CpuPercent -ge 85 -and $cpuLevel -ge 2) {
        $level = [math]::Max($level, 3)
        $reasons.Add('A sessão coincide com CPU total em atenção e usa pelo menos 85% da máquina.')
    } elseif ($CpuPercent -ge 50) {
        $level = [math]::Max($level, 2)
        $reasons.Add('A árvore usa pelo menos metade da capacidade total de CPU.')
    } elseif ($CpuPercent -ge 15) {
        $level = [math]::Max($level, 1)
        $reasons.Add('A árvore usa pelo menos 15% da capacidade total de CPU.')
    }

    $memoryLevel = Get-PressureResourceLevel -Assessment $Assessment -Key 'memory'
    if ($memoryLevel -ge 4 -and $PrivateMB -ge 512) {
        $level = [math]::Max($level, 4)
        $reasons.Add('O host está em emergência de memória e esta árvore mantém commit privado relevante.')
    } elseif ($memoryLevel -ge 3 -and $PrivateMB -ge 1024) {
        $level = [math]::Max($level, 3)
        $reasons.Add('O host está crítico em memória e esta árvore mantém pelo menos 1 GB privado.')
    }

    $diskLevel = Get-PressureResourceLevel -Assessment $Assessment -Key 'disk'
    if ($IoTotalMBps -ge 20 -and $diskLevel -ge 3) {
        $level = [math]::Max($level, 3)
        $reasons.Add('A E/S da árvore coincide com pressão crítica de disco.')
    } elseif ($IoTotalMBps -ge 50) {
        $level = [math]::Max($level, 2)
        $reasons.Add('A árvore movimenta pelo menos 50 MB/s de E/S de processos.')
    } elseif ($IoTotalMBps -ge 5) {
        $level = [math]::Max($level, 1)
        $reasons.Add('A árvore movimenta pelo menos 5 MB/s de E/S de processos.')
    }

    $gpuLevel = Get-PressureResourceLevel -Assessment $Assessment -Key 'gpu'
    if ($GpuPercent -ge 85 -and $gpuLevel -ge 2) {
        $level = [math]::Max($level, 3)
        $reasons.Add('A árvore coincide com pressão de GPU e contém um PID acima de 85%.')
    } elseif ($GpuPercent -ge 60) {
        $level = [math]::Max($level, 2)
        $reasons.Add('Um processo da árvore usa pelo menos 60% de um motor de GPU.')
    } elseif ($GpuPercent -ge 20) {
        $level = [math]::Max($level, 1)
        $reasons.Add('Um processo da árvore usa pelo menos 20% de um motor de GPU.')
    }

    if (-not $TerminalAggregate) {
        if ($ProcessCount -ge 120) {
            $level = [math]::Max($level, 3)
            $reasons.Add('A sessão mantém pelo menos 120 processos descendentes.')
        } elseif ($ProcessCount -ge 75) {
            $level = [math]::Max($level, 2)
            $reasons.Add('A sessão mantém pelo menos 75 processos descendentes.')
        } elseif ($ProcessCount -ge 30) {
            $level = [math]::Max($level, 1)
            $reasons.Add('A sessão mantém pelo menos 30 processos descendentes.')
        }
    }

    $primaryKey = [string]$primaryEntry.Key
    $primaryEvidence = switch ($primaryKey) {
        'memory' { "$([math]::Round($privateGB, 2)) GB privados em $ProcessCount processos" }
        'cpu' { "$([math]::Round($CpuPercent, 1))% da CPU total" }
        'io' { "$([math]::Round($IoTotalMBps, 2)) MB/s de E/S de processos" }
        'gpu' { "$([math]::Round($GpuPercent, 1))% no PID com maior uso de GPU" }
        default { "$ProcessCount processos na árvore" }
    }
    $summary = if ($level -eq 0) {
        "Sem sinal relevante agora; $primaryEvidence."
    } else {
        "$($signalLabels[$primaryKey]) é o maior sinal: $primaryEvidence."
    }

    [pscustomobject]@{
        Level = $level
        State = Get-PressureLevelName -Level $level
        Score = [math]::Round([double]$primaryEntry.Value, 1)
        CriticalNow = $level -ge 3
        PrimarySignal = $primaryKey
        PrimaryLabel = [string]$signalLabels[$primaryKey]
        Summary = $summary
        Reasons = @($reasons)
    }
}

function Get-PressureProcessImpactScore {
    param([Parameter(Mandatory)]$Process)

    return [math]::Max(
        [double]$Process.GpuPercent,
        [math]::Max(
            10 * [double]$Process.CpuPercent,
            [math]::Max(
                [double]$Process.PrivateMB / 8,
                10 * [double]$Process.IoTotalMBps
            )
        )
    )
}

function New-PressureCliSession {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][object[]]$Members,
        [Parameter(Mandatory)][object[]]$IdentityMembers,
        [Parameter(Mandatory)][hashtable]$MetadataByPid,
        [uint32[]]$ProtectedProcessIds = @(),
        [Parameter(Mandatory)][bool]$HostedByTerminal,
        [Parameter(Mandatory)]$Assessment,
        [Parameter(Mandatory)]$Metrics,
        [Parameter(Mandatory)][double]$TotalPhysicalMemoryBytes,
        [Parameter(Mandatory)][double]$TotalObservedIoMBps
    )

    $first = $Members[0]
    $rootId = if ($HostedByTerminal) {
        [uint32]$first.TerminalSessionRootId
    } else {
        [uint32]$first.RootCliId
    }
    $root = @($Members | Where-Object Id -eq $rootId | Select-Object -First 1)
    if ($root.Count -eq 0) {
        $root = @($first)
    }

    $cliRoots = @(
        $Members |
            Where-Object {
                [uint32]$_.RootCliId -gt 0 -and
                [uint32]$_.Id -eq [uint32]$_.RootCliId
            } |
            Sort-Object PrivateMB -Descending
    )
    $cliNames = @(
        $Members |
            ForEach-Object RootCliName |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            Sort-Object -Unique
    )
    $primaryCli = if ($cliRoots.Count -gt 0) {
        $cliRoots[0]
    } else {
        $null
    }
    $displayName = if ($cliNames.Count -gt 0) {
        $cliNames -join ' + '
    } else {
        $rootBase = [IO.Path]::GetFileNameWithoutExtension([string]$root[0].Name)
        "$rootBase (sem CLI reconhecida)"
    }

    $cpuPercent = [math]::Min(
        100,
        [double](($Members | Measure-Object CpuPercent -Sum).Sum)
    )
    $privateMB = [double](($Members | Measure-Object PrivateMB -Sum).Sum)
    $workingSetMB = [double](($Members | Measure-Object WorkingSetMB -Sum).Sum)
    $ioReadMBps = [double](($Members | Measure-Object IoReadMBps -Sum).Sum)
    $ioWriteMBps = [double](($Members | Measure-Object IoWriteMBps -Sum).Sum)
    $ioTotalMBps = [double](($Members | Measure-Object IoTotalMBps -Sum).Sum)
    $gpuPercent = [double]((
        $Members |
            Measure-Object GpuPercent -Maximum
    ).Maximum)
    $gpuMemoryMB = [double](($Members | Measure-Object GpuMemoryMB -Sum).Sum)
    $connections = [int](($Members | Measure-Object EstablishedConnections -Sum).Sum)
    $severity = Get-PressureCliSeverity `
        -CpuPercent $cpuPercent `
        -PrivateMB $privateMB `
        -IoTotalMBps $ioTotalMBps `
        -GpuPercent $gpuPercent `
        -ProcessCount $Members.Count `
        -Assessment $Assessment

    $topProcesses = @(
        $Members |
            Sort-Object @{
                Expression = { Get-PressureProcessImpactScore -Process $_ }
                Descending = $true
            } |
            Select-Object -First 5 |
            ForEach-Object {
                [pscustomobject]@{
                    Id = [uint32]$_.Id
                    Name = [string]$_.Name
                    ParentId = [uint32]$_.ParentId
                    ParentName = [string]$_.ParentName
                    Workload = [string]$_.Workload
                    CpuPercent = [double]$_.CpuPercent
                    PrivateMB = [double]$_.PrivateMB
                    WorkingSetMB = [double]$_.WorkingSetMB
                    IoTotalMBps = [double]$_.IoTotalMBps
                    GpuPercent = [double]$_.GpuPercent
                    Lineage = @($_.Lineage)
                }
            }
    )
    $startedAt = if ($root[0].StartedAt) {
        [datetime]$root[0].StartedAt
    } else {
        [datetime]::MinValue
    }
    $ageMinutes = if ($startedAt -eq [datetime]::MinValue) {
        $null
    } else {
        [math]::Max(0, [math]::Round(((Get-Date) - $startedAt).TotalMinutes, 0))
    }
    $termination = Get-PressureCliTerminationDisposition `
        -RootId $rootId `
        -HostedByTerminal $HostedByTerminal `
        -IdentityMembers $IdentityMembers `
        -MetadataByPid $MetadataByPid `
        -ProtectedProcessIds $ProtectedProcessIds

    [pscustomobject]@{
        Key = $Key
        HostedByTerminal = $HostedByTerminal
        HostLabel = if ($HostedByTerminal) { 'Windows Terminal' } else { 'Fora do Windows Terminal' }
        TerminalId = if ($HostedByTerminal) { [uint32]$first.TerminalId } else { [uint32]0 }
        TerminalName = if ($HostedByTerminal) { [string]$first.TerminalName } else { '' }
        RootId = $rootId
        RootName = [string]$root[0].Name
        CliName = $displayName
        CliNames = $cliNames
        PrimaryCliId = if ($null -ne $primaryCli) { [uint32]$primaryCli.Id } else { [uint32]0 }
        StartedAt = if ($startedAt -ne [datetime]::MinValue) { $startedAt.ToString('o') } else { $null }
        AgeMinutes = $ageMinutes
        ProcessCount = $IdentityMembers.Count
        CpuPercent = [math]::Round($cpuPercent, 1)
        CpuHostSharePercent = if ([double]$Metrics.CpuPercent -gt 0) {
            [math]::Round(
                [math]::Min(100, 100 * $cpuPercent / [double]$Metrics.CpuPercent),
                1
            )
        } else {
            0.0
        }
        PrivateMB = [math]::Round($privateMB, 1)
        PrivateGB = [math]::Round($privateMB / 1024, 2)
        PrivateToPhysicalPercent = if ($TotalPhysicalMemoryBytes -gt 0) {
            [math]::Round(100 * $privateMB * 1MB / $TotalPhysicalMemoryBytes, 1)
        } else {
            0.0
        }
        WorkingSetMB = [math]::Round($workingSetMB, 1)
        WorkingSetGB = [math]::Round($workingSetMB / 1024, 2)
        IoReadMBps = [math]::Round($ioReadMBps, 2)
        IoWriteMBps = [math]::Round($ioWriteMBps, 2)
        IoTotalMBps = [math]::Round($ioTotalMBps, 2)
        IoObservedSharePercent = if ($TotalObservedIoMBps -gt 0) {
            [math]::Round(
                [math]::Min(100, 100 * $ioTotalMBps / $TotalObservedIoMBps),
                1
            )
        } else {
            0.0
        }
        GpuPercent = [math]::Round($gpuPercent, 1)
        GpuMemoryMB = [math]::Round($gpuMemoryMB, 1)
        EstablishedConnections = $connections
        Level = [int]$severity.Level
        State = [string]$severity.State
        Score = [double]$severity.Score
        CriticalNow = [bool]$severity.CriticalNow
        PrimarySignal = [string]$severity.PrimarySignal
        Summary = [string]$severity.Summary
        Reasons = @($severity.Reasons)
        AttributionConfidence = if ($HostedByTerminal) { 'alta' } else { 'média' }
        CauseConfidence = 'média'
        TopProcesses = $topProcesses
        Termination = $termination
    }
}

function Get-PressureCliSessions {
    param(
        [Parameter(Mandatory)][object[]]$Processes,
        [Parameter(Mandatory)][hashtable]$MetadataByPid,
        [Parameter(Mandatory)][uint32]$DashboardProcessId,
        [Parameter(Mandatory)]$Assessment,
        [Parameter(Mandatory)]$Metrics,
        [Parameter(Mandatory)][double]$TotalPhysicalMemoryBytes
    )

    $sessions = [Collections.Generic.List[object]]::new()
    $totalObservedIoMBps = [double]((
        $Processes |
            Measure-Object IoTotalMBps -Sum
    ).Sum)
    $protectedProcessIds = @(
        Get-PressureProcessLineageIds `
            -ProcessId $DashboardProcessId `
            -MetadataByPid $MetadataByPid
    )

    $terminalMembers = @(
        $Processes |
            Where-Object TerminalSessionRootId -gt 0
    )
    foreach (
        $group in $terminalMembers |
            Group-Object { "terminal:$($_.TerminalId):$($_.TerminalSessionRootId)" }
    ) {
        $sessionRootId = [uint32]$group.Group[0].TerminalSessionRootId
        $identityMembers = @(
            Get-PressureProcessTreeMembers `
                -RootId $sessionRootId `
                -MetadataByPid $MetadataByPid
        )
        $sessions.Add(
            (New-PressureCliSession `
                -Key ([string]$group.Name) `
                -Members @($group.Group) `
                -IdentityMembers $identityMembers `
                -MetadataByPid $MetadataByPid `
                -ProtectedProcessIds $protectedProcessIds `
                -HostedByTerminal $true `
                -Assessment $Assessment `
                -Metrics $Metrics `
                -TotalPhysicalMemoryBytes $TotalPhysicalMemoryBytes `
                -TotalObservedIoMBps $totalObservedIoMBps)
        )
    }

    $detachedMembers = @(
        $Processes |
            Where-Object {
                -not $_.TerminalHosted -and
                [uint32]$_.RootCliId -gt 0
            }
    )
    foreach (
        $group in $detachedMembers |
            Group-Object { "detached:$($_.RootCliId)" }
    ) {
        $cliRootId = [uint32]$group.Group[0].RootCliId
        $identityMembers = @(
            Get-PressureProcessTreeMembers `
                -RootId $cliRootId `
                -MetadataByPid $MetadataByPid
        )
        $sessions.Add(
            (New-PressureCliSession `
                -Key ([string]$group.Name) `
                -Members @($group.Group) `
                -IdentityMembers $identityMembers `
                -MetadataByPid $MetadataByPid `
                -ProtectedProcessIds $protectedProcessIds `
                -HostedByTerminal $false `
                -Assessment $Assessment `
                -Metrics $Metrics `
                -TotalPhysicalMemoryBytes $TotalPhysicalMemoryBytes `
                -TotalObservedIoMBps $totalObservedIoMBps)
        )
    }

    return @(
        $sessions |
            Sort-Object `
                @{ Expression = 'Level'; Descending = $true },
                @{ Expression = 'PrivateMB'; Descending = $true },
                @{ Expression = 'CpuPercent'; Descending = $true } |
            Select-Object -First 24
    )
}

function Get-PressureTerminalSummary {
    param(
        [Parameter(Mandatory)][object[]]$Processes,
        [Parameter(Mandatory)][object[]]$CliSessions,
        [Parameter(Mandatory)]$Assessment
    )

    $family = @(
        $Processes |
            Where-Object {
                [uint32]$_.TerminalId -gt 0 -or
                (
                    (Get-PressureBaseProcessName -Name ([string]$_.Name)) -eq
                    'windowsterminal'
                )
            }
    )
    $terminalSessions = @($CliSessions | Where-Object HostedByTerminal)
    if ($family.Count -eq 0) {
        return [pscustomobject]@{
            Detected = $false
            TerminalCount = 0
            TerminalPids = @()
            SessionCount = 0
            RecognizedCliSessionCount = 0
            CriticalSessionCount = 0
            AttentionSessionCount = 0
            ProcessCount = 0
            CpuPercent = 0.0
            PrivateMB = 0.0
            PrivateGB = 0.0
            WorkingSetMB = 0.0
            WorkingSetGB = 0.0
            AttachedTreesPrivateMB = 0.0
            HostPrivateMB = 0.0
            IoTotalMBps = 0.0
            GpuPercent = 0.0
            Level = 0
            State = Get-PressureLevelName -Level 0
            CriticalNow = $false
            Summary = 'Windows Terminal não foi detectado nesta amostra.'
            Reasons = @()
        }
    }

    $hostProcesses = @($family | Where-Object IsTerminalHost)
    $terminalPids = @(
        $family |
            ForEach-Object TerminalId |
            Where-Object { [uint32]$_ -gt 0 } |
            Sort-Object -Unique
    )
    $cpuPercent = [math]::Min(
        100,
        [double](($family | Measure-Object CpuPercent -Sum).Sum)
    )
    $privateMB = [double](($family | Measure-Object PrivateMB -Sum).Sum)
    $workingSetMB = [double](($family | Measure-Object WorkingSetMB -Sum).Sum)
    $hostPrivateMB = [double](($hostProcesses | Measure-Object PrivateMB -Sum).Sum)
    $ioTotalMBps = [double](($family | Measure-Object IoTotalMBps -Sum).Sum)
    $gpuPercent = [double](($family | Measure-Object GpuPercent -Maximum).Maximum)
    $severity = Get-PressureCliSeverity `
        -CpuPercent $cpuPercent `
        -PrivateMB $privateMB `
        -IoTotalMBps $ioTotalMBps `
        -GpuPercent $gpuPercent `
        -ProcessCount $family.Count `
        -Assessment $Assessment `
        -TerminalAggregate

    [pscustomobject]@{
        Detected = $true
        TerminalCount = $terminalPids.Count
        TerminalPids = $terminalPids
        SessionCount = $terminalSessions.Count
        RecognizedCliSessionCount = @(
            $terminalSessions |
                Where-Object { @($_.CliNames).Count -gt 0 }
        ).Count
        CriticalSessionCount = @($terminalSessions | Where-Object CriticalNow).Count
        AttentionSessionCount = @(
            $terminalSessions |
                Where-Object { [int]$_.Level -eq 2 }
        ).Count
        ProcessCount = $family.Count
        CpuPercent = [math]::Round($cpuPercent, 1)
        PrivateMB = [math]::Round($privateMB, 1)
        PrivateGB = [math]::Round($privateMB / 1024, 2)
        WorkingSetMB = [math]::Round($workingSetMB, 1)
        WorkingSetGB = [math]::Round($workingSetMB / 1024, 2)
        AttachedTreesPrivateMB = [math]::Round(
            [math]::Max(0, $privateMB - $hostPrivateMB),
            1
        )
        HostPrivateMB = [math]::Round($hostPrivateMB, 1)
        IoTotalMBps = [math]::Round($ioTotalMBps, 2)
        GpuPercent = [math]::Round($gpuPercent, 1)
        Level = [int]$severity.Level
        State = [string]$severity.State
        Score = [double]$severity.Score
        CriticalNow = [bool]$severity.CriticalNow
        PrimarySignal = [string]$severity.PrimarySignal
        Summary = "Windows Terminal e árvores anexadas: $($severity.Summary)"
        Reasons = @($severity.Reasons)
        WorkingSetAggregationNote = 'Working Set é somado apenas como referência e pode repetir páginas compartilhadas.'
        AttributionConfidence = 'alta'
    }
}

function Get-PressureCapabilities {
    param([Parameter(Mandatory)]$State)

    @(
        [pscustomobject]@{
            Key = 'gpu'
            Label = 'GPU por processo'
            Available = [bool]$State.Capabilities.GpuEngine
            Detail = if ($State.Capabilities.GpuEngine) {
                'Contadores WDDM disponíveis; usa o motor mais ocupado por PID.'
            } else {
                'Requer driver com WDDM 2.x.'
            }
        }
        [pscustomobject]@{
            Key = 'sensors'
            Label = 'Temperatura e potência'
            Available = $false
            Detail = 'Sem API universal; futuro adaptador opcional poderá usar fontes do fabricante ou LibreHardwareMonitor.'
        }
        [pscustomobject]@{
            Key = 'network-process'
            Label = 'Rede por processo'
            Available = [bool]$State.Capabilities.TcpConnections
            Detail = if ($State.Capabilities.TcpConnections) {
                'Associa conexões estabelecidas a PIDs; não inventa bytes por processo.'
            } else {
                'Somente métricas agregadas de interface estão disponíveis.'
            }
        }
        [pscustomobject]@{
            Key = 'defender'
            Label = 'Estado e agenda do antimalware'
            Available = [bool]$State.Capabilities.Defender
            Detail = if ($State.Capabilities.Defender) {
                'Leitura de estado, agenda e exclusões; o painel nunca altera política de antimalware.'
            } else {
                'O namespace do antimalware não respondeu; a correlação com varredura fica indisponível.'
            }
        }
        [pscustomobject]@{
            Key = 'docker'
            Label = 'Containers e VM do WSL2'
            Available = [bool]$State.Capabilities.Docker
            Detail = if ($State.Capabilities.Docker) {
                'Sonda o motor com prazo curto; afogamento é estado próprio, nunca zero containers.'
            } else {
                'Docker desligado, sem CLI ou sem resposta; a VM do WSL2 ainda é observada pelo host.'
            }
        }
        [pscustomobject]@{
            Key = 'root-cause'
            Label = 'Causa raiz por pilha'
            Available = $false
            Detail = 'WPR/WPA, ETW ou ProcMon são investigações avançadas e nunca são iniciadas automaticamente.'
        }
    )
}

function Get-PressureAdaptiveRefreshSeconds {
    <#
    .SYNOPSIS
    Calcula a próxima cadência de coleta a partir do nível de pressão.

    .DESCRIPTION
    Sobe em degraus e desce de uma vez. Alargar o intervalo aos poucos com a
    máquina saudável corta o custo da própria medição; voltar ao mínimo ao
    primeiro sinal evita perder o início de um episódio, que é justamente a
    parte que interessa.

    Níveis: 0 é SAUDÁVEL. Qualquer coisa a partir de OBSERVAR volta ao mínimo.
    #>
    [CmdletBinding()]
    param(
        [ValidateRange(0, 4)][int]$Level = 0,
        [ValidateRange(1, 3600)][int]$Current = 5,
        [ValidateRange(1, 3600)][int]$Min = 5,
        [ValidateRange(1, 3600)][int]$Max = 30
    )

    $floor = [math]::Min($Min, $Max)
    $ceiling = [math]::Max($Min, $Max)

    if ($Level -ge 1) {
        return $floor
    }

    $stepped = $Current + $floor
    return [math]::Min($ceiling, [math]::Max($floor, $stepped))
}

function Get-PressureSelfCost {
    <#
    .SYNOPSIS
    Mede o custo do próprio painel a partir de dados já coletados.

    .DESCRIPTION
    A tabela de processos do snapshot já contém o processo do painel e os
    provedores WMI, então esta medição não dispara nenhuma consulta adicional.

    O custo do provedor WMI é reportado separadamente e nunca somado ao custo
    próprio: `WmiPrvSE` atende todos os clientes do computador, e atribuir o
    total ao painel seria um palpite.
    #>
    [CmdletBinding()]
    param(
        [object[]]$ProcessRows = @(),

        [uint32]$DashboardProcessId = 0,

        [double]$LastCollectionMs = 0,

        [int]$CollectionCount = 0,

        [double]$CollectionMsTotal = 0,

        [double]$CollectionMsMax = 0,

        [int]$LogicalProcessorCount = 1,

        [int]$RefreshSeconds = 5
    )

    $cores = [math]::Max(1, $LogicalProcessorCount)
    $selfCpuPercent = 0.0
    $selfPrivateMB = 0.0
    $providerCpuPercent = 0.0
    $providerCount = 0

    foreach ($row in $ProcessRows) {
        $rowCpuPercent = [math]::Min(
            100,
            [double]$row.PercentProcessorTime / $cores
        )

        if (
            $DashboardProcessId -ne 0 -and
            [uint32]$row.IDProcess -eq $DashboardProcessId
        ) {
            $selfCpuPercent = $rowCpuPercent
            $selfPrivateMB = [double]$row.PrivateBytes / 1MB
            continue
        }

        # O provedor aparece como WmiPrvSE, WmiPrvSE#1, WmiPrvSE#2 e assim por diante.
        if (([string]$row.Name) -match '(?i)^wmiprvse(#\d+)?$') {
            $providerCpuPercent += $rowCpuPercent
            $providerCount++
        }
    }

    $averageCollectionMs = if ($CollectionCount -gt 0) {
        $CollectionMsTotal / $CollectionCount
    } else {
        0.0
    }
    $dutyPercent = if ($RefreshSeconds -gt 0) {
        [math]::Min(100, 100 * $LastCollectionMs / ($RefreshSeconds * 1000))
    } else {
        0.0
    }

    [pscustomobject]@{
        SelfCpuPercent = [math]::Round($selfCpuPercent, 1)
        SelfPrivateMB = [math]::Round($selfPrivateMB, 1)
        LastCollectionMs = [math]::Round($LastCollectionMs, 0)
        AverageCollectionMs = [math]::Round($averageCollectionMs, 0)
        MaxCollectionMs = [math]::Round($CollectionMsMax, 0)
        CollectionCount = $CollectionCount
        DutyPercent = [math]::Round($dutyPercent, 1)
        WmiProviderCpuPercent = [math]::Round($providerCpuPercent, 1)
        WmiProviderCount = $providerCount
        WmiProviderAttributable = $false
        Note = 'CPU própria é atribuível ao painel. O provedor WMI atende todos os clientes do computador e aparece apenas como contexto.'
    }
}

$script:PressureDefenderScheduleDayNames = @(
    'todos os dias',
    'domingo',
    'segunda-feira',
    'terça-feira',
    'quarta-feira',
    'quinta-feira',
    'sexta-feira',
    'sábado',
    'nunca'
)

$script:PressureToolchainExclusionMarkers = @(
    [pscustomobject]@{
        Key = 'node-runtime'
        Label = 'runtime Node'
        PathPatterns = @('nodejs', 'nvm')
        ProcessPatterns = @('node.exe')
    }
    [pscustomobject]@{
        Key = 'npm-global'
        Label = 'binários globais npm'
        PathPatterns = @('\npm', '/npm')
        ProcessPatterns = @()
    }
    [pscustomobject]@{
        # `npm` e `npx` são JavaScript executado dentro do node, então uma
        # exclusão de processo para node.exe já cobre a leitura e a escrita
        # nesta pasta: ExclusionProcess vale para os arquivos abertos pelo
        # processo, não apenas para o executável.
        Key = 'npm-cache'
        Label = 'cache npm'
        PathPatterns = @('npm-cache', '_npx')
        ProcessPatterns = @('node.exe')
    }
)

# O estado das CLIs não entra na tabela acima de propósito. Um computador pode
# ter vários perfis isolados da mesma CLI, e casamento por substring diria que
# `.claude` cobre `.claude-pessoal`. A cobertura desses diretórios é avaliada
# um por um em Get-PressureCliHomeCoverage.
$script:PressureCliHomeProcessByPrefix = [ordered]@{
    '.claude' = 'claude.exe'
    '.codex' = 'codex.exe'
    '.gemini' = 'gemini.exe'
    '.grok' = 'grok.exe'
}

function ConvertTo-PressureExclusionRegex {
    <#
    .SYNOPSIS
    Traduz um padrão de exclusão do antimalware para expressão regular.

    .DESCRIPTION
    Casamento por substring é enganoso aqui: `.claude` apareceria como
    cobertura para `.claude-pessoal`, que na prática continua sendo varrido.
    Esta função monta contenção real de caminho.

    O curinga `*` cobre um único segmento, nunca atravessa barra. Um padrão
    terminado em `\*` ou `*` no fim do nome vira prefixo do segmento.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Pattern)

    $expanded = [Environment]::ExpandEnvironmentVariables($Pattern).Trim()
    if ([string]::IsNullOrWhiteSpace($expanded)) {
        return $null
    }
    if ($expanded.Contains('%')) {
        # Variável não expandida — a exclusão não casa com nada no disco.
        return $null
    }

    $normalized = $expanded.TrimEnd('\')
    if ($normalized.EndsWith('\*')) {
        $normalized = $normalized.Substring(0, $normalized.Length - 2)
    }
    $normalized = $normalized.TrimEnd('\')
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return $null
    }

    $escaped = [regex]::Escape($normalized)
    # \* é como o Escape deixa o curinga; cada um vale por um segmento apenas.
    $escaped = $escaped.Replace('\*', '[^\\]*')
    $escaped = $escaped.Replace('\?', '[^\\]')

    return [regex]::new(
        '^' + $escaped + '(\\|$)',
        [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
}

function Test-PressureExclusionCoverage {
    <#
    .SYNOPSIS
    Diz se um diretório está coberto por alguma exclusão de caminho.

    .DESCRIPTION
    Cobertura exige que a exclusão seja o próprio caminho ou um ancestral dele.
    Um caminho mais fundo que a exclusão está coberto; um caminho irmão, não.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [string[]]$ExclusionPath = @()
    )

    $target = if ([string]::IsNullOrWhiteSpace($Path)) {
        ''
    } else {
        $Path.Trim().TrimEnd('\')
    }
    if ([string]::IsNullOrWhiteSpace($target)) {
        return [pscustomobject]@{ Covered = $false; MatchedBy = '' }
    }

    foreach ($pattern in @($ExclusionPath)) {
        $regex = ConvertTo-PressureExclusionRegex -Pattern ([string]$pattern)
        if ($null -eq $regex) {
            continue
        }
        if ($regex.IsMatch($target)) {
            return [pscustomobject]@{ Covered = $true; MatchedBy = [string]$pattern }
        }
    }

    return [pscustomobject]@{ Covered = $false; MatchedBy = '' }
}

function Get-PressureCliHomeRoots {
    <#
    .SYNOPSIS
    Resolve as raízes onde procurar diretórios de estado das CLIs.

    .DESCRIPTION
    Raiz explícita vence. Sem ela, o diretório do usuário é o padrão, somado aos
    diretórios pais declarados no mapa local de perfis.

    Perfil mantido fora do diretório do usuário — dentro de uma pasta de
    repositórios, por exemplo — não aparece na descoberta por convenção, e a
    contagem de exposição sai menor que a realidade sem nenhum aviso.

    O mapa nomeia usuário e sistemas internos, então vive fora do versionamento.
    A ausência dele não é erro: o padrão continua valendo.
    #>
    [CmdletBinding()]
    param(
        [string[]]$ExplicitRoot = @(),

        [AllowEmptyString()]
        [string]$ProfileMapPath = ''
    )

    $explicit = @(
        $ExplicitRoot | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    if ($explicit.Count -gt 0) {
        return @($explicit | ForEach-Object { [IO.Path]::GetFullPath($_) } | Sort-Object -Unique)
    }

    $roots = [Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        $roots.Add([IO.Path]::GetFullPath($env:USERPROFILE))
    }

    $resolvedMapPath = if ([string]::IsNullOrWhiteSpace($ProfileMapPath)) {
        [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\local\perfis-cli.json'))
    } else {
        [IO.Path]::GetFullPath($ProfileMapPath)
    }

    if (Test-Path -LiteralPath $resolvedMapPath -PathType Leaf) {
        try {
            $map = Get-Content -LiteralPath $resolvedMapPath -Raw | ConvertFrom-Json
            $declared = @(
                @($map.profiles | ForEach-Object { $_.home })
                if ($map.PSObject.Properties.Name -contains 'ignore') { @($map.ignore) }
            )
            foreach ($declaredHome in @(
                $declared | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            )) {
                $parent = [IO.Path]::GetDirectoryName(
                    [IO.Path]::GetFullPath([string]$declaredHome)
                )
                if (-not [string]::IsNullOrWhiteSpace($parent)) {
                    $roots.Add($parent)
                }
            }
        } catch {
            # Mapa ilegível não pode derrubar a coleta: o painel volta ao padrão.
            Write-Warning "Mapa de perfis ilegivel, seguindo com a raiz do usuario: $resolvedMapPath"
        }
    }

    return @($roots | Sort-Object -Unique)
}

function Get-PressureCliHomeCandidates {
    <#
    .SYNOPSIS
    Descobre os diretórios de estado das CLIs de IA presentes na máquina.

    .DESCRIPTION
    Um mesmo computador pode ter vários perfis isolados da mesma CLI, cada um
    com seu diretório próprio, escolhido por variável de ambiente. Verificar
    apenas o diretório padrão daria falsa sensação de cobertura.

    A varredura é de um nível só em cada raiz informada, o que a torna barata o
    bastante para rodar na mesma frequência da configuração do antimalware.
    #>
    [CmdletBinding()]
    param(
        [string[]]$Roots = @(),
        [string[]]$EnvironmentHomes = @(),
        [string[]]$Patterns = @('.claude*', '.codex*', '.gemini*', '.grok*')
    )

    $found = [ordered]@{}

    foreach ($root in @($Roots | Where-Object { $_ })) {
        $resolvedRoot = try {
            [IO.Path]::GetFullPath($root)
        } catch {
            continue
        }
        if (-not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) {
            continue
        }

        foreach ($pattern in $Patterns) {
            $matches = try {
                Get-ChildItem -LiteralPath $resolvedRoot -Filter $pattern -Directory -Force -ErrorAction Stop
            } catch {
                @()
            }
            foreach ($entry in $matches) {
                $found[$entry.FullName] = 'convenção'
            }
        }
    }

    # $home é variável automática somente-leitura do PowerShell; usar outro nome.
    foreach ($environmentHome in @($EnvironmentHomes | Where-Object { $_ })) {
        $resolved = try {
            [IO.Path]::GetFullPath($environmentHome)
        } catch {
            continue
        }
        if (Test-Path -LiteralPath $resolved -PathType Container) {
            $found[$resolved] = 'variável de ambiente'
        }
    }

    return @(
        foreach ($path in $found.Keys) {
            [pscustomobject]@{
                Path = [string]$path
                # O rótulo é o nome da pasta: identifica o perfil sem revelar o
                # caminho completo do usuário quando isto for para a interface.
                Label = [IO.Path]::GetFileName([string]$path)
                Source = [string]$found[$path]
            }
        }
    )
}

function Get-PressureCliHomeCoverage {
    <#
    .SYNOPSIS
    Cruza os diretórios de estado das CLIs com as exclusões declaradas.

    .DESCRIPTION
    Não percorre o conteúdo dos diretórios. Contar arquivos aqui somaria E/S
    justamente no caminho que o painel aponta como problema.
    #>
    [CmdletBinding()]
    param(
        [object[]]$Homes = @(),
        [string[]]$ExclusionPath = @(),
        [string[]]$ExclusionProcess = @()
    )

    $processes = @(
        $ExclusionProcess |
            Where-Object { $_ } |
            ForEach-Object { ([string]$_).ToLowerInvariant() }
    )

    return @(
        foreach ($cliHome in $Homes) {
            $coverage = Test-PressureExclusionCoverage `
                -Path ([string]$cliHome.Path) `
                -ExclusionPath $ExclusionPath

            # A exclusão do binário da CLI também cobre o que ela escreve,
            # onde quer que escreva.
            $viaProcess = ''
            if (-not $coverage.Covered) {
                $label = ([string]$cliHome.Label).ToLowerInvariant()
                foreach ($prefix in $script:PressureCliHomeProcessByPrefix.Keys) {
                    if (-not $label.StartsWith($prefix)) {
                        continue
                    }
                    $binary = ([string]$script:PressureCliHomeProcessByPrefix[$prefix]).ToLowerInvariant()
                    if (@($processes | Where-Object { $_.EndsWith($binary) }).Count -gt 0) {
                        $viaProcess = $binary
                    }
                    break
                }
            }

            [pscustomobject]@{
                Label = [string]$cliHome.Label
                Source = [string]$cliHome.Source
                Covered = [bool]($coverage.Covered -or -not [string]::IsNullOrEmpty($viaProcess))
                CoveredBy = if ($coverage.Covered) {
                    'caminho'
                } elseif (-not [string]::IsNullOrEmpty($viaProcess)) {
                    'processo'
                } else {
                    ''
                }
            }
        }
    )
}

function Get-PressureNextScheduledScan {
    <#
    .SYNOPSIS
    Calcula o próximo horário da varredura completa agendada.

    .DESCRIPTION
    Puro de propósito: recebe dia, hora e o instante de referência, para o
    cálculo poder ser testado na virada de semana sem depender do relógio real.

    Convenção de MSFT_MpPreference: 0 é todos os dias, 1 é domingo, 7 é sábado
    e 8 é nunca.
    #>
    [CmdletBinding()]
    param(
        [ValidateRange(0, 8)][int]$ScheduleDay = 0,
        [timespan]$ScheduleTimeOfDay = [timespan]::Zero,
        [datetime]$Now = (Get-Date)
    )

    if ($ScheduleDay -eq 8) {
        return $null
    }

    if ($ScheduleDay -eq 0) {
        $candidate = $Now.Date.Add($ScheduleTimeOfDay)
        if ($candidate -le $Now) {
            $candidate = $candidate.AddDays(1)
        }
        return $candidate
    }

    $targetDayOfWeek = [int]$ScheduleDay - 1
    $daysAhead = (($targetDayOfWeek - [int]$Now.DayOfWeek) + 7) % 7
    $candidate = $Now.Date.AddDays($daysAhead).Add($ScheduleTimeOfDay)
    if ($candidate -le $Now) {
        $candidate = $candidate.AddDays(7)
    }

    return $candidate
}

function Get-PressureToolchainExclusionGaps {
    <#
    .SYNOPSIS
    Aponta quais caminhos típicos de desenvolvimento não estão excluídos.
    #>
    [CmdletBinding()]
    param(
        [string[]]$ExclusionPath = @(),
        [string[]]$ExclusionProcess = @()
    )

    $paths = @($ExclusionPath | Where-Object { $_ } | ForEach-Object { ([string]$_).ToLowerInvariant() })
    $processes = @($ExclusionProcess | Where-Object { $_ } | ForEach-Object { ([string]$_).ToLowerInvariant() })

    $gaps = [Collections.Generic.List[object]]::new()
    foreach ($marker in $script:PressureToolchainExclusionMarkers) {
        $covered = $false

        foreach ($pattern in $marker.PathPatterns) {
            $needle = $pattern.ToLowerInvariant()
            if (@($paths | Where-Object { $_.Contains($needle) }).Count -gt 0) {
                $covered = $true
                break
            }
        }
        if (-not $covered) {
            foreach ($pattern in $marker.ProcessPatterns) {
                $needle = $pattern.ToLowerInvariant()
                if (@($processes | Where-Object { $_.Contains($needle) }).Count -gt 0) {
                    $covered = $true
                    break
                }
            }
        }

        if (-not $covered) {
            $gaps.Add([pscustomobject]@{
                Key = [string]$marker.Key
                Label = [string]$marker.Label
            })
        }
    }

    return @($gaps)
}

function Get-PressureMpLogPath {
    <#
    .SYNOPSIS
    Encontra o log de suporte mais recente do antimalware.

    .DESCRIPTION
    O diretório exige privilégio administrativo para leitura. Sem ele a função
    devolve vazio, e o painel segue sem o ranking em vez de falhar.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$Directory = ''
    )

    $resolved = if ([string]::IsNullOrWhiteSpace($Directory)) {
        Join-Path $env:ProgramData 'Microsoft\Windows Defender\Support'
    } else {
        $Directory
    }

    try {
        $newest = Get-ChildItem -LiteralPath $resolved -Filter 'MPLog-*.log' -ErrorAction Stop |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($null -eq $newest) {
            return ''
        }
        return $newest.FullName
    } catch {
        return ''
    }
}

function ConvertTo-PressureDisplayPath {
    <#
    .SYNOPSIS
    Reduz um caminho a uma forma que não revela a conta do usuário.

    .DESCRIPTION
    O ranking só serve se disser onde dói, mas o painel não expõe caminho
    completo. Trocar o diretório do usuário pela variável preserva a informação
    útil sem publicar o nome da conta.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ''
    }

    $userProfile = [string]$env:USERPROFILE
    if (
        -not [string]::IsNullOrWhiteSpace($userProfile) -and
        $Path.StartsWith($userProfile, [StringComparison]::OrdinalIgnoreCase)
    ) {
        return '%USERPROFILE%' + $Path.Substring($userProfile.Length)
    }
    return $Path
}

function ConvertFrom-PressureMpLog {
    <#
    .SYNOPSIS
    Extrai do log do antimalware o custo de varredura por processo.

    .DESCRIPTION
    O provedor não informa qual arquivo está sendo varrido. O próprio motor,
    porém, registra periodicamente quanto tempo gastou por processo e qual foi o
    arquivo mais caro de cada um. É a medição dele, não uma inferência nossa.

    Os carimbos do log estão em UTC. O log é lido pela cauda: ele é acrescido no
    fim, e reler megabytes a cada ciclo custaria mais que a informação vale.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$LogPath = '',

        # Injetável para teste; vazio lê o arquivo.
        [string[]]$Line = $null,

        [int]$TailLines = 4000,

        [datetime]$Since = [datetime]::MinValue
    )

    $lines = if ($null -ne $Line) {
        @($Line)
    } elseif (-not [string]::IsNullOrWhiteSpace($LogPath)) {
        try {
            @(Get-Content -LiteralPath $LogPath -Tail $TailLines -Encoding Unicode -ErrorAction Stop)
        } catch {
            @()
        }
    } else {
        @()
    }

    $pattern = [regex](
        '^(?<t>\S+)\s+ProcessImageName:\s(?<proc>[^,]+),\sPid:\s(?<pid>\d+),' +
        '\sTotalTime:\s(?<tt>\d+),\sCount:\s(?<cnt>\d+),\sMaxTime:\s\d+,' +
        '\sMaxTimeFile:\s(?<file>.*?),\sEstimatedImpact:\s(?<imp>\d+)%'
    )
    $sinceUtc = if ($Since -eq [datetime]::MinValue) {
        [datetime]::MinValue
    } else {
        $Since.ToUniversalTime()
    }

    return @(
        foreach ($current in $lines) {
            $match = $pattern.Match([string]$current)
            if (-not $match.Success) {
                continue
            }

            $stamp = [datetime]::MinValue
            if (-not [datetime]::TryParse(
                $match.Groups['t'].Value,
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::AssumeUniversal -bor
                    [Globalization.DateTimeStyles]::AdjustToUniversal,
                [ref]$stamp
            )) {
                continue
            }
            if ($stamp -lt $sinceUtc) {
                continue
            }

            # O log nomeia o volume pelo dispositivo, e o sufixo ->(...) descreve
            # o conteúdo interno inspecionado, não outro arquivo.
            $file = $match.Groups['file'].Value -replace '->\(.*$', ''

            [pscustomobject]@{
                At = $stamp.ToLocalTime()
                Process = $match.Groups['proc'].Value
                ProcessId = [int]$match.Groups['pid'].Value
                TotalTimeMs = [int]$match.Groups['tt'].Value
                FileCount = [int]$match.Groups['cnt'].Value
                DevicePath = $file
                ImpactPercent = [int]$match.Groups['imp'].Value
            }
        }
    )
}

function Resolve-PressureDevicePath {
    <#
    .SYNOPSIS
    Traduz `\Device\HarddiskVolumeN\...` para letra de unidade.

    .DESCRIPTION
    A tradução é feita por tentativa: o caminho relativo é testado nas unidades
    fixas e a primeira que o contém vence. Evita interoperação com a API do
    Windows para um ganho que não justifica o risco, e degrada devolvendo o
    caminho original quando nada casa.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [string[]]$DriveRoot = @()
    )

    if ($Path -notmatch '^\\Device\\HarddiskVolume\d+\\(?<rest>.*)$') {
        return $Path
    }

    $rest = $matches['rest']
    $roots = if (@($DriveRoot).Count -gt 0) {
        @($DriveRoot)
    } else {
        @(
            Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType = 3' -ErrorAction SilentlyContinue |
                ForEach-Object { "$($_.DeviceID)\" }
        )
    }

    foreach ($root in $roots) {
        $candidate = Join-Path $root $rest
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    $systemRoot = [IO.Path]::GetPathRoot([string]$env:SystemRoot)
    if (-not [string]::IsNullOrWhiteSpace($systemRoot)) {
        return (Join-Path $systemRoot $rest)
    }
    return $Path
}

function Get-PressureGenericPrefix {
    <#
    .SYNOPSIS
    Monta o prefixo de um padrão trocando o segmento da conta por curinga.

    .DESCRIPTION
    O diretório imediatamente acima do conteúdo identificado costuma ser a conta
    do usuário — em `Users` ou em qualquer raiz de perfis que a organização
    tenha adotado. Trocá-lo por curinga é o que faz o padrão valer para a
    próxima estação e para o próximo colaborador, em vez de descrever uma
    máquina.

    Conteúdo logo abaixo da raiz da unidade não tem segmento de conta para
    generalizar, e o prefixo sai inteiro.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Part,
        [Parameter(Mandatory)][int]$AnchorIndex
    )

    # Um único segmento entre a unidade e o conteúdo é raiz compartilhada — uma
    # pasta de repositórios, por exemplo — e generalizá-la produziria um padrão
    # largo demais. Conta de usuário só aparece a partir do segundo nível.
    if ($AnchorIndex -le 2) {
        return (@($Part[0..([math]::Max(0, $AnchorIndex - 1))]) -join '\')
    }

    $prefixo = @($Part[0..($AnchorIndex - 1)])
    $prefixo[$prefixo.Count - 1] = '*'
    return ($prefixo -join '\')
}

function ConvertTo-PressureExclusionSuggestion {
    <#
    .SYNOPSIS
    Generaliza um caminho observado em padrão de exclusão e categoria.

    .DESCRIPTION
    Pedir exclusão de caminho literal produz uma decisão por máquina, que não
    sobrevive a outro usuário, a outra estação nem a um perfil criado depois.
    Política de antimalware é definida por padrão, então a recomendação sai por
    padrão: o segmento da conta vira curinga e o nome específico do perfil vira
    prefixo.

    A categoria acompanha o padrão porque quem avalia risco decide por classe de
    conteúdo — estado de ferramenta, cache restaurável, artefato de build — e não
    por pasta isolada.

    Caminho fora das famílias conhecidas volta sem sugestão: inventar um padrão
    largo para conteúdo desconhecido seria pior que não sugerir nada.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)

    $vazio = [pscustomobject]@{ Pattern = ''; Category = ''; Rationale = '' }
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $vazio
    }

    $parts = @($Path -split '\\' | Where-Object { $_ -ne '' })
    if ($parts.Count -lt 2) {
        return $vazio
    }
    $drive = $parts[0]

    # Diretório de estado de CLI de IA, sob a conta do usuário ou fora dela.
    $cliIndex = -1
    for ($i = 1; $i -lt $parts.Count; $i++) {
        if ($parts[$i] -match '^\.(claude|codex|gemini|grok)') {
            $cliIndex = $i
            break
        }
    }
    if ($cliIndex -ge 0) {
        $family = ($parts[$cliIndex] -split '-')[0]
        return [pscustomobject]@{
            Pattern = (Get-PressureGenericPrefix -Part $parts -AnchorIndex $cliIndex) + "\$family*"
            Category = 'estado de CLI de IA'
            Rationale = 'Diretório de estado da ferramenta, reescrito continuamente durante o uso. O curinga cobre perfis isolados existentes e futuros.'
        }
    }

    # Caches de dependência: restauráveis, alto volume, baixo valor forense.
    if ($Path -match '(?i)\\(\.nuget|\.m2|\.gradle|\.cargo|node_modules|\.pnpm-store|\.npm|\.yarn)(\\|$)') {
        $token = $matches[1]
        $cacheIndex = -1
        for ($i = 1; $i -lt $parts.Count; $i++) {
            if ($parts[$i] -ieq $token) {
                $cacheIndex = $i
                break
            }
        }
        $sufixo = if ($token -ieq '.nuget') { "\$token\packages" } else { "\$token" }
        return [pscustomobject]@{
            Pattern = (Get-PressureGenericPrefix -Part $parts -AnchorIndex $cacheIndex) + $sufixo
            Category = 'cache de dependência'
            Rationale = 'Conteúdo restaurável a partir do repositório de pacotes, com o mesmo perfil de risco de caches já excluídos.'
        }
    }

    if ($Path -match '(?i)(dev-cache|\\uv\\|\\pip\\cache|\\Temp\\)') {
        return [pscustomobject]@{
            Pattern = (@($parts[0..([math]::Min(1, $parts.Count - 1))]) -join '\') + '\*'
            Category = 'cache de ferramenta'
            Rationale = 'Área de trabalho temporária de ferramenta de build, recriada sob demanda.'
        }
    }

    if ($Path -match '(?i)\\(bin|obj|target|dist|\.vs|\.gradle)(\\|$)') {
        return [pscustomobject]@{
            Pattern = ''
            Category = 'artefato de build'
            Rationale = 'Saída de compilação. A prática usual é excluir por processo de build, não por caminho de projeto.'
        }
    }

    if ($Path -match '(?i)^\w:\\Windows(\\|$)') {
        return [pscustomobject]@{
            Pattern = ''
            Category = 'componente do sistema'
            Rationale = 'Caminho do sistema operacional. Não é candidato a exclusão; o custo aqui indica atividade de build ou de runtime, não conteúdo a isentar.'
        }
    }

    return $vazio
}

function Get-PressureScanCost {
    <#
    .SYNOPSIS
    Ranqueia processos e diretórios pelo tempo que o antimalware gastou neles.

    .DESCRIPTION
    Responde "o que está sendo varrido" com a contabilidade do próprio motor,
    e cruza cada diretório com as exclusões declaradas: custo alto em caminho
    já excluído significa outra causa, custo alto em caminho exposto é um
    candidato objetivo para um chamado.

    Os números são amostrados pelo antimalware em intervalos próprios, então
    valem como ordem de grandeza e ranking, não como auditoria de arquivos.
    #>
    [CmdletBinding()]
    param(
        [object[]]$Record = @(),
        [string[]]$ExclusionPath = @(),
        [string[]]$ExclusionProcess = @(),
        [int]$Top = 6,
        [int]$DirectoryDepth = 5,
        [string[]]$DriveRoot = @()
    )

    # O log emite blocos periódicos com contadores ACUMULADOS por processo, não
    # incrementos: o mesmo PID reaparece a cada bloco com o mesmo TotalTime, e
    # somar registros multiplicaria o custo pelo número de blocos na janela.
    # A leitura correta é uma linha por PID, a mais recente.
    $records = @(
        @($Record) |
            Group-Object ProcessId, Process |
            ForEach-Object {
                @($_.Group | Sort-Object TotalTimeMs -Descending)[0]
            }
    )
    if ($records.Count -eq 0) {
        return [pscustomobject]@{
            Available = $false
            Samples = 0
            WindowStart = $null
            TotalSeconds = 0
            Processes = @()
            Paths = @()
        }
    }

    $byProcess = @(
        $records |
            Group-Object Process |
            ForEach-Object {
                $name = [string]$_.Name
                [pscustomobject]@{
                    Name = $name
                    Seconds = [math]::Round((($_.Group | Measure-Object TotalTimeMs -Sum).Sum) / 1000, 1)
                    Files = [int](($_.Group | Measure-Object FileCount -Sum).Sum)
                    MaxImpact = [int](($_.Group | Measure-Object ImpactPercent -Maximum).Maximum)
                    ExcludedProcess = ($ExclusionProcess -contains $name)
                }
            } |
            Sort-Object Seconds -Descending |
            Select-Object -First $Top
    )

    # As unidades são resolvidas uma vez por execução. Consultar o provedor por
    # registro custava mais que toda a agregação junta.
    $roots = if (@($DriveRoot).Count -gt 0) {
        @($DriveRoot)
    } else {
        @(
            Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType = 3' -ErrorAction SilentlyContinue |
                ForEach-Object { "$($_.DeviceID)\" }
        )
    }
    # O que muda entre registros é o arquivo, não o volume. Resolver por
    # dispositivo e não por caminho troca centenas de acessos ao disco por um
    # punhado — diferença que pesa justamente quando a máquina já está sob
    # varredura, que é quando esta função roda.
    $deviceMap = @{}

    $byPath = @(
        $records |
            ForEach-Object {
                $devicePath = [string]$_.DevicePath
                $full = $devicePath
                if ($devicePath -match '^(?<dev>\\Device\\HarddiskVolume\d+)\\') {
                    $device = $matches['dev']
                    if (-not $deviceMap.ContainsKey($device)) {
                        $resolved = Resolve-PressureDevicePath -Path $devicePath -DriveRoot $roots
                        # Guarda apenas a raiz descoberta, para reaproveitar em
                        # todos os demais caminhos do mesmo volume.
                        $sufixo = $devicePath.Substring($device.Length).TrimStart('\')
                        $deviceMap[$device] = if (
                            -not [string]::IsNullOrWhiteSpace($sufixo) -and
                            $resolved.EndsWith($sufixo, [StringComparison]::OrdinalIgnoreCase)
                        ) {
                            $resolved.Substring(0, $resolved.Length - $sufixo.Length).TrimEnd('\')
                        } else {
                            ''
                        }
                    }
                    $raiz = [string]$deviceMap[$device]
                    if (-not [string]::IsNullOrWhiteSpace($raiz)) {
                        $full = $raiz + $devicePath.Substring($device.Length)
                    }
                }
                $parts = @($full -split '\\')
                $take = [math]::Min($DirectoryDepth, [math]::Max(2, $parts.Count - 1))
                [pscustomobject]@{
                    Directory = ($parts[0..($take - 1)] -join '\')
                    TotalTimeMs = $_.TotalTimeMs
                }
            } |
            Group-Object Directory |
            ForEach-Object {
                $directory = [string]$_.Name
                $coverage = Test-PressureExclusionCoverage `
                    -Path $directory `
                    -ExclusionPath $ExclusionPath
                $suggestion = ConvertTo-PressureExclusionSuggestion -Path $directory
                [pscustomobject]@{
                    Label = ConvertTo-PressureDisplayPath -Path $directory
                    Seconds = [math]::Round((($_.Group | Measure-Object TotalTimeMs -Sum).Sum) / 1000, 1)
                    Events = $_.Count
                    Covered = [bool]$coverage.Covered
                    # Recomendação sempre por padrão, nunca por caminho literal:
                    # política de antimalware é definida por classe de conteúdo.
                    Suggestion = $suggestion.Pattern
                    Category = $suggestion.Category
                    Rationale = $suggestion.Rationale
                }
            } |
            Sort-Object Seconds -Descending |
            Select-Object -First $Top
    )

    return [pscustomobject]@{
        Available = $true
        # Processos distintos considerados, já sem a repetição entre blocos.
        Samples = $records.Count
        WindowStart = (($records | Measure-Object At -Minimum).Minimum).ToString('yyyy-MM-dd HH:mm')
        TotalSeconds = [math]::Round((($records | Measure-Object TotalTimeMs -Sum).Sum) / 1000, 1)
        Processes = $byProcess
        Paths = $byPath
    }
}

function Update-PressureScanCostCache {
    <#
    .SYNOPSIS
    Recalcula o ranking de custo de varredura sob condição e com cache.

    .DESCRIPTION
    Duas travas de custo, porque a resposta não vale qualquer preço:

    1. só recalcula quando há varredura em andamento ou o motor está de fato
       consumindo CPU. Máquina tranquila não paga por um ranking que diria
       apenas que nada está acontecendo;
    2. entre recálculos vale o cache. O ranking descreve minutos de trabalho
       acumulado e não muda de forma útil a cada ciclo do painel.

    Sem privilégio para ler o log, devolve indisponível em silêncio: é um
    detalhe a mais, não um requisito do painel.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)]$Defender,
        [datetime]$Now = (Get-Date)
    )

    $engineBusy = (
        $Defender.ScanInProgress -eq $true -or
        [double]$Defender.EngineCpuPercent -ge [double]$State.ScanCostEngineThreshold
    )
    if (-not $engineBusy) {
        # Preserva a última leitura: saber o que doeu no episódio anterior
        # continua útil depois que ele passa.
        return $State.ScanCost
    }
    if ($Now -lt $State.ScanCostRefreshAt -and $null -ne $State.ScanCost) {
        return $State.ScanCost
    }

    $logPath = Get-PressureMpLogPath
    if ([string]::IsNullOrWhiteSpace($logPath)) {
        $State.ScanCost = [pscustomobject]@{
            Available = $false
            Detail = 'Log do antimalware indisponível: leitura exige privilégio administrativo.'
            Samples = 0
            WindowStart = $null
            TotalSeconds = 0
            Processes = @()
            Paths = @()
        }
        $State.ScanCostRefreshAt = $Now.AddSeconds($State.ScanCostRefreshSeconds)
        return $State.ScanCost
    }

    $records = @(
        ConvertFrom-PressureMpLog -LogPath $logPath -Since $Now.AddHours(-2)
    )
    $cost = Get-PressureScanCost `
        -Record $records `
        -ExclusionPath @(
            if ($null -ne $State.DefenderPreference) { $State.DefenderPreference.ExclusionPath } else { @() }
        ) `
        -ExclusionProcess @(
            if ($null -ne $State.DefenderPreference) { $State.DefenderPreference.ExclusionProcess } else { @() }
        )

    $State.ScanCost = $cost |
        Add-Member -NotePropertyName MeasuredAt -NotePropertyValue $Now.ToString('yyyy-MM-dd HH:mm') -PassThru
    $State.ScanCostRefreshAt = $Now.AddSeconds($State.ScanCostRefreshSeconds)
    return $State.ScanCost
}

function Get-PressureScanProcess {
    <#
    .SYNOPSIS
    Detecta varredura agendada ou sob demanda em execução.

    .DESCRIPTION
    `FullScanStartTime` e `FullScanEndTime` só descrevem a varredura anterior:
    o provedor os atualiza quando ela termina. Comparar um com o outro responde
    "nada em andamento" justamente enquanto o motor consome a máquina, que é o
    momento em que a resposta importa.

    O processo de varredura é o sinal direto. `MpCmdRun.exe` também executa
    atualização de assinatura e outras tarefas, então quem decide é a linha de
    comando, não a mera presença do processo.

    Somente leitura: nenhuma varredura é iniciada, interrompida ou alterada.
    #>
    [CmdletBinding()]
    param(
        # Injetável para teste; vazio consulta a máquina.
        [object[]]$Process = $null
    )

    $candidates = if ($null -ne $Process) {
        @($Process)
    } else {
        try {
            @(Get-CimInstance -ClassName Win32_Process -Filter "Name='MpCmdRun.exe'" -ErrorAction Stop)
        } catch {
            @()
        }
    }

    foreach ($candidate in $candidates) {
        $commandLine = [string]$candidate.CommandLine
        if ($commandLine -notmatch '(?i)(^|\s)Scan(\s|$)') {
            continue
        }

        $startedAt = $null
        if ($null -ne $candidate.CreationDate) {
            try {
                $startedAt = [datetime]$candidate.CreationDate
            } catch {
                $startedAt = $null
            }
        }
        $scheduled = $commandLine -match '(?i)-ScheduleJob'

        return [pscustomobject]@{
            Active = $true
            ProcessId = [uint32]$candidate.ProcessId
            StartedAt = $startedAt
            Scheduled = $scheduled
            Kind = if ($scheduled) { 'agendada' } else { 'sob demanda' }
        }
    }

    return [pscustomobject]@{
        Active = $false
        ProcessId = [uint32]0
        StartedAt = $null
        Scheduled = $false
        Kind = ''
    }
}

function Get-PressureDefenderState {
    <#
    .SYNOPSIS
    Interpreta a configuração e o estado do antimalware.

    .DESCRIPTION
    Somente leitura e sem efeito colateral. O painel nunca altera política de
    antimalware: em máquina gerenciada isso é decisão da organização.

    A varredura em andamento é inferida por início posterior ao término
    registrado, que é como o próprio Windows expõe o estado.
    #>
    [CmdletBinding()]
    param(
        $Status = $null,
        $Preference = $null,
        [double]$EngineIoMBps = 0,
        [double]$EngineCpuPercent = 0,
        [object[]]$CliHomes = @(),
        $ScanProcess = $null,
        [datetime]$Now = (Get-Date)
    )

    if ($null -eq $Status -and $null -eq $Preference) {
        return [pscustomobject]@{
            Available = $false
            Detail = 'O namespace do antimalware não respondeu nesta máquina.'
            RealtimeEnabled = $null
            ScanInProgress = $false
            ScanStartedAt = $null
            ScanSource = ''
            ScanKind = ''
            SignatureUpdatedAt = $null
            SignatureAgeDays = $null
            SignatureVersion = ''
            LastFullScanEnd = $null
            ScheduleDay = $null
            ScheduleDayName = ''
            NextScheduledScan = $null
            MinutesUntilNextScan = $null
            ScanOnlyIfIdle = $null
            CatchupDisabled = $null
            EngineIoMBps = 0
            EngineCpuPercent = 0
            ToolchainGaps = @()
            CliHomes = @()
            ExposedCliHomeCount = 0
        }
    }

    $fullScanStart = if ($null -ne $Status) { $Status.FullScanStartTime } else { $null }
    $fullScanEnd = if ($null -ne $Status) { $Status.FullScanEndTime } else { $null }
    # Os campos descrevem a varredura anterior enquanto a atual roda, então
    # sozinhos eles nao detectam nada em andamento. O processo de varredura
    # complementa: basta um dos dois sinais para declarar varredura ativa.
    $fieldsIndicateScan = (
        $null -ne $fullScanStart -and
        (
            $null -eq $fullScanEnd -or
            [datetime]$fullScanStart -gt [datetime]$fullScanEnd
        )
    )
    $scanProcessActive = ($null -ne $ScanProcess -and $ScanProcess.Active -eq $true)
    $scanInProgress = ($fieldsIndicateScan -or $scanProcessActive)
    $scanSource = if ($scanProcessActive) {
        'processo de varredura'
    } elseif ($fieldsIndicateScan) {
        'campos do provedor'
    } else {
        ''
    }
    $scanStartedAt = if ($scanProcessActive -and $null -ne $ScanProcess.StartedAt) {
        ([datetime]$ScanProcess.StartedAt)
    } elseif ($fieldsIndicateScan -and $null -ne $fullScanStart) {
        ([datetime]$fullScanStart)
    } else {
        $null
    }

    $signatureUpdatedAt = if (
        $null -ne $Status -and
        $Status.PSObject.Properties.Name -contains 'AntivirusSignatureLastUpdated' -and
        $null -ne $Status.AntivirusSignatureLastUpdated
    ) {
        [datetime]$Status.AntivirusSignatureLastUpdated
    } else {
        $null
    }

    $scheduleDay = if ($null -ne $Preference -and $null -ne $Preference.ScanScheduleDay) {
        [int]$Preference.ScanScheduleDay
    } else {
        $null
    }
    # O provedor devolve TimeSpan neste Windows e DateTime em outros; aceitar
    # apenas um dos dois quebraria a leitura em máquinas perfeitamente normais.
    $scheduleTimeOfDay = [timespan]::Zero
    if ($null -ne $Preference -and $null -ne $Preference.ScanScheduleTime) {
        $rawScheduleTime = $Preference.ScanScheduleTime
        if ($rawScheduleTime -is [timespan]) {
            $scheduleTimeOfDay = [timespan]$rawScheduleTime
        } elseif ($rawScheduleTime -is [datetime]) {
            $scheduleTimeOfDay = ([datetime]$rawScheduleTime).TimeOfDay
        } else {
            try {
                $scheduleTimeOfDay = [timespan]::Parse([string]$rawScheduleTime)
            } catch {
                $scheduleTimeOfDay = [timespan]::Zero
            }
        }
    }

    $cliHomeCoverage = @(
        Get-PressureCliHomeCoverage `
            -Homes $CliHomes `
            -ExclusionPath @(if ($null -ne $Preference) { $Preference.ExclusionPath } else { @() }) `
            -ExclusionProcess @(if ($null -ne $Preference) { $Preference.ExclusionProcess } else { @() })
    )

    $nextScan = if ($null -ne $scheduleDay -and $scheduleDay -ge 0 -and $scheduleDay -le 8) {
        Get-PressureNextScheduledScan `
            -ScheduleDay $scheduleDay `
            -ScheduleTimeOfDay $scheduleTimeOfDay `
            -Now $Now
    } else {
        $null
    }

    [pscustomobject]@{
        Available = $true
        Detail = 'Estado e agenda lidos do provedor do antimalware; nada é alterado.'
        RealtimeEnabled = if ($null -ne $Status) {
            [bool]$Status.RealTimeProtectionEnabled
        } else {
            $null
        }
        ScanInProgress = $scanInProgress
        ScanStartedAt = if ($null -ne $scanStartedAt) {
            $scanStartedAt.ToString('yyyy-MM-dd HH:mm')
        } else {
            $null
        }
        ScanSource = $scanSource
        ScanKind = if ($scanProcessActive) { [string]$ScanProcess.Kind } else { '' }
        # Duração é o que o provedor não entrega enquanto a varredura roda: seus
        # campos seguem descrevendo a anterior até esta terminar.
        ScanElapsedMinutes = if ($scanInProgress -and $null -ne $scanStartedAt) {
            [math]::Round(($Now - $scanStartedAt).TotalMinutes, 0)
        } else {
            $null
        }
        SignatureUpdatedAt = if ($null -ne $signatureUpdatedAt) {
            $signatureUpdatedAt.ToString('yyyy-MM-dd HH:mm')
        } else {
            $null
        }
        SignatureAgeDays = if ($null -ne $signatureUpdatedAt) {
            [math]::Round(($Now - $signatureUpdatedAt).TotalDays, 0)
        } else {
            $null
        }
        SignatureVersion = if (
            $null -ne $Status -and
            $Status.PSObject.Properties.Name -contains 'AntivirusSignatureVersion'
        ) {
            [string]$Status.AntivirusSignatureVersion
        } else {
            ''
        }
        LastFullScanEnd = if ($null -ne $fullScanEnd) {
            ([datetime]$fullScanEnd).ToString('yyyy-MM-dd HH:mm')
        } else {
            $null
        }
        ScheduleDay = $scheduleDay
        ScheduleDayName = if (
            $null -ne $scheduleDay -and
            $scheduleDay -ge 0 -and
            $scheduleDay -lt $script:PressureDefenderScheduleDayNames.Count
        ) {
            $script:PressureDefenderScheduleDayNames[$scheduleDay]
        } else {
            ''
        }
        NextScheduledScan = if ($null -ne $nextScan) {
            ([datetime]$nextScan).ToString('yyyy-MM-dd HH:mm')
        } else {
            $null
        }
        MinutesUntilNextScan = if ($null -ne $nextScan) {
            [math]::Round(([datetime]$nextScan - $Now).TotalMinutes, 0)
        } else {
            $null
        }
        ScanOnlyIfIdle = if ($null -ne $Preference -and $null -ne $Preference.ScanOnlyIfIdleEnabled) {
            [bool]$Preference.ScanOnlyIfIdleEnabled
        } else {
            $null
        }
        CatchupDisabled = if ($null -ne $Preference -and $null -ne $Preference.DisableCatchupFullScan) {
            [bool]$Preference.DisableCatchupFullScan
        } else {
            $null
        }
        EngineIoMBps = [math]::Round($EngineIoMBps, 2)
        EngineCpuPercent = [math]::Round($EngineCpuPercent, 1)
        ToolchainGaps = @(
            Get-PressureToolchainExclusionGaps `
                -ExclusionPath @(if ($null -ne $Preference) { $Preference.ExclusionPath } else { @() }) `
                -ExclusionProcess @(if ($null -ne $Preference) { $Preference.ExclusionProcess } else { @() })
        )
        # Apenas rótulo e cobertura: o caminho completo revelaria o perfil do
        # usuário, e o painel não expõe caminho.
        CliHomes = $cliHomeCoverage
        ExposedCliHomeCount = @($cliHomeCoverage | Where-Object { -not $_.Covered }).Count
    }
}

function Update-PressureDefenderConfiguration {
    <#
    .SYNOPSIS
    Recarrega a configuração do antimalware em baixa frequência.

    .DESCRIPTION
    Agenda e exclusões são estáticas; consultar a cada ciclo só somaria custo à
    própria medição. O estado vivo do motor vem da tabela de processos, que já
    é coletada de qualquer forma.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State)

    $now = Get-Date
    if ($now -lt $State.DefenderRefreshAt) {
        return
    }

    $status = $null
    $preference = $null
    try {
        $status = Get-CimInstance `
            -Namespace root/Microsoft/Windows/Defender `
            -ClassName MSFT_MpComputerStatus `
            -ErrorAction Stop |
            Select-Object -First 1 RealTimeProtectionEnabled, FullScanStartTime,
                FullScanEndTime, QuickScanStartTime, QuickScanEndTime,
                AntivirusSignatureLastUpdated, AntivirusSignatureVersion
    } catch {
        $status = $null
    }
    try {
        $preference = Get-CimInstance `
            -Namespace root/Microsoft/Windows/Defender `
            -ClassName MSFT_MpPreference `
            -ErrorAction Stop |
            Select-Object -First 1 ExclusionPath, ExclusionProcess, ScanScheduleDay,
                ScanScheduleTime, ScanOnlyIfIdleEnabled, DisableCatchupFullScan
    } catch {
        $preference = $null
    }

    $State.DefenderStatus = $status
    $State.DefenderPreference = $preference
    $State.DefenderScanProcess = Get-PressureScanProcess
    $State.Capabilities.Defender = ($null -ne $status -or $null -ne $preference)
    $State.CliHomes = @(
        Get-PressureCliHomeCandidates `
            -Roots $State.CliHomeRoots `
            -EnvironmentHomes @($env:CLAUDE_CONFIG_DIR, $env:CODEX_HOME)
    )
    $State.DefenderRefreshAt = $now.AddSeconds($State.DefenderRefreshSeconds)
}

function Get-PressureWslConfigCaps {
    <#
    .SYNOPSIS
    Lê os tetos declarados no .wslconfig do usuário.

    .DESCRIPTION
    Somente leitura. Também informa em qual seção autoMemoryReclaim está: no
    WSL 2.7 a chave só vale dentro de [experimental] — em 03/08/2026 ela passou
    um mês dentro de [wsl2] sendo ignorada com aviso. Teto declarado não é teto
    vigente, e o painel mostra a diferença em vez de presumir.
    #>
    [CmdletBinding()]
    param(
        [string]$Path = (Join-Path $env:USERPROFILE '.wslconfig')
    )

    $caps = [pscustomobject]@{
        Present = $false
        MemoryGB = $null
        Processors = $null
        SwapGB = $null
        ReclaimMode = ''
        ReclaimActive = $null
    }
    if ([string]::IsNullOrWhiteSpace($Path) -or
        -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $caps
    }

    $caps.Present = $true
    $section = ''
    foreach ($line in @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)) {
        $trimmed = ([string]$line).Trim()
        if ($trimmed -match '^\[(?<name>[^\]]+)\]') {
            $section = $Matches.name.ToLowerInvariant()
            continue
        }
        if ($trimmed -notmatch '^(?<key>[A-Za-z]+)\s*=\s*(?<value>[^#\s]+)') {
            continue
        }
        $key = $Matches.key.ToLowerInvariant()
        $value = [string]$Matches.value
        switch ($key) {
            'memory' {
                if ($value -match '^(?<n>[\d.]+)\s*(?<u>GB|MB)$') {
                    $number = [double]$Matches.n
                    $caps.MemoryGB = if ($Matches.u -eq 'MB') {
                        [math]::Round($number / 1024, 1)
                    } else {
                        $number
                    }
                }
            }
            'processors' {
                if ($value -match '^\d+$') { $caps.Processors = [int]$value }
            }
            'swap' {
                if ($value -match '^(?<n>[\d.]+)\s*(?<u>GB|MB)$') {
                    $number = [double]$Matches.n
                    $caps.SwapGB = if ($Matches.u -eq 'MB') {
                        [math]::Round($number / 1024, 1)
                    } else {
                        $number
                    }
                }
            }
            'automemoryreclaim' {
                $caps.ReclaimMode = $value
                $caps.ReclaimActive = ($section -eq 'experimental')
            }
        }
    }
    $caps
}

function ConvertFrom-PressureDockerSize {
    <#
    .SYNOPSIS
    Converte um tamanho impresso pelo docker ("617.2MiB", "9.712GiB") em MB.
    #>
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }
    if ($Text -notmatch '(?<n>[\d.]+)\s*(?<u>[KkMmGgTt]i?B|B)') {
        return $null
    }
    $number = [double]$Matches.n
    switch -Regex ([string]$Matches.u) {
        '^[Kk]' { return [math]::Round($number / 1024, 3) }
        '^[Mm]' { return [math]::Round($number, 1) }
        '^[Gg]' { return [math]::Round($number * 1024, 0) }
        '^[Tt]' { return [math]::Round($number * 1024 * 1024, 0) }
        default { return [math]::Round($number / 1MB, 3) }
    }
}

function Get-PressureDockerState {
    <#
    .SYNOPSIS
    Interpreta a sondagem do Docker/WSL2 com semântica explícita de ausência.

    .DESCRIPTION
    Motor que não respondeu dentro do prazo vira o estado 'afogado', nunca
    "zero containers": em 03/08/2026 o silêncio do docker ps ERA o sintoma do
    travamento. Sem processos do Docker Desktop o estado é 'desligado' e
    nenhuma CLI chega a ser chamada.
    #>
    [CmdletBinding()]
    param(
        [bool]$EngineProcessesPresent = $false,
        [int]$EngineProcessCount = 0,
        [double]$EngineMemoryMB = 0,
        $Vmmem = $null,
        $Probe = $null,
        [bool]$ProbeTimedOut = $false,
        [int]$ProbeTimeoutSeconds = 8,
        $WslConfig = $null,
        [double]$VhdxSizeGB = 0,
        [datetime]$Now = (Get-Date)
    )

    $containers = @()
    $testcontainers = @()
    $runningCount = 0
    $danglingVolumes = $null
    $unboundedCount = $null
    $probeOk = (
        -not $ProbeTimedOut -and
        $null -ne $Probe -and
        $Probe.ContainsKey('Ok') -and
        $Probe.Ok -eq $true
    )

    if ($probeOk) {
        $runningCount = @($Probe.Running).Count
        $memoryCapMB = if ($null -ne $WslConfig -and $null -ne $WslConfig.MemoryGB) {
            [double]$WslConfig.MemoryGB * 1024
        } else {
            $null
        }
        $containers = @(
            foreach ($linha in @($Probe.Stats)) {
                $parte = [string]$linha -split '\|', 3
                if ($parte.Count -lt 3) { continue }
                $memParte = [string]$parte[2] -split '/', 2
                $usedMB = ConvertFrom-PressureDockerSize -Text $memParte[0]
                $limitMB = if ($memParte.Count -gt 1) {
                    ConvertFrom-PressureDockerSize -Text $memParte[1]
                } else {
                    $null
                }
                # Sem mem_limit, o docker imprime a memória total da VM como
                # limite: encostar nesse valor identifica container sem teto.
                $unbounded = if ($null -ne $memoryCapMB -and $null -ne $limitMB) {
                    $limitMB -ge ($memoryCapMB * 0.85)
                } else {
                    $null
                }
                [pscustomobject]@{
                    Name = [string]$parte[0]
                    CpuPercent = if ($parte[1] -match '(?<n>[\d.]+)') {
                        [math]::Round([double]$Matches.n, 1)
                    } else {
                        $null
                    }
                    MemoryMB = $usedMB
                    MemoryLimitMB = $limitMB
                    Unbounded = $unbounded
                }
            }
        )
        $unboundedCount = @($containers | Where-Object { $_.Unbounded -eq $true }).Count
        $testcontainers = @(
            foreach ($linha in @($Probe.Testcontainers)) {
                $parte = [string]$linha -split '\|', 2
                if ($parte.Count -lt 1 -or [string]::IsNullOrWhiteSpace($parte[0])) { continue }
                [pscustomobject]@{
                    Name = [string]$parte[0]
                    RunningFor = if ($parte.Count -gt 1) { [string]$parte[1] } else { '' }
                }
            }
        )
        if ($Probe.ContainsKey('DanglingCount')) {
            $danglingVolumes = [int]$Probe.DanglingCount
        }
    }

    $engineState = if (-not $EngineProcessesPresent) {
        'desligado'
    } elseif ($ProbeTimedOut) {
        'afogado'
    } elseif (-not $probeOk) {
        'indisponivel'
    } elseif ($runningCount -gt 0) {
        'ativo'
    } else {
        'ocioso'
    }
    $detail = switch ($engineState) {
        'desligado' { 'Docker Desktop sem processos; nenhuma CLI foi chamada.' }
        'afogado' {
            "O motor não respondeu em $ProbeTimeoutSeconds s. Leitura ausente não é " +
            'recurso zerado: em 03/08/2026 esse silêncio era o próprio sintoma.'
        }
        'indisponivel' {
            $motivo = if ($null -ne $Probe -and $Probe.ContainsKey('Error') -and $Probe.Error) {
                [string]$Probe.Error
            } else {
                'motivo não informado'
            }
            "Processos do Docker existem, mas a sondagem falhou: $motivo"
        }
        'ativo' { "$runningCount container(s) em execução; consumo por container abaixo." }
        default { 'Motor de pé e sem nenhum container em execução.' }
    }

    [pscustomobject]@{
        Available = $true
        EngineState = $engineState
        Detail = $detail
        EngineProcessCount = $EngineProcessCount
        EngineMemoryMB = [math]::Round($EngineMemoryMB, 0)
        VmmemPresent = ($null -ne $Vmmem)
        VmmemPid = if ($null -ne $Vmmem) { [int]$Vmmem.ProcessId } else { $null }
        VmmemWorkingSetMB = if ($null -ne $Vmmem) { [double]$Vmmem.WorkingSetMB } else { $null }
        VmmemPrivateMB = if ($null -ne $Vmmem) { [double]$Vmmem.PrivateMB } else { $null }
        # $null na primeira amostra: sem leitura anterior não há delta, e essa
        # leitura é ausente, não zero.
        VmmemCores = if ($null -ne $Vmmem) { $Vmmem.Cores } else { $null }
        RunningCount = $runningCount
        Containers = $containers
        UnboundedCount = $unboundedCount
        TestcontainersCount = @($testcontainers).Count
        Testcontainers = $testcontainers
        DanglingVolumes = $danglingVolumes
        WslConfig = $WslConfig
        VhdxSizeGB = $VhdxSizeGB
        CheckedAt = $Now.ToString('HH:mm:ss')
    }
}

function Update-PressureDockerState {
    <#
    .SYNOPSIS
    Sonda o Docker em cadência própria e com prazo duro.

    .DESCRIPTION
    As chamadas de CLI rodam num job de processo — não de thread — porque um
    docker.exe pendurado num motor afogado só é abortável matando o processo
    filho, e é exatamente nesse cenário que o painel mais precisa continuar
    respondendo. Estouro de prazo vira estado 'afogado' e dobra o intervalo até
    a próxima sondagem. Com o Docker desligado, nenhuma CLI é chamada.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State)

    $now = Get-Date
    if ($now -lt $State.DockerRefreshAt) {
        return
    }

    $engineProcs = @(
        Get-Process -Name 'com.docker.backend', 'Docker Desktop' -ErrorAction SilentlyContinue
    )
    $vmmemProcs = @(Get-Process -Name 'vmmem*' -ErrorAction SilentlyContinue)

    $vmmem = $null
    if ($vmmemProcs.Count -gt 0) {
        $vmmemProc = $vmmemProcs | Sort-Object WorkingSet64 -Descending | Select-Object -First 1
        $cpuSeconds = $null
        try { $cpuSeconds = [double]$vmmemProc.CPU } catch { $cpuSeconds = $null }
        $cores = $null
        $previous = $State.DockerPreviousVmmem
        if ($null -ne $previous -and
            $null -ne $cpuSeconds -and
            [int]$previous.ProcessId -eq [int]$vmmemProc.Id -and
            $cpuSeconds -ge [double]$previous.CpuSeconds) {
            $elapsed = ($now - [datetime]$previous.SampledAt).TotalSeconds
            if ($elapsed -gt 1) {
                $cores = [math]::Round(($cpuSeconds - [double]$previous.CpuSeconds) / $elapsed, 2)
            }
        }
        $State.DockerPreviousVmmem = [pscustomobject]@{
            ProcessId = [int]$vmmemProc.Id
            CpuSeconds = $cpuSeconds
            SampledAt = $now
        }
        $vmmem = [pscustomobject]@{
            ProcessId = [int]$vmmemProc.Id
            WorkingSetMB = [math]::Round($vmmemProc.WorkingSet64 / 1MB, 0)
            PrivateMB = [math]::Round($vmmemProc.PrivateMemorySize64 / 1MB, 0)
            Cores = $cores
        }
    } else {
        $State.DockerPreviousVmmem = $null
    }

    $probe = $null
    $timedOut = $false
    $probeTimeoutSeconds = 8
    if ($engineProcs.Count -gt 0) {
        $cli = Get-Command -Name docker -CommandType Application -ErrorAction SilentlyContinue
        if ($null -eq $cli) {
            $probe = @{ Ok = $false; Error = 'CLI docker não encontrada no PATH.' }
        } else {
            $job = Start-Job -ScriptBlock {
                $resultado = @{ Ok = $false; Error = '' }
                try {
                    $running = @(docker ps --format '{{.Names}}' 2>$null)
                    if ($LASTEXITCODE -ne 0) {
                        $resultado.Error = 'docker ps retornou erro.'
                        return $resultado
                    }
                    $stats = @()
                    if ($running.Count -gt 0) {
                        $stats = @(
                            docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}' 2>$null
                        )
                    }
                    $testcontainers = @(
                        docker ps --filter 'label=org.testcontainers=true' --format '{{.Names}}|{{.RunningFor}}' 2>$null
                    )
                    $dangling = @(docker volume ls -q -f dangling=true 2>$null)
                    $resultado.Ok = $true
                    $resultado.Running = $running
                    $resultado.Stats = $stats
                    $resultado.Testcontainers = $testcontainers
                    $resultado.DanglingCount = @($dangling).Count
                } catch {
                    $resultado.Error = [string]$_.Exception.Message
                }
                $resultado
            }
            if (Wait-Job -Job $job -Timeout $probeTimeoutSeconds) {
                try {
                    $probe = Receive-Job -Job $job -ErrorAction Stop
                    if ($probe -is [object[]]) { $probe = $probe[-1] }
                    if ($probe -isnot [hashtable]) {
                        $probe = @{ Ok = $false; Error = 'sondagem devolveu formato inesperado.' }
                    }
                } catch {
                    $probe = @{ Ok = $false; Error = [string]$_.Exception.Message }
                }
            } else {
                Stop-Job -Job $job
                $timedOut = $true
            }
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        }
    }

    $vhdxSizeGB = 0.0
    $vhdxPath = Join-Path $env:LOCALAPPDATA 'Docker\wsl\disk\docker_data.vhdx'
    if (Test-Path -LiteralPath $vhdxPath -PathType Leaf) {
        $vhdxSizeGB = [math]::Round((Get-Item -LiteralPath $vhdxPath).Length / 1GB, 1)
    }

    $State.DockerState = Get-PressureDockerState `
        -EngineProcessesPresent ($engineProcs.Count -gt 0) `
        -EngineProcessCount $engineProcs.Count `
        -EngineMemoryMB ([double](($engineProcs | Measure-Object WorkingSet64 -Sum).Sum) / 1MB) `
        -Vmmem $vmmem `
        -Probe $probe `
        -ProbeTimedOut $timedOut `
        -ProbeTimeoutSeconds $probeTimeoutSeconds `
        -WslConfig (Get-PressureWslConfigCaps) `
        -VhdxSizeGB $vhdxSizeGB `
        -Now $now
    $State.Capabilities.Docker = (
        $engineProcs.Count -gt 0 -and -not $timedOut -and
        $null -ne $probe -and $probe.ContainsKey('Ok') -and $probe.Ok -eq $true
    )
    $refreshSeconds = [int]$State.DockerRefreshSeconds
    # Motor afogado: dobrar o intervalo evita pagar o prazo inteiro a cada
    # ciclo justamente quando o painel mais precisa se manter leve.
    $State.DockerRefreshAt = if ($timedOut) {
        $now.AddSeconds([math]::Max(60, $refreshSeconds * 2))
    } else {
        $now.AddSeconds($refreshSeconds)
    }
}

function Get-PressureParentWatch {
    <#
    .SYNOPSIS
    Registra a identidade do processo que lançou o painel.

    .DESCRIPTION
    Guarda PID e horário de criação juntos. O horário é o que impede confundir
    o pai original com um processo novo que recebeu o mesmo PID reciclado.
    #>
    [CmdletBinding()]
    param([uint32]$ProcessId = [uint32]$PID)

    $disabled = [pscustomobject]@{
        Enabled = $false
        ParentId = [uint32]0
        ParentName = ''
        StartedAt = [datetime]::MinValue
    }

    try {
        $self = Get-CimInstance `
            -ClassName Win32_Process `
            -Filter "ProcessId=$ProcessId" `
            -Property ParentProcessId `
            -ErrorAction Stop
        if ($null -eq $self) {
            return $disabled
        }

        $parentId = [uint32]$self.ParentProcessId
        if ($parentId -eq 0) {
            return $disabled
        }

        $parent = Get-CimInstance `
            -ClassName Win32_Process `
            -Filter "ProcessId=$parentId" `
            -Property ProcessId, Name, CreationDate `
            -ErrorAction Stop
        if ($null -eq $parent -or $null -eq $parent.CreationDate) {
            # Pai já ausente na largada: não há o que vigiar.
            return $disabled
        }

        return [pscustomobject]@{
            Enabled = $true
            ParentId = $parentId
            ParentName = [string]$parent.Name
            StartedAt = [datetime]$parent.CreationDate
        }
    } catch {
        return $disabled
    }
}

function Test-PressureParentAlive {
    <#
    .SYNOPSIS
    Diz se o processo pai vigiado continua sendo o mesmo de antes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Watch,
        [ValidateRange(0, 60)][int]$ToleranceSeconds = 2
    )

    if (-not $Watch.Enabled) {
        return $true
    }

    try {
        $parent = Get-CimInstance `
            -ClassName Win32_Process `
            -Filter "ProcessId=$([uint32]$Watch.ParentId)" `
            -Property ProcessId, Name, CreationDate `
            -ErrorAction Stop
    } catch {
        return $false
    }

    if ($null -eq $parent -or $null -eq $parent.CreationDate) {
        return $false
    }
    if (
        (Get-PressureBaseProcessName -Name ([string]$parent.Name)) -ne
        (Get-PressureBaseProcessName -Name ([string]$Watch.ParentName))
    ) {
        return $false
    }

    $delta = [math]::Abs(
        ([datetime]$parent.CreationDate).ToUniversalTime().Ticks -
        ([datetime]$Watch.StartedAt).ToUniversalTime().Ticks
    )
    return $delta -le ([timespan]::FromSeconds($ToleranceSeconds).Ticks)
}

function ConvertTo-PressureHistoryRecord {
    <#
    .SYNOPSIS
    Reduz um snapshot à linha compacta que vai para o histórico local.

    .DESCRIPTION
    Grava apenas números e nomes de processo. Linha de comando, caminho de
    executável e endereço remoto nunca entram, para o arquivo herdar a mesma
    promessa de privacidade do snapshot.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Snapshot,
        [ValidateRange(0, 12)][int]$TopCount = 3
    )

    $metrics = $Snapshot.Metrics
    $selfCost = $Snapshot.SelfCost
    $top = @(
        @($Snapshot.Consumers.cpu) |
            Select-Object -First $TopCount |
            ForEach-Object {
                [ordered]@{
                    n = [string]$_.Name
                    cpu = [double]$_.CpuPercent
                    mem = [double]$_.PrivateMB
                    io = [double]$_.IoTotalMBps
                }
            }
    )

    [ordered]@{
        kind = 'sample'
        t = [string]$Snapshot.GeneratedAt
        level = [int]$Snapshot.Overall.Level
        state = [string]$Snapshot.Overall.State
        score = [double]$Snapshot.Overall.Score
        dominant = [string]$Snapshot.Overall.DominantResource
        cpu = [double]$metrics.CpuPercent
        availMB = [double]$metrics.AvailableMB
        commitPct = [double]$metrics.CommitPercent
        pagesOut = [double]$metrics.PagesOutputPerSec
        diskPct = [double]$metrics.DiskPercent
        diskQueue = [double]$metrics.DiskQueue
        diskLatMs = $metrics.DiskLatencyMs
        diskReadMBps = [double]$metrics.DiskReadMBps
        diskWriteMBps = [double]$metrics.DiskWriteMBps
        freeGB = $metrics.LowestFreeGB
        gpuPct = [double]$metrics.GpuPercent
        netPct = [double]$metrics.NetworkPercent
        collectMs = [double]$Snapshot.CollectionDurationMs
        refreshSec = [int]$Snapshot.RefreshSeconds
        selfCpu = [double]$selfCost.SelfCpuPercent
        selfDuty = [double]$selfCost.DutyPercent
        wmiCpu = [double]$selfCost.WmiProviderCpuPercent
        # Sem isto, olhar o histórico depois não responde à pergunta que mais
        # importa: havia varredura em curso quando a máquina degradou?
        scanning = [bool]$Snapshot.Defender.ScanInProgress
        avIoMBps = [double]$Snapshot.Defender.EngineIoMBps
        avCpu = [double]$Snapshot.Defender.EngineCpuPercent
        top = $top
    }
}

function New-PressureHistoryBaseline {
    <#
    .SYNOPSIS
    Monta o registro que abre cada arquivo de histórico.

    .DESCRIPTION
    Sem esta linha, um arquivo de amostras não diz de qual computador veio nem
    o que era normal nele. Com ela, cada arquivo se explica sozinho.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$State,
        [ValidateSet('session-start', 'session-end')]
        [string]$Kind = 'session-start',
        [AllowEmptyString()][string]$Reason = '',
        [datetime]$Now = (Get-Date)
    )

    $bootedAt = $null
    try {
        $bootedAt = (
            Get-CimInstance `
                -ClassName Win32_OperatingSystem `
                -Property LastBootUpTime `
                -ErrorAction Stop
        ).LastBootUpTime
    } catch {
        $bootedAt = $null
    }

    [ordered]@{
        kind = $Kind
        t = $Now.ToString('o')
        reason = $Reason
        schema = 2
        startedAt = ([datetime]$State.StartedAt).ToString('o')
        bootedAt = if ($null -ne $bootedAt) { ([datetime]$bootedAt).ToString('o') } else { $null }
        cores = [int]$State.LogicalProcessorCount
        totalRamGB = [math]::Round([double]$State.TotalPhysicalMemoryBytes / 1GB, 1)
        refreshSec = [int]$State.RefreshSeconds
        collections = [int]$State.CollectionCount
        volumes = @(
            $State.DiskCapacities | ForEach-Object {
                [ordered]@{
                    drive = [string]$_.Drive
                    freeGB = [double]$_.FreeGB
                }
            }
        )
    }
}

function New-PressureHistoryWriter {
    <#
    .SYNOPSIS
    Cria o escritor de histórico local com retenção declarada.

    .DESCRIPTION
    A escrita é em lote de propósito. Gravar a cada amostra num caminho comum
    do usuário produziria E/S pequena e contínua — exatamente o padrão que o
    painel existe para diagnosticar.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Directory,

        [ValidateRange(1, 365)]
        [int]$RetentionDays = 7,

        [ValidateRange(1, 4096)]
        [int]$MaxMB = 50,

        [ValidateRange(5, 3600)]
        [int]$FlushSeconds = 60,

        # Identifica quem escreve. Dois coletores no mesmo arquivo diário
        # disputariam o handle, e a amostra perdida não voltaria.
        [ValidatePattern('^[a-z0-9-]{0,24}$')]
        [string]$Tag = '',

        [datetime]$Now = (Get-Date),

        [switch]$Disabled
    )

    [pscustomobject]@{
        Directory = [IO.Path]::GetFullPath($Directory)
        Tag = $Tag
        FallbackTag = ''
        Enabled = -not [bool]$Disabled
        RetentionDays = $RetentionDays
        MaxBytes = [double]$MaxMB * 1MB
        FlushSeconds = $FlushSeconds
        Buffer = [Collections.Generic.List[string]]::new()
        NextFlushAt = $Now.AddSeconds($FlushSeconds)
        NextRetentionAt = [datetime]::MinValue
        PendingCleanup = @()
        WrittenLines = 0
        DroppedLines = 0
        LastError = ''
    }
}

function Get-PressureHistoryFilePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Writer,
        [datetime]$Now = (Get-Date)
    )

    $tag = if (-not [string]::IsNullOrWhiteSpace($Writer.FallbackTag)) {
        [string]$Writer.FallbackTag
    } else {
        [string]$Writer.Tag
    }
    $suffix = if ([string]::IsNullOrWhiteSpace($tag)) { '' } else { "_$tag" }

    Join-Path $Writer.Directory ("pressure_{0:yyyy-MM-dd}{1}.jsonl" -f $Now, $suffix)
}

function Get-PressureHistoryExpired {
    <#
    .SYNOPSIS
    Lista os arquivos de histórico que excederam a retenção declarada.

    .DESCRIPTION
    Somente leitura, por decisão de arquitetura: quem apaga é
    `scripts\remove-pressure-history.ps1`, que carrega o gate de dry-run,
    `-Execute` e `ShouldProcess`. Esta função apenas calcula o plano.

    A idade é avaliada primeiro; o teto de tamanho depois, do arquivo mais
    antigo para o mais novo. O arquivo do dia corrente nunca entra no plano,
    porque é o que está sendo escrito.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Directory,

        [ValidateRange(1, 365)]
        [int]$RetentionDays = 7,

        [double]$MaxBytes = 50MB,

        [datetime]$Now = (Get-Date)
    )

    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        return @()
    }

    $files = @(
        Get-ChildItem -LiteralPath $Directory -Filter 'pressure_*.jsonl' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime
    )
    if ($files.Count -eq 0) {
        return @()
    }

    # Protege todos os arquivos do dia corrente, de qualquer coletor: o nome
    # carrega identidade, então comparar por nome exato deixaria de proteger o
    # arquivo que outro coletor está escrevendo agora.
    $currentPrefix = ("pressure_{0:yyyy-MM-dd}" -f $Now)
    $expired = [Collections.Generic.List[object]]::new()
    $expiredKeys = @{}
    $cutoff = $Now.AddDays(-$RetentionDays)

    foreach ($file in $files) {
        if ($file.Name.StartsWith($currentPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        if ($file.LastWriteTime -lt $cutoff) {
            $expired.Add([pscustomobject]@{
                Name = $file.Name
                FullName = $file.FullName
                Length = [double]$file.Length
                LastWriteTime = $file.LastWriteTime
                Reason = 'idade'
            })
            $expiredKeys[$file.FullName] = $true
        }
    }

    $totalBytes = ($files | Measure-Object Length -Sum).Sum
    if ($null -eq $totalBytes) {
        $totalBytes = 0
    }
    foreach ($entry in $expired) {
        $totalBytes -= $entry.Length
    }

    foreach ($file in $files) {
        if ($totalBytes -le $MaxBytes) {
            break
        }
        if (
            $file.Name.StartsWith($currentPrefix, [StringComparison]::OrdinalIgnoreCase) -or
            $expiredKeys.ContainsKey($file.FullName)
        ) {
            continue
        }

        $totalBytes -= [double]$file.Length
        $expired.Add([pscustomobject]@{
            Name = $file.Name
            FullName = $file.FullName
            Length = [double]$file.Length
            LastWriteTime = $file.LastWriteTime
            Reason = 'tamanho'
        })
        $expiredKeys[$file.FullName] = $true
    }

    return @($expired)
}

function Save-PressureHistoryBuffer {
    <#
    .SYNOPSIS
    Descarrega o buffer em disco num único acréscimo.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Writer,
        [datetime]$Now = (Get-Date)
    )

    if (-not $Writer.Enabled -or $Writer.Buffer.Count -eq 0) {
        return 0
    }

    $lines = @($Writer.Buffer.ToArray())
    $written = $false
    # Duas tentativas: a segunda troca para um arquivo com sufixo de PID. Assim
    # uma disputa de handle com outro coletor não descarta amostra em silêncio.
    foreach ($attempt in 1, 2) {
        try {
            if (-not (Test-Path -LiteralPath $Writer.Directory -PathType Container)) {
                New-Item -ItemType Directory -Path $Writer.Directory -Force | Out-Null
            }
            $path = Get-PressureHistoryFilePath -Writer $Writer -Now $Now
            [IO.File]::AppendAllLines(
                $path,
                [string[]]$lines,
                [Text.UTF8Encoding]::new($false)
            )
            $written = $true
            $Writer.LastError = ''
            break
        } catch {
            $Writer.LastError = [string]$_.Exception.Message
            if ($attempt -eq 1 -and [string]::IsNullOrWhiteSpace($Writer.FallbackTag)) {
                $base = if ([string]::IsNullOrWhiteSpace($Writer.Tag)) { 'p' } else { "$($Writer.Tag)-p" }
                $Writer.FallbackTag = "$base$PID"
                continue
            }
            break
        }
    }

    $Writer.Buffer.Clear()
    $Writer.NextFlushAt = $Now.AddSeconds($Writer.FlushSeconds)
    if ($written) {
        $Writer.WrittenLines = [int]$Writer.WrittenLines + $lines.Count
    } else {
        # Histórico é observabilidade, não missão crítica: a coleta segue. Mas o
        # descarte fica contado, para não passar por gravação completa.
        $Writer.DroppedLines = [int]$Writer.DroppedLines + $lines.Count
        return 0
    }

    if ($Now -ge $Writer.NextRetentionAt) {
        $Writer.PendingCleanup = @(
            Get-PressureHistoryExpired `
                -Directory $Writer.Directory `
                -RetentionDays $Writer.RetentionDays `
                -MaxBytes $Writer.MaxBytes `
                -Now $Now
        )
        $Writer.NextRetentionAt = $Now.AddHours(1)
    }

    return $lines.Count
}

function Add-PressureHistoryRecord {
    <#
    .SYNOPSIS
    Enfileira um registro e descarrega quando o lote vence.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Writer,
        [Parameter(Mandatory)]$Record,
        [datetime]$Now = (Get-Date),
        [switch]$Flush
    )

    if (-not $Writer.Enabled) {
        return 0
    }

    $Writer.Buffer.Add(($Record | ConvertTo-Json -Depth 6 -Compress))
    if ($Flush -or $Now -ge $Writer.NextFlushAt) {
        return Save-PressureHistoryBuffer -Writer $Writer -Now $Now
    }

    return 0
}

function Get-PressureSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State)

    $startedAt = Get-Date
    $warnings = [Collections.Generic.List[string]]::new()

    Update-PressureProcessMetadata -State $State
    Update-PressureConnectionCounts -State $State
    Update-PressureDiskCapacities -State $State
    Update-PressureDefenderConfiguration -State $State
    Update-PressureDockerState -State $State

    $cpuRows = @()
    $memoryRow = $null
    $diskRows = @()
    $diskRawRows = @()
    $processRows = @()
    $networkRows = @()
    $gpuEngineRows = @()
    $gpuMemoryRows = @()
    $gpuAdapterMemoryRows = @()

    try {
        $cpuRows = @(
            Get-CimInstance `
                Win32_PerfRawData_PerfOS_Processor `
                -Property Name, PercentProcessorTime, Timestamp_Sys100NS `
                -ErrorAction Stop
        )
    } catch {
        $warnings.Add('cpu_unavailable')
    }
    try {
        $memoryRow = Get-CimInstance `
            Win32_PerfFormattedData_PerfOS_Memory `
            -Property AvailableMBytes, PercentCommittedBytesInUse, PagesOutputPersec `
            -ErrorAction Stop |
                Select-Object -First 1
    } catch {
        $warnings.Add('memory_unavailable')
    }
    try {
        $diskRows = @(
            Get-CimInstance `
                Win32_PerfFormattedData_PerfDisk_PhysicalDisk `
                -Property Name, PercentDiskTime, CurrentDiskQueueLength,
                    DiskReadBytesPersec, DiskWriteBytesPersec `
                -ErrorAction Stop
        )
        $diskRawRows = @(
            Get-CimInstance `
                Win32_PerfRawData_PerfDisk_PhysicalDisk `
                -Property Name, Frequency_PerfTime, AvgDiskSecPerTransfer,
                    AvgDiskSecPerTransfer_Base, AvgDiskSecPerRead,
                    AvgDiskSecPerRead_Base, AvgDiskSecPerWrite,
                    AvgDiskSecPerWrite_Base `
                -ErrorAction Stop
        )
    } catch {
        $warnings.Add('disk_unavailable')
    }
    try {
        $processRows = @(
            Get-CimInstance `
                Win32_PerfFormattedData_PerfProc_Process `
                -Property Name, IDProcess, PercentProcessorTime, PrivateBytes,
                    WorkingSet, IOReadBytesPersec, IOWriteBytesPersec,
                    IODataBytesPersec `
                -ErrorAction Stop
        )
    } catch {
        $warnings.Add('process_unavailable')
    }
    try {
        $networkRows = @(
            Get-CimInstance `
                Win32_PerfFormattedData_Tcpip_NetworkInterface `
                -Property Name, BytesTotalPersec, CurrentBandwidth `
                -ErrorAction Stop
        )
    } catch {
        $warnings.Add('network_unavailable')
    }
    if ($State.Capabilities.GpuEngine) {
        try {
            $gpuEngineRows = @(
                Get-CimInstance `
                    Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine `
                    -Property Name, UtilizationPercentage `
                    -ErrorAction Stop
            )
        } catch {
            $warnings.Add('gpu_engine_unavailable')
        }
    }
    if ($State.Capabilities.GpuProcessMemory) {
        try {
            $gpuMemoryRows = @(
                Get-CimInstance `
                    Win32_PerfFormattedData_GPUPerformanceCounters_GPUProcessMemory `
                    -Property Name, DedicatedUsage, SharedUsage, TotalCommitted `
                    -ErrorAction Stop
            )
        } catch {
            $warnings.Add('gpu_memory_unavailable')
        }
    }
    if ($State.Capabilities.GpuAdapterMemory) {
        try {
            $gpuAdapterMemoryRows = @(
                Get-CimInstance `
                    Win32_PerfFormattedData_GPUPerformanceCounters_GPUAdapterMemory `
                    -Property DedicatedUsage, SharedUsage `
                    -ErrorAction Stop
            )
        } catch {
            $warnings.Add('gpu_adapter_memory_unavailable')
        }
    }

    $cpuUtilization = Get-PressureCpuUtilization -RawRows $cpuRows -State $State
    # Os zeros abaixo mantêm o formato da amostra estável para o histórico; quem
    # decide se o número vale são os campos CpuAvailable e MemoryAvailable.
    # A primeira coleta sempre cai aqui: sem amostra anterior não há delta, e
    # essa leitura é ausente, não zero.
    $cpuAvailable = $null -ne $cpuUtilization
    $memoryAvailable = $null -ne $memoryRow
    $cpuPercent = if ($null -ne $cpuUtilization) {
        [double]$cpuUtilization
    } else {
        0.0
    }
    $availableMB = if ($null -ne $memoryRow) {
        [double]$memoryRow.AvailableMBytes
    } else {
        0.0
    }
    $commitPercent = if ($null -ne $memoryRow) {
        [double]$memoryRow.PercentCommittedBytesInUse
    } else {
        0.0
    }
    $pagesOutputPerSec = if ($null -ne $memoryRow) {
        [double]$memoryRow.PagesOutputPersec
    } else {
        0.0
    }
    $availablePercent = if ($State.TotalPhysicalMemoryBytes -gt 0) {
        100 * ($availableMB * 1MB) / $State.TotalPhysicalMemoryBytes
    } else {
        0.0
    }

    $diskLatencies = Get-PressureDiskLatencies -RawRows $diskRawRows -State $State
    $diskTotal = @($diskRows | Where-Object Name -eq '_Total' | Select-Object -First 1)
    $diskPercent = if ($diskTotal.Count -gt 0) {
        [math]::Min(100, [double]$diskTotal[0].PercentDiskTime)
    } else {
        0.0
    }
    $diskQueue = if ($diskTotal.Count -gt 0) {
        [double]$diskTotal[0].CurrentDiskQueueLength
    } else {
        0.0
    }
    $diskReadMBps = if ($diskTotal.Count -gt 0) {
        [double]$diskTotal[0].DiskReadBytesPersec / 1MB
    } else {
        0.0
    }
    $diskWriteMBps = if ($diskTotal.Count -gt 0) {
        [double]$diskTotal[0].DiskWriteBytesPersec / 1MB
    } else {
        0.0
    }
    $diskLatencyMs = if ($diskLatencies.ContainsKey('_Total')) {
        $diskLatencies['_Total'].TransferMs
    } else {
        $null
    }
    $lowestFree = @(
        $State.DiskCapacities |
            Where-Object { $null -ne $_.FreeGB } |
            Sort-Object FreeGB |
            Select-Object -First 1
    )
    $lowestFreeGB = if ($lowestFree.Count -gt 0) {
        [double]$lowestFree[0].FreeGB
    } else {
        $null
    }

    $physicalDisks = @(
        foreach ($diskRow in $diskRows | Where-Object Name -ne '_Total') {
            $name = [string]$diskRow.Name
            $latency = if ($diskLatencies.ContainsKey($name)) {
                $diskLatencies[$name]
            } else {
                $null
            }
            [pscustomobject]@{
                Name = $name
                ActivePercent = [math]::Round(
                    [math]::Min(100, [double]$diskRow.PercentDiskTime),
                    1
                )
                Queue = [double]$diskRow.CurrentDiskQueueLength
                ReadMBps = [math]::Round([double]$diskRow.DiskReadBytesPersec / 1MB, 2)
                WriteMBps = [math]::Round([double]$diskRow.DiskWriteBytesPersec / 1MB, 2)
                LatencyMs = if ($null -ne $latency) { $latency.TransferMs } else { $null }
                ReadLatencyMs = if ($null -ne $latency) { $latency.ReadMs } else { $null }
                WriteLatencyMs = if ($null -ne $latency) { $latency.WriteMs } else { $null }
            }
        }
    )

    $networkBytesPerSec = 0.0
    $networkPercent = 0.0
    foreach ($networkRow in $networkRows) {
        $name = [string]$networkRow.Name
        if ($name -match '(?i)(loopback|isatap|teredo)') {
            continue
        }

        $bytes = [double]$networkRow.BytesTotalPersec
        $bandwidth = [double]$networkRow.CurrentBandwidth
        $networkBytesPerSec += $bytes
        if ($bandwidth -gt 0) {
            $rowPercent = [math]::Min(100, 100 * ($bytes * 8) / $bandwidth)
            $networkPercent = [math]::Max($networkPercent, $rowPercent)
        }
    }

    $gpuEngineData = Get-PressureGpuEngineData -Rows $gpuEngineRows
    $gpuMemoryByPid = Get-PressureGpuMemoryData -Rows $gpuMemoryRows
    $gpuDedicatedBytes = (
        $gpuAdapterMemoryRows |
            Measure-Object -Property DedicatedUsage -Sum
    ).Sum
    $gpuSharedBytes = (
        $gpuAdapterMemoryRows |
            Measure-Object -Property SharedUsage -Sum
    ).Sum
    if ($null -eq $gpuDedicatedBytes) { $gpuDedicatedBytes = 0 }
    if ($null -eq $gpuSharedBytes) { $gpuSharedBytes = 0 }

    $processes = @(
        foreach ($row in $processRows) {
            $processId = [uint32]$row.IDProcess
            if ($processId -eq 0 -or [string]$row.Name -in @('_Total', 'Idle')) {
                continue
            }

            $pidKey = [string]$processId
            $metadata = if ($State.MetadataByPid.ContainsKey($pidKey)) {
                $State.MetadataByPid[$pidKey]
            } else {
                $fallback = Get-PressureProcessContext -Name ([string]$row.Name)
                [pscustomobject]@{
                    Id = [uint32]$processId
                    Name = [string]$row.Name
                    ParentId = 0
                    ParentName = ''
                    CreationDate = [datetime]::MinValue
                    SessionId = [uint32]0
                    Category = $fallback.Category
                    Purpose = $fallback.Purpose
                    ServiceNames = @()
                    Protected = Test-PressureProtectedProcess -Name ([string]$row.Name)
                    IsTerminalHost = (
                        (Get-PressureBaseProcessName -Name ([string]$row.Name)) -in
                        $script:PressureTerminalHostProcessNames
                    )
                    CliName = ''
                    CliDetectionConfidence = 'nenhuma'
                    Workload = Get-PressureWorkloadLabel -Name ([string]$row.Name)
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
            $gpuEngine = if ($gpuEngineData.ByPid.ContainsKey($pidKey)) {
                $gpuEngineData.ByPid[$pidKey]
            } else {
                $null
            }
            $gpuMemory = if ($gpuMemoryByPid.ContainsKey($pidKey)) {
                $gpuMemoryByPid[$pidKey]
            } else {
                $null
            }
            $connectionCount = if ($State.ConnectionCountsByPid.ContainsKey($pidKey)) {
                [int]$State.ConnectionCountsByPid[$pidKey]
            } else {
                0
            }

            [pscustomobject]@{
                Id = $processId
                Name = [string]$metadata.Name
                ParentId = [uint32]$metadata.ParentId
                ParentName = [string]$metadata.ParentName
                StartedAt = if (
                    [datetime]$metadata.CreationDate -ne [datetime]::MinValue
                ) {
                    ([datetime]$metadata.CreationDate).ToString('o')
                } else {
                    $null
                }
                SessionId = [uint32]$metadata.SessionId
                Category = [string]$metadata.Category
                Purpose = [string]$metadata.Purpose
                Protected = [bool]$metadata.Protected
                IsTerminalHost = [bool]$metadata.IsTerminalHost
                CliName = [string]$metadata.CliName
                Workload = [string]$metadata.Workload
                TerminalHosted = [bool]$metadata.TerminalHosted
                TerminalId = [uint32]$metadata.TerminalId
                TerminalName = [string]$metadata.TerminalName
                TerminalSessionRootId = [uint32]$metadata.TerminalSessionRootId
                TerminalSessionRootName = [string]$metadata.TerminalSessionRootName
                OwningCliId = [uint32]$metadata.OwningCliId
                OwningCliName = [string]$metadata.OwningCliName
                RootCliId = [uint32]$metadata.RootCliId
                RootCliName = [string]$metadata.RootCliName
                Lineage = @($metadata.Lineage)
                CpuPercent = [math]::Round(
                    [math]::Min(
                        100,
                        [double]$row.PercentProcessorTime / $State.LogicalProcessorCount
                    ),
                    1
                )
                PrivateMB = [math]::Round([double]$row.PrivateBytes / 1MB, 1)
                WorkingSetMB = [math]::Round([double]$row.WorkingSet / 1MB, 1)
                IoReadMBps = [math]::Round([double]$row.IOReadBytesPersec / 1MB, 2)
                IoWriteMBps = [math]::Round([double]$row.IOWriteBytesPersec / 1MB, 2)
                IoTotalMBps = [math]::Round([double]$row.IODataBytesPersec / 1MB, 2)
                GpuPercent = if ($null -ne $gpuEngine) {
                    [double]$gpuEngine.Percent
                } else {
                    0.0
                }
                GpuEngine = if ($null -ne $gpuEngine) {
                    [string]$gpuEngine.Engine
                } else {
                    ''
                }
                GpuDedicatedMB = if ($null -ne $gpuMemory) {
                    [math]::Round([double]$gpuMemory.DedicatedBytes / 1MB, 1)
                } else {
                    0.0
                }
                GpuSharedMB = if ($null -ne $gpuMemory) {
                    [math]::Round([double]$gpuMemory.SharedBytes / 1MB, 1)
                } else {
                    0.0
                }
                GpuMemoryMB = if ($null -ne $gpuMemory) {
                    [math]::Round([double]$gpuMemory.CommittedBytes / 1MB, 1)
                } else {
                    0.0
                }
                EstablishedConnections = $connectionCount
            }
        }
    )

    $consumers = [ordered]@{
        cpu = @(
            $processes |
                Sort-Object CpuPercent -Descending |
                Select-Object -First 12
        )
        memory = @(
            $processes |
                Sort-Object PrivateMB -Descending |
                Select-Object -First 12
        )
        io = @(
            $processes |
                Sort-Object IoTotalMBps -Descending |
                Select-Object -First 12
        )
        gpu = @(
            $processes |
                Where-Object { $_.GpuPercent -gt 0 -or $_.GpuMemoryMB -gt 0 } |
                Sort-Object `
                    @{ Expression = 'GpuPercent'; Descending = $true },
                    @{ Expression = 'GpuMemoryMB'; Descending = $true } |
                Select-Object -First 12
        )
        network = @(
            $processes |
                Where-Object EstablishedConnections -gt 0 |
                Sort-Object EstablishedConnections -Descending |
                Select-Object -First 12
        )
    }

    $metrics = [pscustomobject]@{
        Timestamp = (Get-Date).ToString('o')
        CpuAvailable = $cpuAvailable
        MemoryAvailable = $memoryAvailable
        DiskActivityAvailable = $diskTotal.Count -gt 0
        NetworkAvailable = $networkRows.Count -gt 0
        CpuPercent = [math]::Round($cpuPercent, 1)
        AvailableMB = [math]::Round($availableMB, 1)
        AvailablePercent = [math]::Round($availablePercent, 1)
        CommitPercent = [math]::Round($commitPercent, 1)
        PagesOutputPerSec = [math]::Round($pagesOutputPerSec, 1)
        DiskPercent = [math]::Round($diskPercent, 1)
        DiskQueue = [math]::Round($diskQueue, 2)
        DiskLatencyMs = $diskLatencyMs
        DiskReadMBps = [math]::Round($diskReadMBps, 2)
        DiskWriteMBps = [math]::Round($diskWriteMBps, 2)
        LowestFreeGB = $lowestFreeGB
        GpuPercent = [double]$gpuEngineData.OverallPercent
        GpuEngine = [string]$gpuEngineData.OverallEngine
        GpuDedicatedMB = [math]::Round([double]$gpuDedicatedBytes / 1MB, 1)
        GpuSharedMB = [math]::Round([double]$gpuSharedBytes / 1MB, 1)
        NetworkPercent = [math]::Round($networkPercent, 1)
        NetworkMBps = [math]::Round($networkBytesPerSec / 1MB, 2)
    }

    $historyForAssessment = @($State.History)
    $assessment = Get-PressureAssessment `
        -Metrics $metrics `
        -History $historyForAssessment `
        -GpuAvailable ([bool]$State.Capabilities.GpuEngine)
    $cliSessions = Get-PressureCliSessions `
        -Processes $processes `
        -MetadataByPid $State.MetadataByPid `
        -DashboardProcessId $State.DashboardProcessId `
        -Assessment $assessment `
        -Metrics $metrics `
        -TotalPhysicalMemoryBytes $State.TotalPhysicalMemoryBytes
    $terminalSummary = Get-PressureTerminalSummary `
        -Processes $processes `
        -CliSessions $cliSessions `
        -Assessment $assessment
    $antimalwareProcesses = @(
        $processes | Where-Object {
            (Get-PressureBaseProcessName -Name ([string]$_.Name)) -eq 'msmpeng'
        }
    )
    $defender = Get-PressureDefenderState `
        -Status $State.DefenderStatus `
        -Preference $State.DefenderPreference `
        -EngineIoMBps ([double](($antimalwareProcesses | Measure-Object IoTotalMBps -Sum).Sum)) `
        -EngineCpuPercent ([double](($antimalwareProcesses | Measure-Object CpuPercent -Sum).Sum)) `
        -CliHomes @($State.CliHomes) `
        -ScanProcess $State.DefenderScanProcess
    $baseInsights = Get-PressureInsights `
        -Assessment $assessment `
        -Metrics $metrics `
        -Consumers $consumers `
        -Defender $defender
    $terminalInsight = if ($terminalSummary.Detected -and $terminalSummary.Level -ge 1) {
        [pscustomobject]@{
            Resource = 'terminal'
            Level = [int]$terminalSummary.Level
            Title = "Árvores do Windows Terminal somam $($terminalSummary.PrivateGB) GB privados"
            Narrative = "$($terminalSummary.SessionCount) sessões e $($terminalSummary.ProcessCount) processos atribuídos. O host gráfico usa $($terminalSummary.HostPrivateMB) MB; o restante pertence às árvores de shells e CLIs."
            Evidence = 'Atribuição pela cadeia de PID pai validada pelo horário de criação; linhas de comando brutas não são expostas.'
            AttributionConfidence = 'alta'
            CauseConfidence = 'média'
        }
    } else {
        $null
    }
    $insights = @(
        @($terminalInsight) + @($baseInsights) |
            Where-Object { $null -ne $_ } |
            Select-Object -First 5
    )

    $State.History.Add($metrics)
    while ($State.History.Count -gt 120) {
        $State.History.RemoveAt(0)
    }

    $collectionMs = ((Get-Date) - $startedAt).TotalMilliseconds
    $State.CollectionCount = [int]$State.CollectionCount + 1
    $State.CollectionMsTotal = [double]$State.CollectionMsTotal + $collectionMs
    if ($collectionMs -gt [double]$State.CollectionMsMax) {
        $State.CollectionMsMax = $collectionMs
    }
    $selfCost = Get-PressureSelfCost `
        -ProcessRows $processRows `
        -DashboardProcessId ([uint32]$State.DashboardProcessId) `
        -LastCollectionMs $collectionMs `
        -CollectionCount ([int]$State.CollectionCount) `
        -CollectionMsTotal ([double]$State.CollectionMsTotal) `
        -CollectionMsMax ([double]$State.CollectionMsMax) `
        -LogicalProcessorCount ([int]$State.LogicalProcessorCount) `
        -RefreshSeconds ([int]$State.RefreshSeconds)

    # A cadência muda depois de medir o custo: o percentual de ciclo acima se
    # refere ao intervalo que estava valendo durante esta coleta.
    if ($State.AdaptiveCadence) {
        $State.RefreshSeconds = Get-PressureAdaptiveRefreshSeconds `
            -Level ([int]$assessment.Level) `
            -Current ([int]$State.RefreshSeconds) `
            -Min ([int]$State.MinRefreshSeconds) `
            -Max ([int]$State.MaxRefreshSeconds)
    }
    $State.CadenceRelaxed = [int]$State.RefreshSeconds -gt [int]$State.MinRefreshSeconds

    [pscustomobject]@{
        SchemaVersion = 2
        GeneratedAt = (Get-Date).ToString('o')
        CollectionDurationMs = [math]::Round($collectionMs, 0)
        RefreshSeconds = $State.RefreshSeconds
        Cadence = [pscustomobject]@{
            Adaptive = [bool]$State.AdaptiveCadence
            Relaxed = [bool]$State.CadenceRelaxed
            MinSeconds = [int]$State.MinRefreshSeconds
            MaxSeconds = [int]$State.MaxRefreshSeconds
        }
        SelfCost = $selfCost
        Overall = [pscustomobject]@{
            Level = $assessment.Level
            State = $assessment.State
            Score = $assessment.Score
            DominantResource = $assessment.DominantResource
            Summary = $assessment.Summary
        }
        Resources = $assessment.Resources
        Metrics = $metrics
        Consumers = $consumers
        TerminalSummary = $terminalSummary
        CliSessions = @($cliSessions)
        Insights = @($insights)
        Defender = $defender
        ScanCost = (Update-PressureScanCostCache -State $State -Defender $defender)
        Docker = $State.DockerState
        PhysicalDisks = $physicalDisks
        Volumes = @($State.DiskCapacities)
        Capabilities = Get-PressureCapabilities -State $State
        Actions = [pscustomobject]@{
            ProcessTerminationEnabled = [bool]$State.ProcessTerminationEnabled
            RequiresExplicitConfirmation = $true
            DashboardSelfProtection = $true
        }
        Warnings = @($warnings)
        Privacy = [pscustomobject]@{
            RawCommandLinesExposed = $false
            ExecutablePathsExposed = $false
            RemoteAddressesExposed = $false
        }
    }
}
