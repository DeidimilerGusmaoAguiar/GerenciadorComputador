<#
.SYNOPSIS
Remove residuo de teste antigo do %TEMP%, feito para rodar sem supervisao.

.DESCRIPTION
E a acao da tarefa agendada de install-temp-sweeper.ps1. Os grupos de nomes vem
de um arquivo local (local\temp-sweeper.json por padrao), porque os prefixos
variam de maquina para maquina; docs\temp-sweeper.example.json mostra o formato.
A configuracao declara o host e e recusada em outra maquina.

Para cada grupo, gera um manifesto novo com measure-stale-directories.ps1 e o
entrega a remove-stale-directories.ps1, que revalida cada pasta na hora. Grupo
com somenteAntesDoBoot (nomes aleatorios como tmpXXXXXXXX) so remove pasta cuja
ultima escrita e anterior ao ultimo boot, porque nenhum processo vivo conhece
aquele nome. A idade minima nunca fica abaixo de um dia.

Antes de remover, confere o gate do AGENTS.md (disco, RAM, commit e Windows
Terminal) e a ausencia de build ou teste rodando; com qualquer um deles, sai sem
remover e tenta de novo na proxima execucao. Entre um grupo e outro, interrompe
se um processo protegido sumir. Duas instancias nao rodam juntas.

Cada execucao grava uma linha em reports\temp-sweeper\historico.jsonl: o que
removeu e quantas pastas nasceram por prefixo desde a execucao anterior. E essa
taxa que mostra se a correcao na origem funcionou; report-temp-sweeper.ps1 le o
historico.

Sem -Execute, apenas simula e nao conta para o intervalo entre execucoes.

.EXAMPLE
pwsh -NoProfile -File .\scripts\sweep-temp-residue.ps1

