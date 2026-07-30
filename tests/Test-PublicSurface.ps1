<#
.SYNOPSIS
Valida a superficie publica do projeto sem alterar o sistema.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$failures = [Collections.Generic.List[string]]::new()
$checks = 0

function Assert-PublicCondition {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    $script:checks++
    if (-not $Condition) {
        $script:failures.Add($Message)
    }
}

$requiredPaths = @(
    '.gitattributes',
    '.gitignore',
    'README.md',
    'LICENSE',
    'SECURITY.md',
    'CONTRIBUTING.md',
    'AGENTS.md',
    'CLAUDE.md',
    'GEMINI.md',
    '.geminiignore',
    'docs\AI-CLI.md',
    'docs\MEMORY.md',
    'docs\PRESSURE-DASHBOARD.md',
    '.claude\settings.json',
    'scripts\collect-memory.ps1',
    'scripts\sync-cli-profiles.ps1',
    'scripts\perfis-cli.example.json',
    'scripts\lib\pressure-core.ps1',
    'scripts\start-pressure-dashboard.ps1',
    'scripts\stop-pressure-cli-session.ps1',
    'dashboard\pressure\index.html',
    'dashboard\pressure\styles.css',
    'dashboard\pressure\app.js',
    'tests\Test-PressureDashboard.ps1',
    'reports\.gitkeep',
    'quarantine\.gitkeep'
)
foreach ($relativePath in $requiredPaths) {
    Assert-PublicCondition `
        -Condition (Test-Path -LiteralPath (Join-Path $repoRoot $relativePath)) `
        -Message "Arquivo obrigatorio ausente: $relativePath"
}

$gitignore = [IO.File]::ReadAllText((Join-Path $repoRoot '.gitignore'))
foreach ($requiredIgnore in @(
    '/reports/*',
    '!/reports/.gitkeep',
    '/quarantine/*',
    '!/quarantine/.gitkeep',
    '/local/',
    '/.codex/',
    '/.gsd/',
    '/.agents/skills/gsd-*/'
)) {
    Assert-PublicCondition `
        -Condition $gitignore.Contains($requiredIgnore) `
        -Message "Regra ausente no .gitignore: $requiredIgnore"
}

$agentsPath = Join-Path $repoRoot 'AGENTS.md'
$agentsContent = [IO.File]::ReadAllText($agentsPath)
$claudeContent = [IO.File]::ReadAllText((Join-Path $repoRoot 'CLAUDE.md'))
$geminiContent = [IO.File]::ReadAllText((Join-Path $repoRoot 'GEMINI.md'))

Assert-PublicCondition `
    -Condition ($claudeContent -match '(?m)^@AGENTS\.md\s*$') `
    -Message 'CLAUDE.md deve importar AGENTS.md'
Assert-PublicCondition `
    -Condition ($geminiContent -match '(?m)^@\./AGENTS\.md\s*$') `
    -Message 'GEMINI.md deve importar AGENTS.md'
Assert-PublicCondition `
    -Condition (([IO.File]::ReadAllLines((Join-Path $repoRoot 'CLAUDE.md'))).Count -le 80) `
    -Message 'CLAUDE.md deve ser um adaptador curto, sem duplicar AGENTS.md'
Assert-PublicCondition `
    -Condition (([IO.File]::ReadAllLines((Join-Path $repoRoot 'GEMINI.md'))).Count -le 40) `
    -Message 'GEMINI.md deve ser um adaptador curto, sem duplicar AGENTS.md'

foreach ($cliName in @('codex', 'claude', 'gemini', 'grok')) {
    Assert-PublicCondition `
        -Condition $agentsContent.Contains(
            $cliName,
            [StringComparison]::OrdinalIgnoreCase
        ) `
        -Message "AGENTS.md nao protege ou documenta a CLI: $cliName"
}
foreach ($criticalRule in @('Stop-Process', 'taskkill', 'wsl --shutdown')) {
    Assert-PublicCondition `
        -Condition $agentsContent.Contains(
            $criticalRule,
            [StringComparison]::OrdinalIgnoreCase
        ) `
        -Message "AGENTS.md nao contem gate critico: $criticalRule"
}

