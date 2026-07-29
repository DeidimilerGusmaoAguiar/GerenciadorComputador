<#
.SYNOPSIS
Inicia o painel local de pressão de CPU, memória, disco, GPU e rede.

.DESCRIPTION
Serve uma interface local em 127.0.0.1 e coleta métricas por meio das classes
CIM nativas do Windows. O modo padrão é somente leitura. O encerramento de uma
árvore de CLI órfã só fica disponível com -EnableProcessTermination e ainda
exige confirmação explícita e revalidação integral no clique.
#>
[CmdletBinding()]
param(
    [ValidateRange(1024, 65535)]
    [int]$Port = 8765,

    [ValidateRange(2, 60)]
    [int]$RefreshSeconds = 5,

    [switch]$NoBrowser,

    [switch]$Background,

    [switch]$SnapshotOnly,

    [switch]$EnableProcessTermination,

    [ValidateRange(0, 10000)]
    [int]$MaxRequests = 0,

    [AllowEmptyString()]
    [string]$ShutdownToken = '',

    [switch]$NoHistory,

    [ValidateRange(1, 365)]
    [int]$HistoryRetentionDays = 7,

    [ValidateRange(1, 4096)]
    [int]$HistoryMaxMB = 50,

    [AllowEmptyString()]
    [string]$HistoryDirectory = '',

    [ValidateRange(0, 1440)]
    [int]$IdleTimeoutMinutes = 15,

    [switch]$NoParentWatch,

    [ValidateRange(2, 600)]
    [int]$MaxRefreshSeconds = 30,

    [switch]$FixedCadence
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$corePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'lib\pressure-core.ps1'))
$terminationScriptPath = [IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot 'stop-pressure-cli-session.ps1')
)
$historyCleanupScriptPath = [IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot 'remove-pressure-history.ps1')
)
$dashboardRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\dashboard\pressure'))
$indexPath = Join-Path $dashboardRoot 'index.html'
$stylePath = Join-Path $dashboardRoot 'styles.css'
$scriptPath = Join-Path $dashboardRoot 'app.js'

foreach (
    $requiredPath in @(
        $corePath,
        $terminationScriptPath,
        $historyCleanupScriptPath,
        $indexPath,
        $stylePath,
        $scriptPath
    )
) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Arquivo obrigatório do painel ausente: $requiredPath"
    }
}

