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

        [ValidateRange(2, 600)]
        [int]$MaxRefreshSeconds = 30,

        [switch]$FixedCadence,

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
        ConnectionCountsByPid = @{}
        ConnectionRefreshAt = (Get-Date).AddSeconds(10)
        DiskCapacities = @()
        DiskCapacityRefreshAt = [datetime]::MinValue
        PreviousDiskRawByName = @{}
        History = [Collections.Generic.List[object]]::new()
        CollectionCount = 0
        CollectionMsTotal = 0.0
        CollectionMsMax = 0.0
        DefenderRefreshSeconds = $DefenderRefreshSeconds
        DefenderRefreshAt = [datetime]::MinValue
        DefenderStatus = $null
        DefenderPreference = $null
        Capabilities = [ordered]@{
            GpuEngine = $gpuEngineAvailable
            GpuProcessMemory = $gpuMemoryAvailable
            GpuAdapterMemory = $gpuAdapterMemoryAvailable
            TcpConnections = $tcpConnectionAvailable
            HttpListener = [System.Net.HttpListener]::IsSupported
            VendorHardwareSensors = $false
            EtwRootCause = $false
            Defender = $false
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
    [CmdletBinding()]
    param()

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
        $context = Get-PressureProcessContext `
            -Name ([string]$process.Name) `
            -ParentName $parentName `
            -CommandLine ([string]$process.CommandLine) `
            -ServiceNames $serviceNames
        $cliIdentity = Get-PressureCliIdentity `
            -Name ([string]$process.Name) `
            -CommandLine ([string]$process.CommandLine)
        $creationDate = if ($null -ne $process.CreationDate) {
            [datetime]$process.CreationDate
        } else {
            [datetime]::MinValue
        }

        $metadata[$pidKey] = [pscustomobject]@{
            Id = [uint32]$process.ProcessId
            Name = [string]$process.Name
            ParentId = [uint32]$process.ParentProcessId
            ParentName = $parentName
            CreationDate = $creationDate
            SessionId = [uint32]$process.SessionId
            Category = $context.Category
            Purpose = $context.Purpose
            ServiceNames = $serviceNames
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
        $State.MetadataByPid = Get-PressureProcessMetadataSnapshot
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

    $cpuPercent = [double]$Metrics.CpuPercent
    $cpuLevel = if ($cpuPercent -ge 85 -and $cpuStreak -ge 3) {
        3
    } elseif ($cpuPercent -ge 85) {
        2
    } elseif ($cpuPercent -ge 65) {
        1
    } else {
        0
    }
    $cpuBasis = if ($cpuStreak -ge 3) {
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
        -Score $cpuPercent `
        -Value ([math]::Round($cpuPercent, 1)) `
        -Unit '%' `
        -Detail "$([math]::Round($cpuPercent, 1))% da capacidade total" `
        -Basis $cpuBasis

    $availableMB = [double]$Metrics.AvailableMB
    $availableGB = $availableMB / 1024
    $availablePercent = [double]$Metrics.AvailablePercent
    $commitPercent = [double]$Metrics.CommitPercent
    $memoryUsedPercent = [math]::Min(100, [math]::Max(0, 100 - $availablePercent))
    $memoryLevel = if ($availableMB -lt 750 -or $commitPercent -ge 97) {
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
    $memoryScore = [math]::Max(
        $commitPercent,
        [math]::Min(100, 100 - (100 * $availableGB / 8))
    )
    $memory = New-PressureResourceAssessment `
        -Key 'memory' `
        -Label 'Memória' `
        -Level $memoryLevel `
        -Score $memoryScore `
        -Value ([math]::Round($memoryUsedPercent, 1)) `
        -Unit '%' `
        -Detail "$([math]::Round($availableGB, 2)) GB disponíveis • commit $([math]::Round($commitPercent, 1))%" `
        -Basis 'Disponível mede RAM reutilizável; commit mede a reserva total garantida por RAM ou page file.'

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
    $diskLevel = 0
    $diskBasis = 'Tempo ativo, fila, latência e espaço livre dos volumes locais.'
    if ($null -ne $lowestFreeGB -and $lowestFreeGB -lt 0.5) {
        $diskLevel = 4
        $diskBasis = 'Há um volume local com menos de 500 MB livres.'
    } elseif ($null -ne $lowestFreeGB -and $lowestFreeGB -lt 2) {
        $diskLevel = 3
        $diskBasis = 'Há um volume local com menos de 2 GB livres.'
    } elseif ($null -ne $lowestFreeGB -and $lowestFreeGB -lt 5) {
        $diskLevel = 2
        $diskBasis = 'Há um volume local com menos de 5 GB livres.'
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
    $diskScore = [math]::Max(
        [math]::Min(100, $diskPercent),
        [math]::Max($diskLatencyScore, $diskCapacityScore)
    )
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
        -Value ([math]::Round([math]::Min(100, $diskPercent), 1)) `
        -Unit '%' `
        -Detail "$latencyDetail • fila $([math]::Round([double]$Metrics.DiskQueue, 2))" `
        -Basis $diskBasis

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

    $networkPercent = [double]$Metrics.NetworkPercent
    $networkLevel = if ($networkPercent -ge 80 -and $networkStreak -ge 3) {
        3
    } elseif ($networkPercent -ge 80) {
        2
    } elseif ($networkPercent -ge 50) {
        1
    } else {
        0
    }
    $networkBasis = if ($networkStreak -ge 3) {
        "Interface mais ocupada acima de 80% por $networkStreak ciclos."
    } else {
        'Uso comparado à velocidade nominal informada pelo adaptador.'
    }
    $network = New-PressureResourceAssessment `
        -Key 'network' `
        -Label 'Rede' `
        -Level $networkLevel `
        -Score $networkPercent `
        -Value ([math]::Round($networkPercent, 1)) `
        -Unit '%' `
        -Detail "$([math]::Round([double]$Metrics.NetworkMBps, 2)) MB/s agregados" `
        -Basis $networkBasis

    $resources = @($cpu, $memory, $disk, $gpu, $network)
    $dominant = @(
        $resources |
            Where-Object Available |
            Sort-Object `
                @{ Expression = 'Level'; Descending = $true },
                @{ Expression = 'Score'; Descending = $true } |
            Select-Object -First 1
    )[0]
    $overallLevel = [int]$dominant.Level
    $overallSummary = if ($overallLevel -eq 0) {
        'Nenhum gargalo sustentado foi detectado nesta amostra.'
    } else {
        "$($dominant.Label) é a pressão dominante: $($dominant.Basis)"
    }

    [pscustomobject]@{
        Level = $overallLevel
        State = Get-PressureLevelName -Level $overallLevel
        Score = [math]::Round([double]$dominant.Score, 1)
        DominantResource = $dominant.Key
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
    [pscustomobject]@{
        # Aqui a exclusão de node.exe não ajuda: quem escreve o estado é o
        # binário próprio de cada CLI, que não é node.exe.
        Key = 'cli-state'
        Label = 'estado das CLIs de IA'
        PathPatterns = @('.claude', '.codex', '.gemini', '.grok')
        ProcessPatterns = @('claude.exe', 'codex.exe')
    }
)

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
        [datetime]$Now = (Get-Date)
    )

    if ($null -eq $Status -and $null -eq $Preference) {
        return [pscustomobject]@{
            Available = $false
            Detail = 'O namespace do antimalware não respondeu nesta máquina.'
            RealtimeEnabled = $null
            ScanInProgress = $false
            ScanStartedAt = $null
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
        }
    }

    $fullScanStart = if ($null -ne $Status) { $Status.FullScanStartTime } else { $null }
    $fullScanEnd = if ($null -ne $Status) { $Status.FullScanEndTime } else { $null }
    $scanInProgress = (
        $null -ne $fullScanStart -and
        (
            $null -eq $fullScanEnd -or
            [datetime]$fullScanStart -gt [datetime]$fullScanEnd
        )
    )

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
        ScanStartedAt = if ($scanInProgress -and $null -ne $fullScanStart) {
            ([datetime]$fullScanStart).ToString('yyyy-MM-dd HH:mm')
        } else {
            $null
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
                FullScanEndTime, QuickScanStartTime, QuickScanEndTime
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
    $State.Capabilities.Defender = ($null -ne $status -or $null -ne $preference)
    $State.DefenderRefreshAt = $now.AddSeconds($State.DefenderRefreshSeconds)
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

        [datetime]$Now = (Get-Date),

        [switch]$Disabled
    )

    [pscustomobject]@{
        Directory = [IO.Path]::GetFullPath($Directory)
        Enabled = -not [bool]$Disabled
        RetentionDays = $RetentionDays
        MaxBytes = [double]$MaxMB * 1MB
        FlushSeconds = $FlushSeconds
        Buffer = [Collections.Generic.List[string]]::new()
        NextFlushAt = $Now.AddSeconds($FlushSeconds)
        NextRetentionAt = [datetime]::MinValue
        PendingCleanup = @()
        WrittenLines = 0
        LastError = ''
    }
}

function Get-PressureHistoryFilePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Writer,
        [datetime]$Now = (Get-Date)
    )

    Join-Path $Writer.Directory ("pressure_{0:yyyy-MM-dd}.jsonl" -f $Now)
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

    $currentName = ("pressure_{0:yyyy-MM-dd}.jsonl" -f $Now)
    $expired = [Collections.Generic.List[object]]::new()
    $expiredKeys = @{}
    $cutoff = $Now.AddDays(-$RetentionDays)

    foreach ($file in $files) {
        if ($file.Name -eq $currentName) {
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
        if ($file.Name -eq $currentName -or $expiredKeys.ContainsKey($file.FullName)) {
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
        $Writer.Buffer.Clear()
        $Writer.WrittenLines = [int]$Writer.WrittenLines + $lines.Count
        $Writer.NextFlushAt = $Now.AddSeconds($Writer.FlushSeconds)
        $Writer.LastError = ''
    } catch {
        # Histórico é observabilidade, não missão crítica: falha de escrita não
        # pode derrubar o painel nem impedir a próxima coleta.
        $Writer.Buffer.Clear()
        $Writer.NextFlushAt = $Now.AddSeconds($Writer.FlushSeconds)
        $Writer.LastError = [string]$_.Exception.Message
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
                Win32_PerfFormattedData_PerfOS_Processor `
                -Property Name, PercentProcessorTime `
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

    $cpuTotal = @($cpuRows | Where-Object Name -eq '_Total' | Select-Object -First 1)
    $cpuPercent = if ($cpuTotal.Count -gt 0) {
        [double]$cpuTotal[0].PercentProcessorTime
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
        -EngineCpuPercent ([double](($antimalwareProcesses | Measure-Object CpuPercent -Sum).Sum))
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