$geminiIgnore = [IO.File]::ReadAllText((Join-Path $repoRoot '.geminiignore'))
foreach ($ignoredDirectory in @(
    '/reports/',
    '/quarantine/',
    '/local/',
    '/.codex/',
    '/.gsd/',
    '/.agents/skills/gsd-*/'
)) {
    Assert-PublicCondition `
        -Condition $geminiIgnore.Contains($ignoredDirectory) `
        -Message ".geminiignore nao protege: $ignoredDirectory"
}

$memoryScriptPath = Join-Path $repoRoot 'scripts\collect-memory.ps1'
$memoryScriptContent = [IO.File]::ReadAllText($memoryScriptPath)
foreach ($requiredMemoryMarker in @(
    'Win32_PerfFormattedData_PerfOS_Memory',
    'PercentCommittedBytesInUse',
    'PagesOutputPersec',
    'PrivateBytesGrowthMBPerMinute',
    'Id = 2004',
    'AutomaticallyInvoked = $false'
)) {
    Assert-PublicCondition `
        -Condition $memoryScriptContent.Contains($requiredMemoryMarker) `
        -Message "collect-memory.ps1 nao contem: $requiredMemoryMarker"
}
foreach ($protectedProcessName in @(
    'WindowsTerminal',
    'OpenConsole',
    'codex',
    'claude',
    'gemini',
    'grok',
    'opencode'
)) {
    Assert-PublicCondition `
        -Condition $memoryScriptContent.Contains($protectedProcessName) `
        -Message "collect-memory.ps1 nao observa a CLI/processo protegido: $protectedProcessName"
}

$monitorContent = [IO.File]::ReadAllText((Join-Path $repoRoot 'scripts\monitor-perf.ps1'))
Assert-PublicCondition `
    -Condition $monitorContent.Contains('PercentCommittedBytesInUse') `
    -Message 'monitor-perf.ps1 deve usar o percentual real do limite de commit'
Assert-PublicCondition `
    -Condition (-not $monitorContent.Contains('MemoryOnlyHostChangeGatePassed')) `
    -Message 'monitor-perf.ps1 nao deve declarar um gate de host sem a coleta completa'

$pressureServerContent = [IO.File]::ReadAllText(
    (Join-Path $repoRoot 'scripts\start-pressure-dashboard.ps1')
)
Assert-PublicCondition `
    -Condition $pressureServerContent.Contains('http://127.0.0.1:') `
    -Message 'Painel de pressao deve escutar explicitamente em 127.0.0.1'
Assert-PublicCondition `
    -Condition (-not $pressureServerContent.Contains('http://*:')) `
    -Message 'Painel de pressao nao pode escutar em wildcard'
Assert-PublicCondition `
    -Condition (-not $pressureServerContent.Contains('http://+:')) `
    -Message 'Painel de pressao nao pode usar wildcard forte'
Assert-PublicCondition `
    -Condition $pressureServerContent.Contains('GetContextAsync') `
    -Message 'Painel de pressao deve poder checar ciclo de vida enquanto espera requisicao'
Assert-PublicCondition `
    -Condition $pressureServerContent.Contains('Test-PressureParentAlive') `
    -Message 'Painel de pressao deve encerrar sozinho quando o processo pai desaparece'