if ($Background) {
    if ($SnapshotOnly) {
        throw '-Background e -SnapshotOnly não podem ser usados juntos.'
    }

    $pwshPath = (Get-Command pwsh -ErrorAction Stop).Source
    $childArguments = @(
        '-NoProfile',
        '-File',
        "`"$PSCommandPath`"",
        '-Port',
        [string]$Port,
        '-RefreshSeconds',
        [string]$RefreshSeconds
    )
    if ($NoBrowser) {
        $childArguments += '-NoBrowser'
    }
    if ($MaxRequests -gt 0) {
        $childArguments += @('-MaxRequests', [string]$MaxRequests)
    }
    if ($EnableProcessTermination) {
        $childArguments += '-EnableProcessTermination'
    }
    if (-not [string]::IsNullOrWhiteSpace($ShutdownToken)) {
        $childArguments += @('-ShutdownToken', "`"$ShutdownToken`"")
    }
    if ($NoHistory) {
        $childArguments += '-NoHistory'
    }
    $childArguments += @(
        '-HistoryRetentionDays',
        [string]$HistoryRetentionDays,
        '-HistoryMaxMB',
        [string]$HistoryMaxMB
    )
    if (-not [string]::IsNullOrWhiteSpace($HistoryDirectory)) {
        $childArguments += @('-HistoryDirectory', "`"$HistoryDirectory`"")
    }
    # O filho é destacado de propósito: este processo termina logo abaixo, então
    # vigiar o pai derrubaria o painel em segundos. A ociosidade continua valendo.
    $childArguments += @(
        '-NoParentWatch',
        '-IdleTimeoutMinutes',
        [string]$IdleTimeoutMinutes
    )

    $child = Start-Process `
        -FilePath $pwshPath `
        -ArgumentList $childArguments `
        -WindowStyle Hidden `
        -PassThru
    [pscustomobject]@{
        Status = 'started'
        ProcessId = $child.Id
        Url = "http://127.0.0.1:$Port/"
        Background = $true
    } |
        ConvertTo-Json -Depth 3
    return
}

. $corePath

$state = New-PressureMonitorState `
    -RefreshSeconds $RefreshSeconds `
    -MaxRefreshSeconds $MaxRefreshSeconds `
    -FixedCadence:$FixedCadence `
    -ProcessTerminationEnabled:$EnableProcessTermination `
    -DashboardProcessId ([uint32]$PID)
if ($SnapshotOnly) {
    Get-PressureSnapshot -State $state |
        ConvertTo-Json -Depth 10
    return
}

$resolvedHistoryDirectory = if ([string]::IsNullOrWhiteSpace($HistoryDirectory)) {
    [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\reports\pressure-history'))
} else {
    [IO.Path]::GetFullPath($HistoryDirectory)
}
$historyWriter = New-PressureHistoryWriter `
    -Directory $resolvedHistoryDirectory `
    -RetentionDays $HistoryRetentionDays `
    -MaxMB $HistoryMaxMB `
    -Disabled:$NoHistory
if ($historyWriter.Enabled) {
    Write-Host (
        "Histórico local em $resolvedHistoryDirectory " +
        "(retenção $HistoryRetentionDays dias ou $HistoryMaxMB MB). " +
        'Contém dados da máquina; não versione. Use -NoHistory para desligar.'
    )
}

$processActionToken = if ($EnableProcessTermination) {
    (
        [Convert]::ToHexString(
            [Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
        )
    ).ToLowerInvariant()
} else {
    ''
}

if (-not [System.Net.HttpListener]::IsSupported) {
    throw 'System.Net.HttpListener não está disponível neste Windows/.NET.'
}

function Write-PressureHttpResponse {
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerResponse]$Response,
        [Parameter(Mandatory)][int]$StatusCode,
        [Parameter(Mandatory)][string]$ContentType,
        [AllowEmptyString()][string]$Body = ''
    )

    $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
    $Response.StatusCode = $StatusCode
    $Response.ContentType = $ContentType
    $Response.ContentEncoding = [Text.Encoding]::UTF8
    $Response.ContentLength64 = $bytes.Length
    $Response.Headers['Cache-Control'] = 'no-store'
    $Response.Headers['Content-Security-Policy'] = (
        "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; " +
        "img-src 'self' data:; connect-src 'self'; object-src 'none'; " +
        "frame-ancestors 'none'; base-uri 'none'"
    )
    $Response.Headers['Permissions-Policy'] = 'camera=(), microphone=(), geolocation=()'
    $Response.Headers['Referrer-Policy'] = 'no-referrer'
    $Response.Headers['X-Content-Type-Options'] = 'nosniff'
    $Response.Headers['X-Frame-Options'] = 'DENY'
    $Response.Headers['Cross-Origin-Resource-Policy'] = 'same-origin'

    try {
        if ($bytes.Length -gt 0) {
            $Response.OutputStream.Write($bytes, 0, $bytes.Length)
        }
    } finally {
        $Response.OutputStream.Close()
        $Response.Close()
    }
}

function Write-PressureJsonResponse {
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerResponse]$Response,
        [Parameter(Mandatory)]$Value,
        [int]$StatusCode = 200
    )

    $json = $Value | ConvertTo-Json -Depth 10 -Compress
    Write-PressureHttpResponse `
        -Response $Response `
        -StatusCode $StatusCode `
        -ContentType 'application/json; charset=utf-8' `
        -Body $json
}

function Test-PressureActionToken {
    param(
        [AllowEmptyString()][string]$Candidate,
        [AllowEmptyString()][string]$Expected
    )

    if (
        [string]::IsNullOrWhiteSpace($Candidate) -or
        [string]::IsNullOrWhiteSpace($Expected)
    ) {
        return $false
    }

    $candidateBytes = [Text.Encoding]::UTF8.GetBytes($Candidate)
    $expectedBytes = [Text.Encoding]::UTF8.GetBytes($Expected)
    if ($candidateBytes.Length -ne $expectedBytes.Length) {
        return $false
    }
    return [Security.Cryptography.CryptographicOperations]::FixedTimeEquals(
        $candidateBytes,
        $expectedBytes
    )
}

function Read-PressureJsonRequest {
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerRequest]$Request,
        [ValidateRange(1, 65536)][int]$MaxBytes = 4096
    )

    if ($Request.ContentLength64 -lt 0 -or $Request.ContentLength64 -gt $MaxBytes) {
        throw 'O corpo da solicitação ultrapassa o limite permitido.'
    }

    $reader = [IO.StreamReader]::new(
        $Request.InputStream,
        $Request.ContentEncoding,
        $true,
        1024,
        $true
    )
    try {
        $body = $reader.ReadToEnd()
    } finally {
        $reader.Dispose()
    }
    if ([Text.Encoding]::UTF8.GetByteCount($body) -gt $MaxBytes) {
        throw 'O corpo da solicitação ultrapassa o limite permitido.'
    }
    if ([string]::IsNullOrWhiteSpace($body)) {
        throw 'O corpo JSON é obrigatório.'
    }

    return $body | ConvertFrom-Json -Depth 8
}