.EXAMPLE
pwsh -NoProfile -File .\scripts\sweep-temp-residue.ps1 -Execute -MinHoursBetweenRuns 0
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [AllowEmptyString()]
    [string]$ConfigPath = '',

    [AllowEmptyString()]
    [string]$Root = '',

    [switch]$Execute,

    # A tarefa repete a cada poucas horas para cobrir abortos; depois de uma
    # execucao bem-sucedida, as seguintes saem sem fazer nada ate passar este
    # intervalo.
    [ValidateRange(0, 168)]
    [double]$MinHoursBetweenRuns = 20,

    [AllowEmptyString()]
    [string]$StateDirectory = '',

    [ValidateRange(1, 365)]
    [int]$RetentionDays = 14
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $ConfigPath) { $ConfigPath = Join-Path $repoRoot 'local\temp-sweeper.json' }
if (-not $Root) { $Root = $env:TEMP }
if (-not $StateDirectory) { $StateDirectory = Join-Path $repoRoot 'reports\temp-sweeper' }
$ConfigPath = [IO.Path]::GetFullPath($ConfigPath)
$Root = [IO.Path]::GetFullPath($Root).TrimEnd('\')
$StateDirectory = [IO.Path]::GetFullPath($StateDirectory)
$historyPath = Join-Path $StateDirectory 'historico.jsonl'
$runsDirectory = Join-Path $StateDirectory 'execucoes'
$measureScript = Join-Path $PSScriptRoot 'measure-stale-directories.ps1'
$removeScript = Join-Path $PSScriptRoot 'remove-stale-directories.ps1'

function Get-Setting {
    param($Object, [Parameter(Mandatory)][string]$Name, $Default)

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

# --- Configuracao -----------------------------------------------------------

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "Configuracao nao encontrada: $ConfigPath. Copie docs\temp-sweeper.example.json para local\temp-sweeper.json e revise host e grupos."
}
if (-not (Test-Path -LiteralPath $Root -PathType Container)) { throw "Raiz nao encontrada: $Root" }
if ($Root.Length -le 3) { throw "Raiz de volume nao e aceita: $Root" }

$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$configHost = [string](Get-Setting $config 'host' '')
if ($configHost -ne $env:COMPUTERNAME) {
    throw "A configuracao e do host '$configHost', e esta maquina e '$env:COMPUTERNAME'. Revise local\temp-sweeper.json antes de usar aqui."
}
$groups = @(Get-Setting $config 'grupos' @())
if ($groups.Count -eq 0) { throw 'A configuracao nao declara nenhum grupo.' }
$exclude = @(Get-Setting $config 'exclude' @())
$maxPerManifest = [int](Get-Setting $config 'maxPorManifesto' 120000)
$minRamGB = [double](Get-Setting $config 'ramMinimaGB' 4)
$maxCommitPct = [double](Get-Setting $config 'commitMaximoPct' 80)
$blockingNames = @(Get-Setting $config 'processosBloqueantes' @('devenv', 'MSBuild', 'dotnet', 'VBCSCompiler'))
$blockingPatterns = @(Get-Setting $config 'linhaDeComandoBloqueante' @('\bpytest\b', '-m\s+unittest\b', 'mutmut', 'mutante'))
foreach ($group in $groups) {
    $groupName = [string](Get-Setting $group 'nome' '')
    if ($groupName -notmatch '^[A-Za-z0-9-]+$') { throw "Nome de grupo invalido: '$groupName' (use letras, digitos e hifen)." }
    if (@(Get-Setting $group 'include' @()).Count -eq 0) { throw "O grupo '$groupName' nao declara include." }
    foreach ($pattern in @(Get-Setting $group 'include' @()) + $exclude + $blockingPatterns) { $null = [regex]::new($pattern) }
}

# --- Instancia unica e intervalo ------------------------------------------

New-Item -ItemType Directory -Force -Path $runsDirectory | Out-Null
try {
    $lock = [IO.File]::Open((Join-Path $StateDirectory '.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
} catch {
    if ($_.Exception -is [IO.IOException] -or $_.Exception.InnerException -is [IO.IOException]) {
        Write-Output 'Outra varredura esta em execucao; saindo sem fazer nada.'
        exit 0
    }
    throw
}

try {
    $history = @(if (Test-Path -LiteralPath $historyPath) {
        Get-Content -LiteralPath $historyPath | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json }
    })
    $lastExecute = $history | Where-Object { $_.modo -eq 'execute' } | Select-Object -Last 1
    $lastSuccess = $history | Where-Object { $_.modo -eq 'execute' -and $_.status -eq 'ok' } | Select-Object -Last 1
    $start = Get-Date
    if ($Execute -and $null -ne $lastSuccess -and $MinHoursBetweenRuns -gt 0) {
        $hours = ($start - [datetime]$lastSuccess.inicio).TotalHours
        if ($hours -lt $MinHoursBetweenRuns) {
            Write-Output ('Ultima varredura bem-sucedida ha {0:N1} h (minimo {1} h); saindo sem fazer nada.' -f $hours, $MinHoursBetweenRuns)
            exit 0
        }
    }

    # --- Funcoes de verificacao ---------------------------------------------

    function Get-Gate {
        $memory = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory
        $wtPrivate = [int64]0
        $wtWorkingSet = [int64]0
        foreach ($process in @(Get-Process WindowsTerminal -ErrorAction SilentlyContinue)) {
            $wtPrivate = [math]::Max($wtPrivate, $process.PrivateMemorySize64)
            $wtWorkingSet = [math]::Max($wtWorkingSet, $process.WorkingSet64)
        }
        return [ordered]@{
            livreGB = [math]::Round([IO.DriveInfo]::new([IO.Path]::GetPathRoot($Root)).AvailableFreeSpace / 1GB, 2)
            ramGB = [math]::Round([double]$memory.AvailableBytes / 1GB, 2)
            commitPct = [math]::Round([double]$memory.PercentCommittedBytesInUse, 1)
            wtPrivadoGB = [math]::Round($wtPrivate / 1GB, 2)
            wtWorkingSetGB = [math]::Round($wtWorkingSet / 1GB, 2)
        }
    }

    function Get-GateFailure {
        param([Parameter(Mandatory)]$Gate)

        if ($Gate.livreGB -lt 5) { return "menos de 5 GB livres ($($Gate.livreGB) GB)" }
        if ($Gate.ramGB -lt $minRamGB) { return "RAM disponivel abaixo de $minRamGB GB ($($Gate.ramGB) GB)" }
        if ($Gate.commitPct -ge $maxCommitPct) { return "commit em $($Gate.commitPct)%" }
        if ($Gate.wtPrivadoGB -ge 4 -or $Gate.wtWorkingSetGB -ge 2) { return 'Windows Terminal acima do limite de memoria' }
        return $null
    }

    function Get-BlockingProcesses {
        $found = [Collections.Generic.List[string]]::new()
        foreach ($process in Get-CimInstance Win32_Process -Property ProcessId, Name, CommandLine) {
            if ($process.ProcessId -eq $PID) { continue }
            $baseName = [IO.Path]::GetFileNameWithoutExtension([string]$process.Name)
            $commandLine = [string]$process.CommandLine
            if (($blockingNames -contains $baseName) -or
                ($commandLine -and ($blockingPatterns | Where-Object { $commandLine -match $_ }))) {
                $found.Add("$($process.Name):$($process.ProcessId)")
            }
        }
        return , $found
    }

    # Hospedeiros do Terminal, CLIs e shells das abas vivos ha mais de 15 min.
    function Get-ProtectedProcesses {
        $hostNames = @('WindowsTerminal.exe', 'OpenConsole.exe')
        $cliNames = @('claude.exe', 'codex.exe', 'gemini.exe', 'grok.exe', 'opencode.exe', 'wsl.exe')
        $shellNames = @('pwsh.exe', 'powershell.exe', 'cmd.exe', 'bash.exe')
        $all = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name, CreationDate)
        $byId = @{}
        foreach ($process in $all) { $byId[[int]$process.ProcessId] = $process }
        $cutoff = (Get-Date).AddMinutes(-15)
        return @(foreach ($process in $all) {
            $parent = $byId[[int]$process.ParentProcessId]
            $isTabShell = ($process.Name -in $shellNames) -and $null -ne $parent -and ($parent.Name -in $hostNames)
            if ((($process.Name -in $hostNames) -or ($process.Name -in $cliNames) -or $isTabShell) -and
                $process.CreationDate -lt $cutoff) {
                [pscustomobject]@{ Id = [int]$process.ProcessId; Name = $process.Name; Created = $process.CreationDate }
            }
        })
    }

    function Get-MissingProtected {
        param([object[]]$Baseline)

        $alive = @{}
        foreach ($process in Get-CimInstance Win32_Process -Property ProcessId, CreationDate) {
            $alive[[int]$process.ProcessId] = $process.CreationDate
        }
        return @($Baseline | Where-Object { -not $alive.ContainsKey($_.Id) -or $alive[$_.Id] -ne $_.Created } |
            ForEach-Object { "$($_.Name):$($_.Id)" })
    }

    function Get-PrefixKey {
        param([Parameter(Mandatory)][string]$Name)

        if ($Name -match '^tmp[a-z0-9_]{8}$') { return 'tmp*' }
        if ($Name -match '^[a-z0-9]{8}\.[a-z0-9]{3}$') { return '8.3' }
        if ($Name -match '^([a-z][a-z0-9]*-(?:[a-z][a-z0-9]*-)?)') { return $Matches[1].ToLowerInvariant() }
        return 'outros'
    }

    # --- Medicao de criacao (antes de qualquer remocao) ----------------------

    $windowStart = if ($null -ne $lastExecute) { [datetime]$lastExecute.inicio } else { $start.AddDays(-1) }
    $created = @{}
    $entriesBefore = 0
    foreach ($dir in [IO.DirectoryInfo]::new($Root).EnumerateDirectories()) {
        $entriesBefore++
        if ($dir.CreationTime -ge $windowStart) {
            $key = Get-PrefixKey $dir.Name
            $created[$key] = 1 + [int]$created[$key]
        }
    }
    $createdOrdered = [ordered]@{}
    $created.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { $createdOrdered[$_.Key] = $_.Value }

    $record = [ordered]@{
        inicio = $start.ToString('o')
        fim = $null
        modo = if ($Execute) { 'execute' } else { 'dry-run' }
        status = 'ok'
        motivo = $null
        host = $env:COMPUTERNAME
        raiz = $Root
        entradasAntes = $entriesBefore
        entradasDepois = $null
        janelaInicio = $windowStart.ToString('o')
        horasJanela = [math]::Round(($start - $windowStart).TotalHours, 2)
        criadasNaJanela = $createdOrdered
        criadasTotal = [int](($created.Values | Measure-Object -Sum).Sum)
        removidas = 0
        gate = Get-Gate
        grupos = [Collections.Generic.List[object]]::new()
    }

    # --- Gate e processos -----------------------------------------------------

    $gateFailure = Get-GateFailure $record.gate
    $blocking = Get-BlockingProcesses
    if ($gateFailure) {
        $record.status = 'gate'
        $record.motivo = $gateFailure
    } elseif ($blocking.Count -gt 0) {
        $record.status = 'bloqueado'
        $record.motivo = "build ou teste rodando: $(($blocking | Select-Object -First 10) -join ', ')"
    } else {
        $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
        $stamp = $start.ToString('yyyy-MM-dd_HHmmss')
        $runDirectory = Join-Path $runsDirectory $stamp
        $protected = @(Get-ProtectedProcesses)

        foreach ($group in $groups) {
            $missing = @(Get-MissingProtected $protected)
            if ($missing.Count -gt 0) {
                $record.status = 'protegidoSumiu'
                $record.motivo = "processo protegido sumiu: $($missing -join ', ')"
                break
            }
            $groupName = [string]$group.nome
            $minAge = [double](Get-Setting $group 'idadeMinimaDias' 1)
            if ([bool](Get-Setting $group 'somenteAntesDoBoot' $false)) {
                $minAge = [math]::Ceiling((($start - $boot).TotalDays + 0.01) * 100) / 100
            }
            $minAge = [math]::Max(1, $minAge)

            $manifestPath = (& $measureScript -Root $Root -Include @($group.include) -Exclude $exclude `
                -MinAgeDays $minAge -SkipSize -Label $groupName -Stamp $stamp -OutDir $runDirectory 6>$null) |
                Select-Object -Last 1
            $selectedCount = [int](Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json).selectedCount
            $result = [ordered]@{ nome = $groupName; idadeMinimaDias = $minAge; selecionadas = $selectedCount; status = 'ok' }

            if ($selectedCount -eq 0) {
                $result.status = 'vazio'
            } elseif ($selectedCount -gt $maxPerManifest) {
                # Manifesto grande demais pesa na memoria (o de 482 mil itens foi encerrado por
                # falta dela em 17/10/2026). Acumulo assim pede limpeza assistida em lotes.
                $result.status = 'excesso'
                $record.status = 'excesso'
                $record.motivo = "grupo '$groupName' com $selectedCount pastas, acima de $maxPerManifest"
            } else {
                $removeParameters = @{
                    ManifestPath = $manifestPath
                    ExpectedRoot = $Root
                    BlockingProcessName = $blockingNames
                    BlockingCommandLinePattern = $blockingPatterns
                    LogPath = Join-Path $runDirectory "remocao_$groupName.jsonl"
                }
                if ($Execute) { $removeParameters.Execute = $true; $removeParameters.Confirm = $false }
                $summary = (& $removeScript @removeParameters) -join "`n" | ConvertFrom-Json
                foreach ($name in 'planned', 'deleted', 'missing', 'blocked', 'tooRecent', 'marker', 'inUse', 'reparsePoint', 'failed') {
                    $result[$name] = [int]$summary.$name
                }
                $result.liberadoGB = [math]::Round([double]$summary.freeBytesDelta / 1GB, 3)
                $record.removidas += $result.deleted
                if ($result.failed -gt 0 -and $record.status -eq 'ok') {
                    $record.status = 'falhas'
                    $record.motivo = "$($result.failed) pasta(s) nao removida(s); ver $($removeParameters.LogPath)"
                }
            }
            $record.grupos.Add($result)
        }
    }
} catch {
    if (-not (Get-Variable record -ErrorAction SilentlyContinue)) { throw }
    $record.status = 'erro'
    $record.motivo = "$($_.Exception.Message) (linha $($_.InvocationInfo.ScriptLineNumber))"
} finally {
    if (Get-Variable record -ErrorAction SilentlyContinue) {
        $entriesAfter = 0
        foreach ($dir in [IO.DirectoryInfo]::new($Root).EnumerateDirectories()) { $entriesAfter++ }
        $record.entradasDepois = $entriesAfter
        $record.livreDepoisGB = [math]::Round([IO.DriveInfo]::new([IO.Path]::GetPathRoot($Root)).AvailableFreeSpace / 1GB, 2)
        $record.fim = (Get-Date).ToString('o')
        Add-Content -LiteralPath $historyPath -Value ($record | ConvertTo-Json -Depth 6 -Compress) -Encoding utf8

        # Manifestos e logs de execucao antigos saem; o historico fica.
        Get-ChildItem -LiteralPath $runsDirectory -Directory |
            Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}_\d{6}$' -and $_.CreationTime -lt (Get-Date).AddDays(-$RetentionDays) } |
            Where-Object { $PSCmdlet.ShouldProcess($_.FullName, 'Remover manifestos e logs de execucao antiga') } |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse }

        Write-Output ('{0} {1}: {2}{3}; removidas {4}; criadas {5} em {6:N1} h; %TEMP% {7} -> {8} entradas' -f
            $record.modo, $record.status, $(if ($record.motivo) { $record.motivo } else { 'sem ocorrencias' }),
            $(if ($record.grupos.Count) { ' (' + (($record.grupos | ForEach-Object { "$($_.nome)=$($_.status)" }) -join ', ') + ')' } else { '' }),
            $record.removidas, $record.criadasTotal, $record.horasJanela, $record.entradasAntes, $record.entradasDepois)
    }
    if (Get-Variable lock -ErrorAction SilentlyContinue) { $lock.Dispose() }
}

if ($record.status -eq 'erro') { exit 1 }