$pressureCoreContent = [IO.File]::ReadAllText(
    (Join-Path $repoRoot 'scripts\lib\pressure-core.ps1')
)
foreach ($requiredPressureMarker in @(
    'Win32_PerfFormattedData_PerfOS_Processor',
    'Win32_PerfFormattedData_PerfOS_Memory',
    'Win32_PerfRawData_PerfDisk_PhysicalDisk',
    'GPUPerformanceCounters_GPUEngine',
    'RawCommandLinesExposed = $false',
    'Test-PressureProtectedProcess',
    'Get-PressureSelfCost',
    'WmiProviderAttributable = $false',
    'ConvertTo-PressureHistoryRecord',
    'Get-PressureHistoryExpired',
    'Get-PressureDefenderState',
    'Get-PressureNextScheduledScan',
    'Get-PressureAdaptiveRefreshSeconds',
    'Test-PressureExclusionCoverage',
    'Get-PressureCliHomeCandidates'
)) {
    Assert-PublicCondition `
        -Condition $pressureCoreContent.Contains($requiredPressureMarker) `
        -Message "Coletor do painel nao contem: $requiredPressureMarker"
}

$memoryGuideContent = [IO.File]::ReadAllText((Join-Path $repoRoot 'docs\MEMORY.md'))
foreach ($requiredGuideMarker in @(
    'Working Set',
    'Private Bytes',
    'Committed Bytes',
    'Pages Output/sec',
    'learn.microsoft.com'
)) {
    Assert-PublicCondition `
        -Condition $memoryGuideContent.Contains($requiredGuideMarker) `
        -Message "docs/MEMORY.md nao explica: $requiredGuideMarker"
}

$pressureGuideContent = [IO.File]::ReadAllText(
    (Join-Path $repoRoot 'docs\PRESSURE-DASHBOARD.md')
)
foreach ($requiredGuideMarker in @(
    '127.0.0.1',
    'WDDM',
    'correlação',
    'ETW',
    'learn.microsoft.com'
)) {
    Assert-PublicCondition `
        -Condition $pressureGuideContent.Contains($requiredGuideMarker) `
        -Message "docs/PRESSURE-DASHBOARD.md nao explica: $requiredGuideMarker"
}

$syncProfilesContent = [IO.File]::ReadAllText(
    (Join-Path $repoRoot 'scripts\sync-cli-profiles.ps1')
)
foreach ($requiredSyncMarker in @(
    '# >>> perfis-cli inicio',
    '# <<< perfis-cli fim',
    'Text.Encoding]::ASCII',
    'Get-AliasConflict',
    'Get-MapDrift',
    'ConvertTo-GeneratedPath',
    'Test-ProfileMap',
    'ReparsePoint',
    # Sem isto o perfil do PowerShell 7 fica com a variavel vazia em lugar de
    # remove-la, e a proxima invocacao herda um diretorio de estado errado.
    'NullString]::Value'
)) {
    Assert-PublicCondition `
        -Condition $syncProfilesContent.Contains($requiredSyncMarker) `
        -Message "Sincronizador de perfis nao contem: $requiredSyncMarker"
}
Assert-PublicCondition `
    -Condition (-not ($syncProfilesContent -match '(?m)^\s*\$MapPath\s*=\s*[''"]\w:')) `
    -Message 'Sincronizador de perfis nao pode ter caminho absoluto embutido'

$exampleMapContent = [IO.File]::ReadAllText(
    (Join-Path $repoRoot 'scripts\perfis-cli.example.json')
)
$exampleMap = $null
$exampleMapValid = $true
try {
    $exampleMap = $exampleMapContent | ConvertFrom-Json
} catch {
    $exampleMapValid = $false
}
Assert-PublicCondition `
    -Condition $exampleMapValid `
    -Message 'scripts/perfis-cli.example.json nao e JSON valido'
if ($exampleMapValid) {
    Assert-PublicCondition `
        -Condition (@($exampleMap.profiles).Count -gt 0) `
        -Message 'Exemplo de mapa de perfis esta vazio'
    # O exemplo e publico: nenhum caminho de conta real pode vazar nele.
    Assert-PublicCondition `
        -Condition (-not ($exampleMapContent -match '(?i)C:\\\\Users')) `
        -Message 'Exemplo de mapa de perfis contem caminho de usuario real'
}