$shutdownReason = 'ctrl-c ou fim do processo'
$prefix = "http://127.0.0.1:$Port/"
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($prefix)
$listener.IgnoreWriteExceptions = $true

try {
    try {
        $listener.Start()
    } catch {
        throw "Não foi possível abrir $prefix. Verifique se a porta está livre. $($_.Exception.Message)"
    }

    Write-Host "Painel local: $prefix"
    if ($EnableProcessTermination) {
        Write-Host (
            'Encerramento opt-in habilitado apenas para árvores órfãs revalidadas; ' +
            'use Ctrl+C para encerrar o servidor.'
        )
    } else {
        Write-Host 'Somente leitura; use Ctrl+C para encerrar o servidor.'
    }

    if (-not $NoBrowser) {
        try {
            $browserRequest = Start-Process -FilePath $prefix -PassThru
            if ($null -ne $browserRequest) {
                Write-Host "Navegador solicitado pelo processo $($browserRequest.Id)."
            } else {
                Write-Host 'Navegador padrão solicitado.'
            }
        } catch {
            Write-Warning "Abra manualmente $prefix"
        }
    }

    $requestCount = 0
    $shutdownRequested = $false
    $cachedSnapshot = $null
    $cachedSnapshotExpiresAt = [datetime]::MinValue
    $null = Add-PressureHistoryRecord `
        -Writer $historyWriter `
        -Record (New-PressureHistoryBaseline -State $state -Kind 'session-start') `
        -Flush

    $parentWatch = if ($NoParentWatch) {
        [pscustomobject]@{
            Enabled = $false
            ParentId = [uint32]0
            ParentName = ''
            StartedAt = [datetime]::MinValue
        }
    } else {
        Get-PressureParentWatch
    }
    if ($parentWatch.Enabled) {
        Write-Host (
            "Vigia do pai ativo: $($parentWatch.ParentName) PID $($parentWatch.ParentId). " +
            'Se ele morrer, o painel encerra sozinho.'
        )
    }
    if ($IdleTimeoutMinutes -gt 0) {
        Write-Host "Encerramento automático após $IdleTimeoutMinutes min sem requisição."
    }

    # A espera precisa ser interrompível: com GetContext() bloqueante o painel
    # nunca conseguiria olhar o relógio nem o pai, e foi assim que uma instância
    # sobreviveu ao terminal que a criou.
    $lifecycleWaitMs = 5000
    $lastRequestAt = Get-Date
    while ($listener.IsListening -and -not $shutdownRequested) {
        $contextTask = $listener.GetContextAsync()
        while (-not $contextTask.Wait($lifecycleWaitMs)) {
            $lifecycleNow = Get-Date

            if (-not (Test-PressureParentAlive -Watch $parentWatch)) {
                $shutdownRequested = $true
                $shutdownReason = (
                    "processo pai $($parentWatch.ParentName) " +
                    "PID $($parentWatch.ParentId) desapareceu"
                )
                break
            }

            if (
                $IdleTimeoutMinutes -gt 0 -and
                ($lifecycleNow - $lastRequestAt).TotalMinutes -ge $IdleTimeoutMinutes
            ) {
                $shutdownRequested = $true
                $shutdownReason = "$IdleTimeoutMinutes min sem nenhuma requisição"
                break
            }

            if ($historyWriter.Enabled -and $lifecycleNow -ge $historyWriter.NextFlushAt) {
                $null = Save-PressureHistoryBuffer `
                    -Writer $historyWriter `
                    -Now $lifecycleNow
            }
        }

        if ($shutdownRequested) {
            Write-Host "Encerrando: $shutdownReason."
            break
        }

        $context = $contextTask.Result
        $lastRequestAt = Get-Date
        $requestCount++
        $request = $context.Request
        $response = $context.Response
        $path = $request.Url.AbsolutePath

        try {
            if ($request.HttpMethod -eq 'GET' -and $path -in @('/', '/index.html')) {
                Write-PressureHttpResponse `
                    -Response $response `
                    -StatusCode 200 `
                    -ContentType 'text/html; charset=utf-8' `
                    -Body ([IO.File]::ReadAllText($indexPath))
            } elseif ($request.HttpMethod -eq 'GET' -and $path -eq '/assets/styles.css') {
                Write-PressureHttpResponse `
                    -Response $response `
                    -StatusCode 200 `
                    -ContentType 'text/css; charset=utf-8' `
                    -Body ([IO.File]::ReadAllText($stylePath))
            } elseif ($request.HttpMethod -eq 'GET' -and $path -eq '/assets/app.js') {
                Write-PressureHttpResponse `
                    -Response $response `
                    -StatusCode 200 `
                    -ContentType 'text/javascript; charset=utf-8' `
                    -Body ([IO.File]::ReadAllText($scriptPath))
            } elseif ($request.HttpMethod -eq 'GET' -and $path -eq '/api/snapshot') {
                $now = Get-Date
                if ($null -eq $cachedSnapshot -or $now -ge $cachedSnapshotExpiresAt) {
                    $cachedSnapshot = Get-PressureSnapshot -State $state
                    # A validade acompanha a cadência efetiva, não o parâmetro
                    # inicial: senão o recuo automático não economizaria nada.
                    $cachedSnapshotExpiresAt = (Get-Date).AddSeconds($state.RefreshSeconds)
                    $null = Add-PressureHistoryRecord `
                        -Writer $historyWriter `
                        -Record (ConvertTo-PressureHistoryRecord -Snapshot $cachedSnapshot)

                    if (@($historyWriter.PendingCleanup).Count -gt 0) {
                        # A remoção fica no único script com dry-run, -Execute e
                        # ShouldProcess; o painel só informa a raiz que ele mesmo criou.
                        try {
                            $cleanup = & $historyCleanupScriptPath `
                                -Directory $historyWriter.Directory `
                                -RetentionDays $HistoryRetentionDays `
                                -MaxMB $HistoryMaxMB `
                                -Execute `
                                -Confirm:$false
                            Write-Host (
                                'Retenção do histórico: ' +
                                "$(@($cleanup.RemovedFiles).Count) arquivo(s) removido(s)."
                            )
                        } catch {
                            Write-Warning "A retenção do histórico falhou: $($_.Exception.Message)"
                        }
                        $historyWriter.PendingCleanup = @()
                    }
                }
                Write-PressureJsonResponse -Response $response -Value $cachedSnapshot
            } elseif ($request.HttpMethod -eq 'GET' -and $path -eq '/api/health') {
                Write-PressureJsonResponse -Response $response -Value ([pscustomobject]@{
                    Status = 'ok'
                    ListeningOn = '127.0.0.1'
                    StartedAt = $state.StartedAt.ToString('o')
                    ProcessTerminationEnabled = [bool]$EnableProcessTermination
                })
            } elseif ($request.HttpMethod -eq 'GET' -and $path -eq '/api/action-token') {
                if (-not $EnableProcessTermination) {
                    Write-PressureJsonResponse `
                        -Response $response `
                        -StatusCode 404 `
                        -Value ([pscustomobject]@{
                            Error = 'process_termination_disabled'
                        })
                } else {
                    Write-PressureJsonResponse -Response $response -Value ([pscustomobject]@{
                        Token = $processActionToken
                    })
                }
            } elseif ($request.HttpMethod -eq 'GET' -and $path -eq '/favicon.ico') {
                Write-PressureHttpResponse `
                    -Response $response `
                    -StatusCode 204 `
                    -ContentType 'image/x-icon'
            } elseif (
                $request.HttpMethod -eq 'POST' -and
                $path -eq '/api/cli-sessions/terminate'
            ) {
                if (-not $EnableProcessTermination) {
                    Write-PressureJsonResponse `
                        -Response $response `
                        -StatusCode 404 `
                        -Value ([pscustomobject]@{
                            Status = 'refused'
                            Code = 'process_termination_disabled'
                            Message = 'O servidor foi iniciado em modo somente leitura.'
                        })
                } elseif (
                    -not (
                        Test-PressureActionToken `
                            -Candidate ([string]$request.Headers['X-Pressure-Action-Token']) `
                            -Expected $processActionToken
                    )
                ) {
                    Write-PressureJsonResponse `
                        -Response $response `
                        -StatusCode 403 `
                        -Value ([pscustomobject]@{
                            Status = 'refused'
                            Code = 'invalid_action_token'
                            Message = 'Token efêmero de ação ausente ou inválido.'
                        })
                } else {
                    if (
                        [string]::IsNullOrWhiteSpace([string]$request.ContentType) -or
                        -not ([string]$request.ContentType).StartsWith(
                            'application/json',
                            [StringComparison]::OrdinalIgnoreCase
                        )
                    ) {
                        throw 'Content-Type deve ser application/json.'
                    }

                    $payload = Read-PressureJsonRequest -Request $request -MaxBytes 4096
                    $requiredActionProperties = @(
                        'RootId',
                        'RootStartedAt',
                        'ExpectedFingerprint',
                        'ExpectedProcessCount',
                        'Confirmed'
                    )
                    foreach ($requiredActionProperty in $requiredActionProperties) {
                        if ($requiredActionProperty -notin $payload.PSObject.Properties.Name) {
                            throw "Propriedade obrigatória ausente: $requiredActionProperty"
                        }
                    }
                    if (
                        -not ($payload.Confirmed -is [bool]) -or
                        $payload.Confirmed -ne $true
                    ) {
                        throw 'A confirmação explícita é obrigatória.'
                    }

                    [uint32]$actionRootId = 0
                    [int]$actionProcessCount = 0
                    if (
                        -not [uint32]::TryParse(
                            [string]$payload.RootId,
                            [ref]$actionRootId
                        ) -or
                        $actionRootId -eq 0
                    ) {
                        throw 'RootId inválido.'
                    }
                    if (
                        -not [int]::TryParse(
                            [string]$payload.ExpectedProcessCount,
                            [ref]$actionProcessCount
                        ) -or
                        $actionProcessCount -lt 1 -or
                        $actionProcessCount -gt 512
                    ) {
                        throw 'ExpectedProcessCount inválido.'
                    }
                    $actionStartedAt = [string]$payload.RootStartedAt
                    $actionFingerprint = [string]$payload.ExpectedFingerprint
                    if ([string]::IsNullOrWhiteSpace($actionStartedAt)) {
                        throw 'RootStartedAt inválido.'
                    }
                    if ($actionFingerprint -notmatch '(?i)^[a-f0-9]{64}$') {
                        throw 'ExpectedFingerprint inválido.'
                    }

                    $terminationResult = & $terminationScriptPath `
                        -RootId $actionRootId `
                        -RootStartedAt $actionStartedAt `
                        -ExpectedFingerprint $actionFingerprint `
                        -ExpectedProcessCount $actionProcessCount `
                        -AdditionalProtectedProcessIds @([uint32]$PID) `
                        -Execute `
                        -Confirm:$false

                    $state.MetadataRefreshAt = [datetime]::MinValue
                    $cachedSnapshot = $null
                    $cachedSnapshotExpiresAt = [datetime]::MinValue
                    $terminationStatusCode = if (
                        [string]$terminationResult.Status -in @('completed', 'partial')
                    ) {
                        200
                    } else {
                        409
                    }
                    Write-PressureJsonResponse `
                        -Response $response `
                        -StatusCode $terminationStatusCode `
                        -Value $terminationResult
                }
            } elseif (
                $request.HttpMethod -eq 'POST' -and
                $path -eq '/api/shutdown' -and
                -not [string]::IsNullOrWhiteSpace($ShutdownToken) -and
                $request.Headers['X-Pressure-Shutdown-Token'] -ceq $ShutdownToken
            ) {
                Write-PressureJsonResponse -Response $response -Value ([pscustomobject]@{
                    Status = 'stopping'
                })
                $shutdownRequested = $true
                $shutdownReason = 'desligamento solicitado com token'
            } elseif ($request.HttpMethod -notin @('GET', 'POST')) {
                Write-PressureJsonResponse `
                    -Response $response `
                    -StatusCode 405 `
                    -Value ([pscustomobject]@{ Error = 'method_not_allowed' })
            } else {
                Write-PressureJsonResponse `
                    -Response $response `
                    -StatusCode 404 `
                    -Value ([pscustomobject]@{ Error = 'not_found' })
            }
        } catch {
            try {
                if ($response.OutputStream.CanWrite) {
                    Write-PressureJsonResponse `
                        -Response $response `
                        -StatusCode 500 `
                        -Value ([pscustomobject]@{
                            Error = 'request_failed'
                            Message = 'A solicitação falhou sem ampliar o escopo da alteração.'
                        })
                }
            } catch {
                # O cliente pode ter fechado a conexão; o servidor segue ativo.
            }
        }

        if ($MaxRequests -gt 0 -and $requestCount -ge $MaxRequests) {
            $shutdownRequested = $true
            $shutdownReason = 'limite de requisições atingido'
        }
    }
} finally {
    if ($listener.IsListening) {
        $listener.Stop()
    }
    $listener.Close()

    if ($null -ne $historyWriter -and $historyWriter.Enabled) {
        try {
            $null = Add-PressureHistoryRecord `
                -Writer $historyWriter `
                -Record (
                    New-PressureHistoryBaseline `
                        -State $state `
                        -Kind 'session-end' `
                        -Reason $shutdownReason
                ) `
                -Flush
        } catch {
            Write-Warning "O histórico não pôde ser finalizado: $($_.Exception.Message)"
        }
    }

    Write-Host 'Servidor do painel encerrado.'
}