$settingsPath = Join-Path $repoRoot '.claude\settings.json'
$settingsContent = [IO.File]::ReadAllText($settingsPath)
$settingsValid = $true
$settingsError = $null
try {
    $null = [IO.File]::ReadAllText($settingsPath) | ConvertFrom-Json
} catch {
    $settingsValid = $false
    $settingsError = $_.Exception.Message
}
Assert-PublicCondition `
    -Condition $settingsValid `
    -Message ".claude/settings.json invalido: $settingsError"
Assert-PublicCondition `
    -Condition ($settingsContent -match '(?i)Stop-Process \*grok\*') `
    -Message '.claude/settings.json nao protege o processo grok'
Assert-PublicCondition `
    -Condition ($settingsContent -match '(?i)taskkill \*grok\*') `
    -Message '.claude/settings.json nao protege grok contra taskkill'

$powerShellFiles = @(
    Get-ChildItem -LiteralPath (Join-Path $repoRoot 'scripts') `
        -Recurse -File -Filter '*.ps1'
    Get-ChildItem -LiteralPath (Join-Path $repoRoot 'tests') `
        -Recurse -File -Filter '*.ps1'
)

$mutatingCommands = @(
    'Remove-Item',
    'Stop-Process',
    'Stop-Service',
    'Set-Service',
    'Disable-ScheduledTask',
    'Remove-AppxPackage',
    'Remove-AppxProvisionedPackage',
    'Set-ItemProperty',
    'New-ItemProperty',
    'Remove-ItemProperty',
    'Checkpoint-Computer',
    'Enable-ComputerRestore',
    'Optimize-VHD',
    'Mount-VHD',
    'Dismount-VHD'
)
$approvedProcessTerminationScript = 'scripts\stop-pressure-cli-session.ps1'

foreach ($file in $powerShellFiles) {
    $relativePath = [IO.Path]::GetRelativePath($repoRoot, $file.FullName)
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        $file.FullName,
        [ref]$tokens,
        [ref]$parseErrors
    )

    Assert-PublicCondition `
        -Condition (@($parseErrors).Count -eq 0) `
        -Message "Erro de sintaxe PowerShell em $relativePath"

    $commands = @(
        $ast.FindAll(
            { param($node) $node -is [Management.Automation.Language.CommandAst] },
            $true
        ) |
            ForEach-Object { $_.GetCommandName() } |
            Where-Object { $_ } |
            Sort-Object -Unique
    )
    $dangerous = @($commands | Where-Object { $_ -in $mutatingCommands })
    $content = [IO.File]::ReadAllText($file.FullName)

    if ($dangerous.Count -gt 0) {
        $parameterNames = if ($ast.ParamBlock) {
            @($ast.ParamBlock.Parameters.Name.VariablePath.UserPath)
        } else {
            @()
        }
        Assert-PublicCondition `
            -Condition ($content -match 'SupportsShouldProcess') `
            -Message "$relativePath altera o sistema sem SupportsShouldProcess"
        Assert-PublicCondition `
            -Condition ('Execute' -in $parameterNames) `
            -Message "$relativePath altera o sistema sem switch -Execute"
        Assert-PublicCondition `
            -Condition ($content -match '\$PSCmdlet\.ShouldProcess') `
            -Message "$relativePath altera o sistema sem chamar ShouldProcess"
    }

    if ('Stop-Process' -in $commands) {
        Assert-PublicCondition `
            -Condition ($relativePath -eq $approvedProcessTerminationScript) `
            -Message "$relativePath nao e o executor nominal aprovado para encerrar processos"
        foreach ($requiredTerminationGuard in @(
            'ExpectedFingerprint',
            'ExpectedProcessCount',
            'AdditionalProtectedProcessIds',
            'Get-PressureCliTerminationDisposition',
            'Get-PressureProcessTreeMembers',
            '$PID'
        )) {
            Assert-PublicCondition `
                -Condition $content.Contains($requiredTerminationGuard) `
                -Message "$relativePath nao contem a trava de encerramento: $requiredTerminationGuard"
        }
    } else {
        Assert-PublicCondition `
            -Condition ($relativePath -ne $approvedProcessTerminationScript) `
            -Message "$approvedProcessTerminationScript deve conter o unico Stop-Process permitido"
    }
}

$publicFiles = [Collections.Generic.List[IO.FileInfo]]::new()
foreach ($directory in @('scripts', '.claude', '.github', 'dashboard', 'docs', 'tests')) {
    $path = Join-Path $repoRoot $directory
    if (Test-Path -LiteralPath $path) {
        foreach ($file in Get-ChildItem -LiteralPath $path -Recurse -File) {
            $publicFiles.Add($file)
        }
    }
}
foreach ($name in @(
    '.gitattributes',
    '.gitignore',
    'README.md',
    'LICENSE',
    'SECURITY.md',
    'CONTRIBUTING.md',
    'AGENTS.md',
    'CLAUDE.md',
    'GEMINI.md',
    '.geminiignore'
)) {
    $publicFiles.Add((Get-Item -LiteralPath (Join-Path $repoRoot $name)))
}

$oldCompanyName = ('im' + 'plant' + 'anet')
$oldUserName = ('mi' + 'ler')
$oldProjectName = ('tri' + 'lha')
$bannedLiterals = @($oldCompanyName, $oldUserName, $oldProjectName)
$concreteUserPath = [regex]::new(
    '(?i)\b[A-Z]:\\Users\\(?!<user>)[A-Za-z0-9._-]+\\'
)
$credentialPatterns = @(
    [regex]::new('(?i)(?<![A-Za-z0-9_])g' + 'hp_[A-Za-z0-9]{20,}'),
    [regex]::new('(?i)(?<![A-Za-z0-9_])github_' + 'pat_[A-Za-z0-9_]{20,}'),
    [regex]::new('(?i)(?<![A-Za-z0-9])s' + 'k-[A-Za-z0-9_-]{20,}'),
    [regex]::new('(?i)(?<![A-Za-z0-9])x' + 'ai-[A-Za-z0-9_-]{20,}'),
    [regex]::new('(?<![A-Za-z0-9])A' + 'Iza[0-9A-Za-z_-]{30,}'),
    [regex]::new('(?i)-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----')
)

foreach ($file in $publicFiles) {
    $relativePath = [IO.Path]::GetRelativePath($repoRoot, $file.FullName)
    $content = [IO.File]::ReadAllText($file.FullName)

    foreach ($literal in $bannedLiterals) {
        Assert-PublicCondition `
            -Condition (-not $content.Contains(
                $literal,
                [StringComparison]::OrdinalIgnoreCase
            )) `
            -Message "Referencia local/corporativa em $relativePath"
    }
    Assert-PublicCondition `
        -Condition (-not $concreteUserPath.IsMatch($content)) `
        -Message "Perfil de usuario concreto em $relativePath"
    foreach ($pattern in $credentialPatterns) {
        Assert-PublicCondition `
            -Condition (-not $pattern.IsMatch($content)) `
            -Message "Possivel credencial em $relativePath"
    }
}

if (Test-Path -LiteralPath (Join-Path $repoRoot '.git')) {
    $trackedLocalData = @(
        git -C $repoRoot ls-files -- reports quarantine local 2>$null |
            Where-Object { $_ -notin @('reports/.gitkeep', 'quarantine/.gitkeep') }
    )
    Assert-PublicCondition `
        -Condition ($trackedLocalData.Count -eq 0) `
        -Message 'Git contem relatorios, quarentena ou arquivos locais'
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
    PowerShellFiles = $powerShellFiles.Count
    PublicFiles = $publicFiles.Count
} | ConvertTo-Json -Depth 3
