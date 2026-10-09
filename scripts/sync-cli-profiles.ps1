<#
.SYNOPSIS
Gera os atalhos de perfil das CLIs de IA a partir de um mapa local, mantendo
todos os hosts do PowerShell com o mesmo conjunto.

.DESCRIPTION
Um computador pode manter varios perfis isolados da mesma CLI, cada um em seu
diretorio de estado. Windows PowerShell 5.1 e PowerShell 7 leem arquivos de
perfil diferentes, e manter os dois a mao faz um deles ficar para tras sem aviso.

Este script trata um mapa como fonte unica e escreve uma regiao delimitada em
cada perfil de host. Fora dessa regiao nada e tocado: funcoes escritas a mao
continuam onde estao, e conflitos de nome sao apenas relatados.

O mapa descreve maquina, entao mora em local\ e nunca e versionado. Use
-Bootstrap para monta-lo por descoberta de convencao num computador novo.

O mapa tambem descreve rotas: quais pastas abrem em qual plano, e em quais
delas a sessao enxerga skills e hooks do perfil do usuario. Nesse formato a
pasta decide a blindagem e o comando decide o lado, entao os atalhos gerados
sao por lado, nao por diretorio de estado.

Dry-run e o padrao, e o script em si so escreve em arquivo de perfil do shell e
nas abas do terminal.

Sobre credencial: o SCRIPT nunca abre .credentials.json. O codigo que ele GERA
abre, se o mapa pedir shareCredentials, e por um motivo: blindagem exige
diretorios de estado separados, mas login e da conta, nao do diretorio. Sem isso
seriam varios /login para a mesma conta. O codigo gerado le apenas metadados
- se ha token e ate quando - e copia o arquivo inteiro entre diretorios do MESMO
lado, nunca entre lados, e so quando a conta gravada no diretorio de origem e a
declarada para aquele lado. O valor do token nunca e lido para variavel, impresso
nem registrado. Junto com a credencial vao a identidade (oauthAccount) e a marca
de onboarding (hasCompletedOnboarding) do .claude.json: sem qualquer uma delas a
CLI pede login mesmo com token valido ao lado.

.EXAMPLE
pwsh -NoProfile -File .\scripts\sync-cli-profiles.ps1 -Bootstrap -SearchRoot C:\Repos

.EXAMPLE
pwsh -NoProfile -File .\scripts\sync-cli-profiles.ps1

.EXAMPLE
pwsh -NoProfile -File .\scripts\sync-cli-profiles.ps1 -Execute
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [AllowEmptyString()]
    [string]$MapPath = '',

    [switch]$Bootstrap,

    # Compara o mapa com o que existe no disco e relata diferenca, sem gerar
    # nada. Descoberta avisa; decidir continua sendo do usuario.
    [switch]$Report,

    [string[]]$SearchRoot = @(),

    [switch]$Force,

    # Grava apenas a regiao gerada num arquivo a parte, para revisar ou testar o
    # codigo antes de encostar em qualquer perfil de host.
    [AllowEmptyString()]
    [string]$BlockOutPath = '',

    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$resolvedMapPath = if ([string]::IsNullOrWhiteSpace($MapPath)) {
    [IO.Path]::GetFullPath((Join-Path $repoRoot 'local\perfis-cli.json'))
} else {
    [IO.Path]::GetFullPath($MapPath)
}

$regionStart = '# >>> perfis-cli inicio: regiao gerenciada - nao editar a mao'
$regionEnd = '# <<< perfis-cli fim'

# CLIs conhecidas e a variavel que troca o diretorio de estado de cada uma. O
# sufixo do alias mantem a convencao de quem ja usa: a CLI primaria nao repete o
# nome, as outras sim.
$cliCatalog = [ordered]@{
    claude = [pscustomobject]@{ Variable = 'CLAUDE_CONFIG_DIR'; Command = 'claude'; AliasSuffix = '' }
    codex = [pscustomobject]@{ Variable = 'CODEX_HOME'; Command = 'codex'; AliasSuffix = '-codex' }
    gemini = [pscustomobject]@{ Variable = 'GEMINI_CONFIG_DIR'; Command = 'gemini'; AliasSuffix = '-gemini' }
    grok = [pscustomobject]@{ Variable = 'GROK_CONFIG_DIR'; Command = 'grok'; AliasSuffix = '-grok' }
}

$paletteByIndex = @('Cyan', 'Yellow', 'Green', 'Magenta', 'Blue', 'DarkYellow')

function Get-ProfileTarget {
    <#
    .SYNOPSIS
    Descobre o arquivo de perfil de cada host do PowerShell nesta maquina.

    .DESCRIPTION
    O caminho vem de Documents em runtime, nunca de letra de unidade ou nome de
    usuario fixo. Escrever em caminho arbitrario nao e oferecido de proposito: o
    alvo e sempre um perfil de host conhecido.
    #>
    [CmdletBinding()]
    param()

    $documents = [Environment]::GetFolderPath('MyDocuments')
    if ([string]::IsNullOrWhiteSpace($documents)) {
        throw 'Nao foi possivel descobrir a pasta Documentos desta conta.'
    }

    # $host e variavel automatica: usar outro nome aqui evita erro de atribuicao.
    foreach ($hostInfo in @(
        [pscustomobject]@{ Name = 'PowerShell 7'; Folder = 'PowerShell'; Executable = 'pwsh' }
        [pscustomobject]@{ Name = 'Windows PowerShell 5.1'; Folder = 'WindowsPowerShell'; Executable = 'powershell' }
    )) {
        $path = [IO.Path]::GetFullPath(
            (Join-Path (Join-Path $documents $hostInfo.Folder) 'Microsoft.PowerShell_profile.ps1')
        )
        [pscustomobject]@{
            Name = $hostInfo.Name
            Path = $path
            Executable = $hostInfo.Executable
            Exists = Test-Path -LiteralPath $path -PathType Leaf
        }
    }
}

function ConvertTo-ProfileSlug {
    <#
    .SYNOPSIS
    Deriva o apelido do perfil a partir do nome do diretorio de estado.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DirectoryName,
        [Parameter(Mandatory)][string]$Cli
    )

    $bare = $DirectoryName.TrimStart('.')
    if ($bare -eq $Cli) {
        return 'padrao'
    }
    return ($bare -replace "^$([regex]::Escape($Cli))-", '')
}

function New-ProfileMap {
    <#
    .SYNOPSIS
    Monta o mapa por descoberta de convencao de nome.

    .DESCRIPTION
    Lancador fora do shell, como um .cmd que monta a variavel, nao aparece em
    lista de alias. Por isso a descoberta olha diretorio, nao atalho existente.
    #>
    [CmdletBinding()]
    param([string[]]$Root = @())

    $roots = @(
        [Environment]::GetFolderPath('UserProfile')
        $Root | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    ) |
        ForEach-Object { [IO.Path]::GetFullPath($_) } |
        Sort-Object -Unique

    $entries = [Collections.Generic.List[object]]::new()
    foreach ($currentRoot in $roots) {
        if (-not (Test-Path -LiteralPath $currentRoot -PathType Container)) {
            Write-Warning "Raiz inexistente ignorada: $currentRoot"
            continue
        }

        foreach ($cli in $cliCatalog.Keys) {
            $candidates = @(
                Get-ChildItem -LiteralPath $currentRoot -Directory -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -eq ".$cli" -or $_.Name -like ".$cli-*" } |
                    Sort-Object Name
            )
            foreach ($candidate in $candidates) {
                # Reparse point pode apontar para fora da raiz; o script nao
                # segue esse tipo de vinculo.
                if ($candidate.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                    Write-Warning "Reparse point ignorado: $($candidate.FullName)"
                    continue
                }

                $slug = ConvertTo-ProfileSlug -DirectoryName $candidate.Name -Cli $cli
                $entries.Add([pscustomobject]@{
                    cli = $cli
                    slug = $slug
                    alias = "cc-$slug$($cliCatalog[$cli].AliasSuffix)"
                    label = $slug.ToUpperInvariant()
                    color = $paletteByIndex[$entries.Count % $paletteByIndex.Count]
                    home = $candidate.FullName
                })
            }
        }
    }

    return [pscustomobject]@{
        version = 1
        generatedBy = 'scripts\sync-cli-profiles.ps1 -Bootstrap'
        note = 'Dado local: nomeia usuario e sistemas internos. Nao versionar.'
        profiles = @($entries)
    }
}

function Test-MapProperty {
    <#
    .SYNOPSIS
    Diz se um objeto vindo de ConvertFrom-Json tem a propriedade.

    .DESCRIPTION
    Sob StrictMode, tocar em propriedade ausente e erro. Campo opcional de mapa
    precisa desta pergunta antes da leitura.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $InputObject) { return $false }
    if ($InputObject -is [Collections.IDictionary]) { return $InputObject.Contains($Name) }
    return ($InputObject.PSObject.Properties.Name -contains $Name)
}

function Test-ProfileMap {
    <#
    .SYNOPSIS
    Recusa mapa incompleto antes de gerar codigo a partir dele.

    .DESCRIPTION
    Dois formatos convivem. O antigo declara um atalho por diretorio de estado,
    e la o campo "alias" e obrigatorio. O novo declara os diretorios com "side"
    e "shield" e deixa a secao "routing" decidir os comandos: nesse caso o alias
    e opcional, porque o diretorio nao vira atalho proprio.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Map)

    if (-not (Test-MapProperty -InputObject $Map -Name 'profiles')) {
        throw 'Mapa sem a lista "profiles".'
    }

    $validShields = @('aberto', 'blindado')
    $seen = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $byCliSideShield = @{}

    foreach ($entry in @($Map.profiles)) {
        foreach ($required in @('cli', 'label', 'color', 'home')) {
            if (
                -not (Test-MapProperty -InputObject $entry -Name $required) -or
                [string]::IsNullOrWhiteSpace([string]$entry.$required)
            ) {
                throw "Perfil sem o campo obrigatorio '$required': $($entry | ConvertTo-Json -Compress)"
            }
        }
        if (-not $cliCatalog.Contains([string]$entry.cli)) {
            throw "CLI desconhecida no mapa: $($entry.cli)"
        }
        if ([string]$entry.color -notin [Enum]::GetNames([ConsoleColor])) {
            throw "Cor invalida no perfil $($entry.home): $($entry.color)"
        }

        $hasAlias = (Test-MapProperty -InputObject $entry -Name 'alias') -and
            -not [string]::IsNullOrWhiteSpace([string]$entry.alias)
        $hasSide = (Test-MapProperty -InputObject $entry -Name 'side') -and
            -not [string]::IsNullOrWhiteSpace([string]$entry.side)
        $hasShield = (Test-MapProperty -InputObject $entry -Name 'shield') -and
            -not [string]::IsNullOrWhiteSpace([string]$entry.shield)

        if ($hasAlias) {
            if ([string]$entry.alias -notmatch '^[A-Za-z][\w\-]*$') {
                throw "Alias invalido para funcao do PowerShell: $($entry.alias)"
            }
            if (-not $seen.Add([string]$entry.alias)) {
                throw "Alias repetido no mapa: $($entry.alias)"
            }
        }

        if ($hasSide -ne $hasShield) {
            throw "Perfil com 'side' sem 'shield' ou vice-versa: $($entry.home)"
        }
        if ($hasShield -and ([string]$entry.shield -notin $validShields)) {
            throw "Blindagem invalida em $($entry.home): $($entry.shield). Use 'aberto' ou 'blindado'."
        }
        if ($hasSide) {
            $chave = '{0}|{1}|{2}' -f $entry.cli, $entry.side, $entry.shield
            if ($byCliSideShield.ContainsKey($chave)) {
                throw "Dois perfis para o mesmo lado e blindagem: $chave"
            }
            $byCliSideShield[$chave] = [string]$entry.home
        }
        if (-not $hasAlias -and -not $hasSide) {
            # Sem alias e sem lado o perfil nao gera nada. Continua valendo para
            # a descoberta de cobertura do antimalware, entao e aviso, nao erro.
            Write-Verbose "Perfil so para inventario, sem atalho e sem rota: $($entry.home)"
        }
    }

    if (-not (Test-MapProperty -InputObject $Map -Name 'routing')) {
        return
    }

    foreach ($cliName in @($Map.routing.PSObject.Properties.Name)) {
        if (-not $cliCatalog.Contains($cliName)) {
            throw "Rota declarada para CLI desconhecida: $cliName"
        }
        $routing = $Map.routing.$cliName

        foreach ($required in @('defaultSide', 'commands')) {
            if (-not (Test-MapProperty -InputObject $routing -Name $required)) {
                throw "routing.$cliName sem o campo obrigatorio '$required'."
            }
        }

        $sides = @($routing.commands.PSObject.Properties.Name)
        if ($sides.Count -eq 0) {
            throw "routing.$cliName sem nenhum lado em 'commands'."
        }
        if ([string]$routing.defaultSide -notin $sides) {
            throw "routing.$cliName.defaultSide '$($routing.defaultSide)' nao esta em 'commands'."
        }

        foreach ($side in $sides) {
            foreach ($shield in $validShields) {
                $chave = '{0}|{1}|{2}' -f $cliName, $side, $shield
                if (-not $byCliSideShield.ContainsKey($chave)) {
                    throw (
                        "Falta o perfil '$side' / '$shield' para $cliName. " +
                        'Cada lado precisa dos dois diretorios de estado, ' +
                        'senao uma pasta fica sem plano.'
                    )
                }
            }
            foreach ($command in @($routing.commands.$side)) {
                if ([string]$command -notmatch '^[A-Za-z][\w\-]*$') {
                    throw "Comando invalido para funcao do PowerShell: $command"
                }
                if (-not $seen.Add([string]$command)) {
                    throw "Comando repetido no mapa: $command"
                }
            }
        }

        foreach ($optional in @('statusCommand', 'askCommand')) {
            if (-not (Test-MapProperty -InputObject $routing -Name $optional)) { continue }
            $nome = [string]$routing.$optional
            if ([string]::IsNullOrWhiteSpace($nome)) { continue }
            if ($nome -notmatch '^[A-Za-z][\w\-]*$') {
                throw "Comando invalido para funcao do PowerShell: $nome"
            }
            if (-not $seen.Add($nome)) {
                throw "Comando repetido no mapa: $nome"
            }
        }
        foreach ($optional in @('statusAliases', 'askAliases')) {
            if (-not (Test-MapProperty -InputObject $routing -Name $optional)) { continue }
            foreach ($nome in @($routing.$optional)) {
                if ([string]$nome -notmatch '^[A-Za-z][\w\-]*$') {
                    throw "Alias invalido para funcao do PowerShell: $nome"
                }
                if (-not $seen.Add([string]$nome)) {
                    throw "Comando repetido no mapa: $nome"
                }
            }
        }

        if (Test-MapProperty -InputObject $routing -Name 'sharedState') {
            $shared = $routing.sharedState
            if (
                -not (Test-MapProperty -InputObject $shared -Name 'root') -or
                [string]::IsNullOrWhiteSpace([string]$shared.root)
            ) {
                throw "routing.$cliName.sharedState sem 'root'."
            }
            # @() por fora do if: lista de um item so seria desmontada e o .Count
            # abaixo falharia no StrictMode com uma unica pasta compartilhada.
            $sharedFolders = @(if (Test-MapProperty -InputObject $shared -Name 'folders') { $shared.folders })
            $sharedFiles = @(if (Test-MapProperty -InputObject $shared -Name 'files') { $shared.files })
            if ($sharedFolders.Count -eq 0 -and $sharedFiles.Count -eq 0) {
                throw "routing.$cliName.sharedState sem nada em 'folders' nem 'files'."
            }
            # Conta e blindagem nao sao historico. Compartilhar qualquer um
            # destes juntaria as contas dos planos, que e' o oposto do desenho.
            $proibidos = @('.claude.json', '.credentials.json', 'settings.json', 'skills', 'agents', 'plugins')
            foreach ($nome in @($sharedFolders) + @($sharedFiles)) {
                if ([string]$nome -in $proibidos) {
                    throw (
                        "routing.$cliName.sharedState tenta compartilhar '$nome'. " +
                        'Esse arquivo pertence a conta ou a blindagem do plano, nao ao historico.'
                    )
                }
                if ([string]$nome -match '[\\/]' -or [string]$nome -match '^\.\.') {
                    throw "routing.$cliName.sharedState com nome invalido: $nome"
                }
            }
        }

        # Variavel de credencial no ambiente passa na frente do login do plano:
        # a sessao interativa sobe cobrando a API e cai quando o saldo nao cobre.
        # Declarada aqui, ela e' retirada de toda sessao do roteador.
        $credentialEnv = @()
        if (Test-MapProperty -InputObject $routing -Name 'credentialEnv') {
            $credentialEnv = @($routing.credentialEnv | ForEach-Object { [string]$_ })
            foreach ($nome in $credentialEnv) {
                if ($nome -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
                    throw "routing.$cliName.credentialEnv com nome de variavel invalido: $nome"
                }
            }
        }

        if (Test-MapProperty -InputObject $routing -Name 'apiKeys') {
            $api = $routing.apiKeys
            foreach ($required in @('variable', 'vaultScript', 'vaultFile', 'sides')) {
                if (-not (Test-MapProperty -InputObject $api -Name $required)) {
                    throw "routing.$cliName.apiKeys sem o campo obrigatorio '$required'."
                }
            }
            if ([string]$api.variable -notin $credentialEnv) {
                throw (
                    "routing.$cliName.apiKeys.variable '$($api.variable)' precisa estar em credentialEnv: " +
                    'sem isso uma chave esquecida no ambiente derrubaria as sessoes do plano.'
                )
            }
            $temBudget = Test-MapProperty -InputObject $api -Name 'budgetFile'
            $temLedger = Test-MapProperty -InputObject $api -Name 'ledgerFile'
            if ($temBudget -ne $temLedger) {
                throw "routing.$cliName.apiKeys precisa de budgetFile e ledgerFile juntos: orcamento sem registro nao confere gasto."
            }
            if (Test-MapProperty -InputObject $api -Name 'budgetCommand') {
                if (-not $temBudget) {
                    throw "routing.$cliName.apiKeys.budgetCommand sem budgetFile."
                }
                $nome = [string]$api.budgetCommand
                if ($nome -notmatch '^[A-Za-z][\w\-]*$') {
                    throw "Comando invalido para funcao do PowerShell: $nome"
                }
                if (-not $seen.Add($nome)) {
                    throw "Comando repetido no mapa: $nome"
                }
            }
            if (Test-MapProperty -InputObject $api -Name 'runner') {
                if (@($api.runner | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -eq 0) {
                    throw "routing.$cliName.apiKeys.runner vazio."
                }
            }
            $apiSides = @($api.sides.PSObject.Properties | ForEach-Object { $_.Name })
            if ($apiSides.Count -eq 0) {
                throw "routing.$cliName.apiKeys sem nenhum lado em 'sides'."
            }
            foreach ($side in $apiSides) {
                if ($side -notin $sides) {
                    throw "routing.$cliName.apiKeys.sides.$side nao e um lado de 'commands'."
                }
                $item = $api.sides.$side
                if (
                    -not (Test-MapProperty -InputObject $item -Name 'entry') -or
                    [string]$item.entry -notmatch '^[^/\s]+/\S+$'
                ) {
                    throw "routing.$cliName.apiKeys.sides.$side.entry deve ser 'namespace/chave' do cofre."
                }
                # @() por fora: atribuir o resultado de um if desmonta lista de
                # um item so, e o .Count falharia no StrictMode.
                $apiCommands = @()
                if (Test-MapProperty -InputObject $item -Name 'commands') { $apiCommands = @($item.commands) }
                if ($apiCommands.Count -eq 0) {
                    throw "routing.$cliName.apiKeys.sides.$side sem 'commands'."
                }
                foreach ($command in $apiCommands) {
                    if ([string]$command -notmatch '^[A-Za-z][\w\-]*$') {
                        throw "Comando invalido para funcao do PowerShell: $command"
                    }
                    if (-not $seen.Add([string]$command)) {
                        throw "Comando repetido no mapa: $command"
                    }
                }
            }
        }

        # Rota para pasta inexistente nao e erro - repositorio pode nao estar
        # clonado nesta maquina - mas o silencio esconde erro de digitacao.
        if (Test-MapProperty -InputObject $routing -Name 'routes') {
            foreach ($route in @($routing.routes)) {
                foreach ($required in @('path', 'side')) {
                    if (-not (Test-MapProperty -InputObject $route -Name $required)) {
                        throw "Rota de $cliName sem o campo '$required'."
                    }
                }
                if ([string]$route.side -notin $sides) {
                    throw "Rota $($route.path) aponta para lado desconhecido: $($route.side)"
                }
                if (-not (Test-Path -LiteralPath ([string]$route.path))) {
                    Write-Warning "Rota declarada para pasta que nao existe aqui: $($route.path)"
                }
            }
        }
    }
}

function Get-MapDrift {
    <#
    .SYNOPSIS
    Compara o mapa com os diretorios de estado existentes no disco.

    .DESCRIPTION
    Perfil novo aparece como diretorio antes de virar atalho. Este relatorio
    aponta o que o mapa ainda nao menciona e o que o mapa menciona sem existir,
    sem alterar nada. Diretorio listado em "ignore" nao volta a aparecer: a
    decisao de nao ter alias tambem e uma decisao registrada.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Map,
        [string[]]$Root = @()
    )

    $known = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $mapped = @(@($Map.profiles).home | Where-Object { $_ })
    $ignored = if ($Map.PSObject.Properties.Name -contains 'ignore') {
        @($Map.ignore | Where-Object { $_ })
    } else {
        @()
    }
    # O store comum mora ao lado dos diretorios de estado e tem a mesma cara.
    # Sem entrar aqui, ele apareceria como "perfil novo" em todo relatorio de
    # deriva, convidando a criar um plano para algo que e' o oposto de um plano.
    $sharedRoots = @(
        if ($Map.PSObject.Properties.Name -contains 'routing') {
            foreach ($cliName in @($Map.routing.PSObject.Properties.Name)) {
                $routing = $Map.routing.$cliName
                if ($routing.PSObject.Properties.Name -notcontains 'sharedState') { continue }
                [string]$routing.sharedState.root
            }
        }
    )
    foreach ($path in @($mapped) + @($ignored) + @($sharedRoots | Where-Object { $_ })) {
        $null = $known.Add([IO.Path]::GetFullPath([string]$path))
    }

    # As raizes saem do proprio mapa: quem ja declarou um perfil em C:\Repos quer
    # que essa pasta continue sendo observada, sem repetir -SearchRoot.
    $roots = @(
        $Root
        @($mapped) + @($ignored) | ForEach-Object {
            [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath([string]$_))
        }
    ) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { [IO.Path]::GetFullPath($_) } |
        Sort-Object -Unique

    $discovered = @(New-ProfileMap -Root $roots).profiles
    $novos = @(
        $discovered |
            Where-Object { -not $known.Contains([IO.Path]::GetFullPath([string]$_.home)) }
    )
    $ausentes = @(
        $mapped |
            Where-Object { -not (Test-Path -LiteralPath ([string]$_) -PathType Container) }
    )

    return [pscustomobject]@{
        Roots = @($roots)
        Mapped = @($mapped).Count
        Ignored = @($ignored).Count
        Novos = $novos
        Ausentes = @($ausentes)
    }
}

function ConvertTo-GeneratedPath {
    <#
    .SYNOPSIS
    Escreve o caminho do perfil preferindo a variavel do proprio usuario.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $userProfile = [IO.Path]::GetFullPath([Environment]::GetFolderPath('UserProfile'))
    $full = [IO.Path]::GetFullPath($Path)
    if ($full.StartsWith($userProfile + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        $relative = $full.Substring($userProfile.Length)
        return '"$env:USERPROFILE' + $relative + '"'
    }
    return "'" + $full.Replace("'", "''") + "'"
}

function ConvertTo-GeneratedList {
    <#
    .SYNOPSIS
    Escreve uma lista de caminhos como literal de array do PowerShell.
    #>
    [CmdletBinding()]
    param([string[]]$Item = @())

    if (@($Item).Count -eq 0) { return '@()' }
    $partes = foreach ($valor in $Item) { ConvertTo-GeneratedPath -Path $valor }
    return '@(' + ($partes -join ', ') + ')'
}

# Nucleo fixo das rotas. Nao depende do mapa: o que muda de maquina para maquina
# entra em $script:PlanoRota, montado logo acima dele por New-RoutingLines.
$routingCore = @'

# ---- nucleo das rotas: identico em qualquer maquina ----

function Get-PlanoPastaAtual {
    # Location fora do provedor de arquivos - HKLM:\, por exemplo - nao tem
    # caminho para casar com rota. O perfil do usuario e o fallback honesto.
    $atual = Get-Location
    if ($atual.Provider.Name -eq 'FileSystem') { return $atual.ProviderPath }
    return $env:USERPROFILE
}

function Test-PlanoDentroDe {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root
    )
    # Caminho exato ou subpasta real. Nao e curinga: um vizinho chamado
    # <raiz>-antigo nao pode entrar na regra da raiz.
    $p = [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $r = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if ($p.Equals($r, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $p.StartsWith($r + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Get-PlanoBlindagem {
    param(
        [Parameter(Mandatory)][string]$Cli,
        [Parameter(Mandatory)][string]$Path
    )
    # Blindagem e propriedade da PASTA, nunca do comando.
    foreach ($zona in $script:PlanoRota[$Cli].OpenZones) {
        if (Test-PlanoDentroDe -Path $Path -Root $zona) { return 'aberto' }
    }
    return 'blindado'
}

function Get-PlanoLado {
    param(
        [Parameter(Mandatory)][string]$Cli,
        [Parameter(Mandatory)][string]$Path
    )
    $lado = $script:PlanoRota[$Cli].DefaultSide
    $maisEspecifica = -1
    foreach ($rota in $script:PlanoRota[$Cli].Routes) {
        if (-not (Test-PlanoDentroDe -Path $Path -Root $rota.Path)) { continue }
        # Rota aninhada vence a rota mais curta que a contem.
        if ($rota.Path.Length -gt $maisEspecifica) {
            $maisEspecifica = $rota.Path.Length
            $lado = $rota.Side
        }
    }
    return $lado
}

function Resolve-PlanoEstado {
    param(
        [Parameter(Mandatory)][string]$Cli,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Side
    )
    $blindagem = Get-PlanoBlindagem -Cli $Cli -Path $Path
    $chave = $Side + '|' + $blindagem
    $rota = $script:PlanoRota[$Cli]
    if (-not $rota.Dir.ContainsKey($chave)) {
        throw "Plano sem diretorio de estado declarado: $chave"
    }
    return [pscustomobject]@{
        Cli = $Cli
        Side = $Side
        Shield = $blindagem
        Home = $rota.Dir[$chave]
        Label = $rota.Label[$chave]
        Color = $rota.Color[$chave]
    }
}

function Get-PlanoConta {
    <#
    .SYNOPSIS
    Le so a identificacao de conta do diretorio de estado.

    .DESCRIPTION
    Le exclusivamente oauthAccount de .claude.json. O arquivo de credenciais
    nunca e aberto: token nao precisa passar por aqui para responder "qual
    plano estou gastando".
    #>
    param([Parameter(Mandatory)][string]$Path)

    $arquivo = Join-Path $Path '.claude.json'
    if (-not (Test-Path -LiteralPath $arquivo -PathType Leaf)) {
        # O diretorio padrao guarda a identificacao um nivel acima.
        $herdado = Join-Path $env:USERPROFILE '.claude.json'
        if (
            (Test-PlanoDentroDe -Path $Path -Root (Join-Path $env:USERPROFILE '.claude')) -and
            (Test-Path -LiteralPath $herdado -PathType Leaf)
        ) {
            $arquivo = $herdado
        } else {
            return 'sem login'
        }
    }
    try {
        $dados = Get-Content -LiteralPath $arquivo -Raw -ErrorAction Stop | ConvertFrom-Json
    } catch {
        return 'ilegivel'
    }
    if ($dados.PSObject.Properties.Name -notcontains 'oauthAccount') { return 'sem login' }
    $conta = $dados.oauthAccount
    $email = if ($conta.PSObject.Properties.Name -contains 'emailAddress') { [string]$conta.emailAddress } else { '' }
    $org = if ($conta.PSObject.Properties.Name -contains 'organizationName') { [string]$conta.organizationName } else { '' }
    if ([string]::IsNullOrWhiteSpace($email)) { return 'sem login' }
    if ([string]::IsNullOrWhiteSpace($org)) { return $email }
    return "$email ($org)"
}

function Get-PlanoCredencial {
    <#
    .SYNOPSIS
    Le a validade da credencial de um diretorio de estado, sem tocar no segredo.

    .DESCRIPTION
    Devolve so metadados: se ha token util e ate quando. O valor do token nunca
    e lido para variavel, impresso nem registrado.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $arquivo = Join-Path $Path '.credentials.json'
    $vazio = [pscustomobject]@{ Arquivo = $arquivo; Existe = $false; TemToken = $false; ExpiraEm = 0 }
    if (-not (Test-Path -LiteralPath $arquivo -PathType Leaf)) { return $vazio }
    try {
        $dados = Get-Content -LiteralPath $arquivo -Raw -ErrorAction Stop | ConvertFrom-Json
    } catch {
        return $vazio
    }
    if ($dados.PSObject.Properties.Name -notcontains 'claudeAiOauth') { return $vazio }
    $oauth = $dados.claudeAiOauth
    $temToken = ($oauth.PSObject.Properties.Name -contains 'accessToken') -and
        -not [string]::IsNullOrWhiteSpace([string]$oauth.accessToken)
    $expira = 0
    if ($oauth.PSObject.Properties.Name -contains 'expiresAt') { $expira = [double]$oauth.expiresAt }
    return [pscustomobject]@{
        Arquivo = $arquivo
        Existe = $true
        TemToken = $temToken
        ExpiraEm = $expira
    }
}

function Copy-PlanoIdentidade {
    <#
    .SYNOPSIS
    Leva a identidade da conta e a marca de onboarding para um diretorio que
    ainda nao as tem.

    .DESCRIPTION
    Credencial sozinha nao basta, e sao dois os campos do .claude.json que a CLI
    consulta antes de olhar o token:

    - oauthAccount: sem ele a CLI ignora o token e pede login de novo. Medido em
      23/08/2026.
    - hasCompletedOnboarding: sem ele a CLI abre o assistente de primeira
      execucao, que traz o passo de login no meio, e o token valido ao lado nao
      e consultado. Medido em 02/09/2026 no diretorio padrao, que tinha token e
      oauthAccount e mesmo assim caiu na tela de login.

    Cada campo que falta e buscado na primeira origem da lista que o tenha; a
    marca de onboarding so e copiada quando e verdadeira na origem. Devolve os
    nomes dos campos gravados, ou nada quando nao havia o que gravar.

    A insercao e textual de proposito. Reserializar um .claude.json de dezenas de
    KB com ConvertTo-Json arrisca estourar profundidade e truncar o arquivo do
    usuario; aqui so os blocos pequenos sao serializados, e o resto do texto nao
    e tocado. O resultado e validado antes de substituir o arquivo.
    #>
    param(
        [Parameter(Mandatory)][string[]]$De,
        [Parameter(Mandatory)][string]$Para
    )

    $destino = Join-Path $Para '.claude.json'
    $texto = ''
    $atual = $null
    if (Test-Path -LiteralPath $destino -PathType Leaf) {
        $texto = [IO.File]::ReadAllText($destino)
        try {
            $atual = $texto | ConvertFrom-Json
        } catch {
            return @()
        }
    }

    $faltam = [ordered]@{}
    foreach ($campo in @('oauthAccount', 'hasCompletedOnboarding')) {
        if (($null -ne $atual) -and ($atual.PSObject.Properties.Name -contains $campo)) { continue }
        foreach ($origem in $De) {
            $arquivo = Join-Path $origem '.claude.json'
            if (-not (Test-Path -LiteralPath $arquivo -PathType Leaf)) { continue }
            try {
                $dados = Get-Content -LiteralPath $arquivo -Raw -ErrorAction Stop | ConvertFrom-Json
            } catch {
                continue
            }
            if ($dados.PSObject.Properties.Name -notcontains $campo) { continue }
            if (($campo -eq 'hasCompletedOnboarding') -and ($dados.$campo -ne $true)) { continue }
            $faltam[$campo] = ($dados.$campo | ConvertTo-Json -Depth 10 -Compress)
            break
        }
    }
    if ($faltam.Count -eq 0) { return @() }

    $partes = @()
    foreach ($campo in $faltam.Keys) { $partes += ('"' + $campo + '":' + $faltam[$campo]) }
    $bloco = $partes -join ','

    if ($null -eq $atual) {
        [IO.File]::WriteAllText($destino, '{' + $bloco + '}', [Text.UTF8Encoding]::new($false))
        return @($faltam.Keys)
    }

    $abre = $texto.IndexOf('{')
    if ($abre -lt 0) { return @() }
    $resto = $texto.Substring($abre + 1)
    $virgula = if ($resto.TrimStart().StartsWith('}')) { '' } else { ',' }
    $novo = $texto.Substring(0, $abre + 1) + $bloco + $virgula + $resto

    try {
        $null = $novo | ConvertFrom-Json
    } catch {
        return @()
    }
    [IO.File]::WriteAllText($destino, $novo, [Text.UTF8Encoding]::new($false))
    return @($faltam.Keys)
}

function Sync-PlanoCredencial {
    <#
    .SYNOPSIS
    Uma credencial por CONTA, nao por diretorio de estado.

    .DESCRIPTION
    Blindagem exige diretorios separados, mas login e da conta. Antes de subir,
    o diretorio com a credencial mais nova daquele lado abastece os irmaos que
    estejam vazios ou atrasados. Assim um /login em qualquer lugar do lado vale
    para o lado inteiro.

    Duas travas: a copia nunca atravessa lados - pessoal e corporativo sao contas
    diferentes - e so sai de diretorio cuja conta gravada e a declarada para
    aquele lado. Sem a segunda trava, um /login trocado dentro de um diretorio
    espalharia a conta errada por todos os irmaos, que e exatamente o defeito que
    este arranjo existe para impedir.
    #>
    param(
        [Parameter(Mandatory)][string]$Cli,
        [Parameter(Mandatory)][string]$Side
    )

    $rota = $script:PlanoRota[$Cli]
    if (-not $rota.ShareCredentials) { return }
    if (-not $rota.Accounts.ContainsKey($Side)) { return }
    $contaEsperada = $rota.Accounts[$Side]

    $irmaos = @()
    foreach ($chave in $rota.Dir.Keys) {
        if ($chave.StartsWith($Side + '|')) { $irmaos += $rota.Dir[$chave] }
    }
    if ($irmaos.Count -lt 2) { return }

    $melhor = $null
    foreach ($dir in $irmaos) {
        $cred = Get-PlanoCredencial -Path $dir
        if (-not $cred.TemToken) { continue }
        # So e fonte confiavel se a conta gravada la for a do lado.
        if ((Get-PlanoConta -Path $dir) -notlike ($contaEsperada + '*')) { continue }
        if (($null -eq $melhor) -or ($cred.ExpiraEm -gt $melhor.Cred.ExpiraEm)) {
            $melhor = [pscustomobject]@{ Home = $dir; Cred = $cred }
        }
    }
    if ($null -eq $melhor) { return }

    # Origens de identidade: todo irmao cuja conta gravada e a do lado, com o
    # dono da melhor credencial na frente. A lista e mais larga que a fonte da
    # credencial de proposito: o diretorio com o token mais novo pode ser
    # justamente o que nunca completou o onboarding.
    $origensIdentidade = @($melhor.Home)
    foreach ($dir in $irmaos) {
        if ($dir -eq $melhor.Home) { continue }
        if ((Get-PlanoConta -Path $dir) -like ($contaEsperada + '*')) { $origensIdentidade += $dir }
    }

    foreach ($dir in $irmaos) {
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        $cred = Get-PlanoCredencial -Path $dir
        $atrasado = ($dir -ne $melhor.Home) -and
            -not ($cred.TemToken -and ($cred.ExpiraEm -ge $melhor.Cred.ExpiraEm))
        # Diretorio com outra conta gravada nao e atrasado, e outro dono: avisar
        # e nao mexer vale mais do que sobrescrever.
        $contaDestino = Get-PlanoConta -Path $dir
        if (($contaDestino -ne 'sem login') -and ($contaDestino -notlike ($contaEsperada + '*'))) {
            if ($atrasado) {
                Write-Host ('    atencao: ' + $dir + ' esta logado em ' + $contaDestino +
                    ', e nao em ' + $contaEsperada + '. Credencial NAO copiada.') -ForegroundColor Red
            }
            continue
        }
        try {
            if ($atrasado) {
                Copy-Item -LiteralPath $melhor.Cred.Arquivo -Destination (Join-Path $dir '.credentials.json') -Force -ErrorAction Stop
                Write-Host ('    login   : credencial de ' + $contaEsperada + ' propagada para ' + $dir) -ForegroundColor DarkGray
            }
            # Token no lugar nao basta. Sem oauthAccount a CLI pede login; sem
            # hasCompletedOnboarding ela abre o assistente de primeira execucao,
            # que pede login no meio. Vale para todo irmao com token, inclusive
            # o que acabou de ser eleito fonte da credencial.
            $gravados = @(Copy-PlanoIdentidade -De $origensIdentidade -Para $dir)
            if ($gravados.Count -gt 0) {
                Write-Host ('    login   : ' + ($gravados -join ' e ') + ' gravado em ' + $dir) -ForegroundColor DarkGray
            }
        } catch {
            Write-Host ('    atencao: nao consegui propagar a credencial para ' + $dir) -ForegroundColor DarkYellow
        }
    }
}

function Get-PlanoResumo {
    <#
    .SYNOPSIS
    Junta identidade e validade de token numa frase so.

    .DESCRIPTION
    As duas coisas moram em arquivos diferentes e podem discordar: um diretorio
    pode ter token utilizavel e ainda nao ter identidade gravada, porque a CLI so
    escreve oauthAccount depois do primeiro uso. Dizer apenas "sem login" nesse
    estado e mentira util para ninguem.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $conta = Get-PlanoConta -Path $Path
    $cred = Get-PlanoCredencial -Path $Path
    $agora = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $validade = ''
    if ($cred.TemToken -and $cred.ExpiraEm -gt 0) {
        $quando = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$cred.ExpiraEm).LocalDateTime.ToString('dd/MM HH:mm')
        if ($cred.ExpiraEm -gt $agora) { $validade = 'token valido ate ' + $quando }
        else { $validade = 'token vencido em ' + $quando + ', renova sozinho' }
    }

    if ($conta -eq 'sem login') {
        if ($cred.TemToken) {
            $texto = 'identidade ainda nao gravada - ' + $validade
        } else {
            $texto = 'sem login'
        }
    } elseif ($validade) {
        $texto = $conta + ' - ' + $validade
    } else {
        $texto = $conta + ' - sem token'
    }

    return [pscustomobject]@{
        Conta = $conta
        TemToken = $cred.TemToken
        Texto = $texto
    }
}

function Get-PlanoSkill {
    param([Parameter(Mandatory)][string]$Path)
    $pasta = Join-Path $Path 'skills'
    if (-not (Test-Path -LiteralPath $pasta -PathType Container)) { return 0 }
    return @(Get-ChildItem -LiteralPath $pasta -Directory -ErrorAction SilentlyContinue).Count
}

function Write-PlanoCabecalho {
    <#
    .SYNOPSIS
    Imprime o cabecalho e garante credencial e historico antes de subir.

    .DESCRIPTION
    Imprimir e sincronizar andam juntos de proposito: o que aparece na tela e o
    estado com que a sessao vai subir, e nao o de antes da sincronizacao. Sao
    duas garantias distintas: a credencial e' da conta do lado, e o historico e'
    de todos os lados ao mesmo tempo.
    #>
    param(
        [Parameter(Mandatory)]$Plano,
        [Parameter(Mandatory)][string]$Pasta
    )
    Write-Host ''
    Write-Host ('  Plano ' + $Plano.Label) -ForegroundColor $Plano.Color
    Write-Host ('    estado : ' + $Plano.Home) -ForegroundColor DarkGray
    Write-Host ('    pasta  : ' + $Pasta) -ForegroundColor DarkGray

    Sync-PlanoCredencial -Cli $Plano.Cli -Side $Plano.Side
    Assert-PlanoCompartilhado -Cli $Plano.Cli -Estado $Plano.Home

    $rota = $script:PlanoRota[$Plano.Cli]
    if (-not [string]::IsNullOrWhiteSpace($rota.SharedRoot)) {
        Write-Host ('    historico: ' + $rota.SharedRoot + ' (comum aos planos)') -ForegroundColor DarkGray
    }
    $resumo = Get-PlanoResumo -Path $Plano.Home
    $conta = $resumo.Conta
    Write-Host ('    conta  : ' + $resumo.Texto) -ForegroundColor DarkGray
    if ($rota.Accounts.ContainsKey($Plano.Side)) {
        $esperada = $rota.Accounts[$Plano.Side]
        if (-not $resumo.TemToken) {
            Write-Host ('    atencao: sem credencial. Rode /login com ' + $esperada) -ForegroundColor DarkYellow
        } elseif (($conta -ne 'sem login') -and ($conta -notlike ($esperada + '*'))) {
            # Foi assim que uma sessao chamada "pessoal" apareceu gastando o
            # plano corporativo: o nome dizia uma coisa, a pasta guardava outra.
            Write-Host ('    ERRO   : este plano deveria ser ' + $esperada +
                ' e esta em ' + $conta) -ForegroundColor Red
        }
    }

    if ($Plano.Shield -eq 'aberto') {
        Write-Host '    atencao: SEM BLINDAGEM - enxerga skills, hooks e agents do perfil do usuario' -ForegroundColor DarkYellow
    }
    foreach ($raiz in $script:PlanoRota[$Plano.Cli].WarnPersonalUnder) {
        if ($Plano.Side -ne $script:PlanoRota[$Plano.Cli].DefaultSide) { break }
        if (Test-PlanoDentroDe -Path $Pasta -Root $raiz) {
            Write-Host ('    atencao: pasta sob ' + $raiz + ' abrindo no plano ' + $Plano.Label) -ForegroundColor Red
            break
        }
    }
    if (-not (Test-Path -LiteralPath $Plano.Home -PathType Container)) {
        Write-Host '    atencao: diretorio de estado ainda nao existe; a CLI vai cria-lo' -ForegroundColor DarkYellow
    }
    Write-Host ''
}

function Merge-PlanoPasta {
    <#
    .SYNOPSIS
    Move o conteudo de uma pasta solta para o store, descendo nas subpastas que
    existem dos dois lados. Devolve $true quando a origem ficou vazia.

    .DESCRIPTION
    Sessao aberta durante o religamento grava na mesma subpasta dos dois lados.
    Mover so o que nao existia no destino deixava essa subpasta para tras, e o
    vinculo nunca era refeito: a pasta crescia ate passar do limite. Arquivo
    igual dos dois lados sai da origem; arquivo diferente vai para Conflitos,
    com o caminho relativo preservado. Nada e' sobrescrito.
    #>
    param(
        [Parameter(Mandatory)][string]$Origem,
        [Parameter(Mandatory)][string]$Destino,
        [Parameter(Mandatory)][string]$Conflitos
    )
    $ok = $true
    foreach ($filho in @(Get-ChildItem -LiteralPath $Origem -Force -ErrorAction SilentlyContinue)) {
        $para = Join-Path $Destino $filho.Name
        $existente = Get-Item -LiteralPath $para -Force -ErrorAction SilentlyContinue
        $ehLink = [bool]($filho.Attributes -band [IO.FileAttributes]::ReparsePoint)
        try {
            if (-not $existente) {
                Move-Item -LiteralPath $filho.FullName -Destination $para -ErrorAction Stop
            } elseif ($filho.PSIsContainer -and $existente.PSIsContainer -and -not $ehLink) {
                if (Merge-PlanoPasta -Origem $filho.FullName -Destino $para -Conflitos (Join-Path $Conflitos $filho.Name)) {
                    [IO.Directory]::Delete($filho.FullName, $false)
                } else {
                    $ok = $false
                }
            } elseif (-not $filho.PSIsContainer -and -not $existente.PSIsContainer) {
                if ((Get-FileHash -LiteralPath $filho.FullName).Hash -eq (Get-FileHash -LiteralPath $para).Hash) {
                    Remove-Item -LiteralPath $filho.FullName -Force -ErrorAction Stop
                } else {
                    $null = New-Item -ItemType Directory -Path $Conflitos -Force
                    $guarda = Join-Path $Conflitos $filho.Name
                    if (Test-Path -LiteralPath $guarda) { $guarda = $guarda + '.' + (Get-Date -Format 'yyyyMMddHHmmss') }
                    Move-Item -LiteralPath $filho.FullName -Destination $guarda -ErrorAction Stop
                }
            } else {
                # Pasta de um lado e arquivo do outro, ou link: decidir e' do script completo.
                $ok = $false
            }
        } catch {
            $ok = $false
        }
    }
    return $ok
}

function Assert-PlanoCompartilhado {
    <#
    .SYNOPSIS
    Garante que o historico do plano aponta para o store comum antes de subir.

    .DESCRIPTION
    Sessao, memoria e anexos sao um store so para todos os lados: ligar isso uma
    vez nao basta, porque a CLI recria qualquer pasta que falte e, no dia em que
    recriar, aquele plano volta a gravar num canto proprio - em silencio. Esta
    funcao roda a cada abertura e refaz o vinculo. Conta e blindagem nao passam
    por aqui: .claude.json, .credentials.json, settings.json, skills e agents
    continuam sendo de cada plano.

    Pasta recriada com conteudo e' mesclada, nunca sobrescrita. Se a mescla for
    grande demais para a abertura de um terminal, ela e' recusada com o nome do
    script que faz o trabalho completo - travar a subida da CLI seria pior que o
    problema que ela resolve.
    #>
    param(
        [Parameter(Mandatory)][string]$Cli,
        # Nao se chama Home: $Home e' automatica e somente leitura, e o parametro
        # com esse nome derruba a funcao inteira na primeira atribuicao.
        [Parameter(Mandatory)][string]$Estado
    )

    $rota = $script:PlanoRota[$Cli]
    if ([string]::IsNullOrWhiteSpace($rota.SharedRoot)) { return }
    # Diretorio que ainda nao existe e' da CLI criar. Ligar antes seria adivinhar.
    if (-not (Test-Path -LiteralPath $Estado -PathType Container)) { return }

    $limite = 500

    foreach ($nome in $rota.SharedFolders) {
        $alvo = Join-Path $rota.SharedRoot $nome
        $link = Join-Path $Estado $nome
        if (-not (Test-Path -LiteralPath $alvo -PathType Container)) {
            $null = New-Item -ItemType Directory -Path $alvo -Force
        }

        $item = Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            $destino = [string](@($item.Target) | Select-Object -First 1)
            if (
                $destino -and
                ([IO.Path]::GetFullPath($destino).TrimEnd('\') -eq $alvo.TrimEnd('\'))
            ) {
                continue
            }
            [IO.Directory]::Delete($link, $false)
            $item = $null
        }

        if ($item) {
            $dentro = @(Get-ChildItem -LiteralPath $link -Recurse -Force -ErrorAction SilentlyContinue)
            if ($dentro.Count -gt $limite) {
                Write-Host (
                    '    atencao: ' + $nome + ' voltou a ser pasta propria com ' + $dentro.Count +
                    ' itens. Rode scripts\unify-plan-sessions.ps1 -Execute'
                ) -ForegroundColor Red
                continue
            }
            # Mesmo formato do unify-plan-sessions.ps1: .conflitos\<pasta>\<plano>\...
            $rotulo = Split-Path -Leaf $Estado
            foreach ($chave in @($rota.Dir.Keys)) {
                if ([IO.Path]::GetFullPath($rota.Dir[$chave]).TrimEnd('\') -eq [IO.Path]::GetFullPath($Estado).TrimEnd('\')) {
                    $rotulo = $chave.Replace('|', '-')
                }
            }
            $conflitos = Join-Path (Join-Path (Join-Path $rota.SharedRoot '.conflitos') $nome) $rotulo
            $sobrou = -not (Merge-PlanoPasta -Origem $link -Destino $alvo -Conflitos $conflitos)
            if ($sobrou) {
                Write-Host (
                    '    atencao: ' + $nome + ' tem itens que nao puderam ser unidos. ' +
                    'Rode scripts\unify-plan-sessions.ps1 -Execute'
                ) -ForegroundColor Red
                continue
            }
            Remove-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue
        }

        try {
            $null = New-Item -ItemType Junction -Path $link -Target $alvo -ErrorAction Stop
            Write-Host ('    religado: ' + $nome + ' -> store comum') -ForegroundColor DarkYellow
        } catch {
            Write-Host ('    atencao: nao consegui religar ' + $nome) -ForegroundColor Red
        }
    }

    foreach ($nome in $rota.SharedFiles) {
        $alvo = Join-Path $rota.SharedRoot $nome
        $link = Join-Path $Estado $nome
        $temAlvo = Test-Path -LiteralPath $alvo -PathType Leaf
        $temLink = Test-Path -LiteralPath $link -PathType Leaf

        if ($temAlvo -and $temLink) {
            # Hardlink e' o mesmo arquivo: tamanho e data batem por definicao.
            # Se divergiram, a ligacao se rompeu e as duas pontas tem conteudo.
            $a = Get-Item -LiteralPath $alvo -Force
            $b = Get-Item -LiteralPath $link -Force
            if (($a.Length -eq $b.Length) -and ($a.LastWriteTimeUtc -eq $b.LastWriteTimeUtc)) { continue }
        }

        $linhas = [Collections.Generic.List[string]]::new()
        $vistas = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($fonte in @($alvo, $link)) {
            if (-not (Test-Path -LiteralPath $fonte -PathType Leaf)) { continue }
            foreach ($linha in Get-Content -LiteralPath $fonte -ErrorAction SilentlyContinue) {
                if ([string]::IsNullOrWhiteSpace($linha)) { continue }
                if ($vistas.Add($linha)) { $linhas.Add($linha) }
            }
        }
        $ordenadas = @(
            $linhas | Sort-Object -Property @{ Expression = {
                if ($_ -match '"timestamp"\s*:\s*(\d+)') { [long]$Matches[1] } else { 0 }
            } }
        )
        try {
            if (-not (Test-Path -LiteralPath $rota.SharedRoot -PathType Container)) {
                $null = New-Item -ItemType Directory -Path $rota.SharedRoot -Force
            }
            Set-Content -LiteralPath $alvo -Value $ordenadas -Encoding utf8NoBOM -ErrorAction Stop
            if ($temLink) { Remove-Item -LiteralPath $link -Force -ErrorAction Stop }
            $null = New-Item -ItemType HardLink -Path $link -Target $alvo -ErrorAction Stop
            Write-Host ('    religado: ' + $nome + ' (' + $ordenadas.Count + ' linhas)') -ForegroundColor DarkYellow
        } catch {
            Write-Host ('    atencao: nao consegui religar ' + $nome) -ForegroundColor Red
        }
    }
}

function Save-PlanoCredencialEnv {
    <#
    .SYNOPSIS
    Retira do processo as variaveis de credencial da rota e devolve o que havia.

    .DESCRIPTION
    Chave de API no ambiente passa na frente do login do plano. Numa sessao
    interativa isso troca a conta em silencio, e se a organizacao so tiver o
    credito incluso no plano a sessao cai por falta de saldo. O valor e'
    guardado so para ser devolvido depois; nunca e' impresso.
    #>
    param([Parameter(Mandatory)][string]$Cli)
    $guardadas = @{}
    foreach ($nome in @($script:PlanoRota[$Cli].CredentialEnv)) {
        if (Test-Path ('Env:\' + $nome)) {
            $guardadas[$nome] = [Environment]::GetEnvironmentVariable($nome)
            [Environment]::SetEnvironmentVariable($nome, [NullString]::Value)
        }
    }
    return $guardadas
}

function Restore-PlanoCredencialEnv {
    param([Parameter(Mandatory)][hashtable]$Guardadas)
    foreach ($nome in @($Guardadas.Keys)) {
        [Environment]::SetEnvironmentVariable($nome, $Guardadas[$nome])
    }
}

function Get-PlanoArgumentoLimpo {
    <#
    .SYNOPSIS
    Injeta as flags obrigatorias uma vez so e descarta as que vieram digitadas.

    .DESCRIPTION
    Digitada a mao - inclusive errada, no singular - a CLI recusava a flag com
    "unknown option" e a sessao morria antes de comecar.
    #>
    param(
        [Parameter(Mandatory)][string]$Cli,
        [AllowEmptyCollection()][object[]]$Rest = @()
    )
    $rota = $script:PlanoRota[$Cli]
    $limpos = @()
    $corrigiu = $false
    foreach ($argumento in @($Rest)) {
        $descartar = $false
        foreach ($flag in $rota.Flags) {
            if (($argumento -is [string]) -and ($argumento -match ('^' + [regex]::Escape($flag) + '?$'))) {
                if ($argumento -cne $flag) { $corrigiu = $true }
                $descartar = $true
                break
            }
        }
        if (-not $descartar) { $limpos += $argumento }
    }
    return [pscustomobject]@{
        Argumentos = @(@($rota.Flags) + @($limpos))
        Corrigiu = $corrigiu
    }
}

function Invoke-PlanoCli {
    param(
        [Parameter(Mandatory)][string]$Cli,
        [Parameter(Mandatory)][string]$Side,
        [Parameter(ValueFromRemainingArguments)][object[]]$Rest
    )

    $rota = $script:PlanoRota[$Cli]
    $pasta = Get-PlanoPastaAtual
    $plano = Resolve-PlanoEstado -Cli $Cli -Path $pasta -Side $Side
    $limpo = Get-PlanoArgumentoLimpo -Cli $Cli -Rest @($Rest)

    Write-PlanoCabecalho -Plano $plano -Pasta $pasta
    if ($limpo.Corrigiu) {
        Write-Host '  (flag corrigida para a forma aceita pela CLI)' -ForegroundColor DarkGray
    }

    $argumentos = $limpo.Argumentos
    $had = Test-Path ('Env:\' + $rota.Variable)
    $anterior = [Environment]::GetEnvironmentVariable($rota.Variable)
    $guardadas = Save-PlanoCredencialEnv -Cli $Cli
    try {
        if ($guardadas.Count -gt 0) {
            Write-Host ('  ' + (@($guardadas.Keys) -join ', ') +
                ' fora desta sessao: passaria na frente do plano e a sessao cobraria a API.') -ForegroundColor Yellow
            if ($rota.ApiKey) {
                Write-Host ('  Para usar a API de proposito: ' + (@($rota.ApiKey.Command.Values) -join ' ou ') +
                    ' ' + $rota.Command + ' -p "..."') -ForegroundColor DarkGray
            }
        }
        [Environment]::SetEnvironmentVariable($rota.Variable, $plano.Home)
        & (Resolve-CliExecutable -Command $rota.Command) @argumentos
    } finally {
        # Restaurar evita que a aba continue apontando para o plano trocado
        # depois que a CLI sai. [NullString]::Value remove de verdade nos dois
        # hosts; $null viraria string vazia no PowerShell 7.
        if ($had) {
            [Environment]::SetEnvironmentVariable($rota.Variable, $anterior)
        } else {
            [Environment]::SetEnvironmentVariable($rota.Variable, [NullString]::Value)
        }
        Restore-PlanoCredencialEnv -Guardadas $guardadas
    }
}

function Get-PlanoArgValor {
    # Valor de uma flag nos dois formatos: "--nome valor" e "--nome=valor".
    param([AllowEmptyCollection()][object[]]$Lista = @(), [Parameter(Mandatory)][string]$Nome)
    $itens = @($Lista)
    for ($i = 0; $i -lt $itens.Count; $i++) {
        $a = [string]$itens[$i]
        if ($a -eq $Nome -and ($i + 1) -lt $itens.Count) { return [string]$itens[$i + 1] }
        if ($a.StartsWith($Nome + '=')) { return $a.Substring($Nome.Length + 1) }
    }
    return $null
}

function Get-PlanoApiOrcamento {
    param([Parameter(Mandatory)][string]$Cli)
    $api = $script:PlanoRota[$Cli].ApiKey
    if (-not (Test-Path -LiteralPath $api.BudgetFile)) {
        Write-Host ('  Orcamento de credito nao encontrado: ' + $api.BudgetFile) -ForegroundColor Red
        return $null
    }
    try {
        return (Get-Content -LiteralPath $api.BudgetFile -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        Write-Host ('  Orcamento de credito ilegivel: ' + $api.BudgetFile) -ForegroundColor Red
        return $null
    }
}

function Get-PlanoApiCiclo {
    <#
    .SYNOPSIS
    Inicio e fim do ciclo de cobranca corrente de um lado.

    .DESCRIPTION
    O credito renova no dia de cobranca da assinatura, nao no dia 1. Mes curto
    leva o dia para o ultimo dia do mes.
    #>
    param([Parameter(Mandatory)]$Orcamento, [Parameter(Mandatory)][string]$Side)
    $dia = 1
    $porCiclo = 0.0
    if ($Orcamento.lados.PSObject.Properties.Name -contains $Side) {
        $cfg = $Orcamento.lados.$Side
        if ($cfg.PSObject.Properties.Name -contains 'renovacaoDia') { $dia = [int]$cfg.renovacaoDia }
        if ($cfg.PSObject.Properties.Name -contains 'porCiclo') { $porCiclo = [double]$cfg.porCiclo }
    }
    $hoje = (Get-Date).Date
    $ini = New-Object DateTime ($hoje.Year, $hoje.Month, [Math]::Min($dia, [DateTime]::DaysInMonth($hoje.Year, $hoje.Month)))
    if ($ini -gt $hoje) {
        $m = $hoje.AddMonths(-1)
        $ini = New-Object DateTime ($m.Year, $m.Month, [Math]::Min($dia, [DateTime]::DaysInMonth($m.Year, $m.Month)))
    }
    $p = $ini.AddMonths(1)
    $fim = New-Object DateTime ($p.Year, $p.Month, [Math]::Min($dia, [DateTime]::DaysInMonth($p.Year, $p.Month)))
    return [pscustomobject]@{ Inicio = $ini; Fim = $fim; PorCiclo = $porCiclo }
}

function Find-PlanoApiAlocacao {
    <#
    .SYNOPSIS
    Alocacao da pasta corrente naquele lado; a raiz mais especifica vence.

    .DESCRIPTION
    Uma alocacao pode ter mais de uma raiz ("raiz" e/ou "raizes"): todas dividem
    o mesmo teto e o mesmo gasto. Serve para trabalho que o projeto roda de
    proposito fora da propria pasta - pesquisa em pasta neutra, por exemplo.
    #>
    param([Parameter(Mandatory)]$Orcamento, [Parameter(Mandatory)][string]$Side, [Parameter(Mandatory)][string]$Pasta)
    $melhor = $null
    $melhorTamanho = -1
    foreach ($a in @($Orcamento.alocacoes)) {
        if ([string]$a.lado -ne $Side) { continue }
        $raizes = @()
        if ($a.PSObject.Properties.Name -contains 'raiz') { $raizes += [string]$a.raiz }
        if ($a.PSObject.Properties.Name -contains 'raizes') { $raizes += @($a.raizes | ForEach-Object { [string]$_ }) }
        foreach ($r in $raizes) {
            if ([string]::IsNullOrWhiteSpace($r)) { continue }
            if (-not (Test-PlanoDentroDe -Path $Pasta -Root $r)) { continue }
            if ($r.Length -gt $melhorTamanho) {
                $melhor = $a
                $melhorTamanho = $r.Length
            }
        }
    }
    return $melhor
}

function Get-PlanoApiRegistro {
    # Entradas do registro dentro do ciclo. Custo medido vale; sem medida, vale o teto.
    param([Parameter(Mandatory)][string]$Arquivo, [Parameter(Mandatory)]$Ciclo)
    $saida = @()
    if (-not (Test-Path -LiteralPath $Arquivo)) { return $saida }
    foreach ($linha in Get-Content -LiteralPath $Arquivo -Encoding UTF8) {
        if ([string]::IsNullOrWhiteSpace($linha)) { continue }
        try { $e = $linha | ConvertFrom-Json } catch { continue }
        # O PowerShell 7 ja entrega data ISO convertida em DateTime; o 5.1 entrega texto.
        if ($e.quando -is [datetime]) {
            $quando = $e.quando
        } else {
            $quando = [datetime]::ParseExact([string]$e.quando, 'yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
        }
        if ($quando -lt $Ciclo.Inicio -or $quando -ge $Ciclo.Fim) { continue }
        $valor = 0.0
        if ($null -ne $e.custo) { $valor = [double]$e.custo } elseif ($null -ne $e.teto) { $valor = [double]$e.teto }
        $saida += [pscustomobject]@{ Lado = [string]$e.lado; Projeto = [string]$e.projeto; Valor = $valor; Medido = ($null -ne $e.custo) }
    }
    return $saida
}

function Test-PlanoApiOrcamento {
    <#
    .SYNOPSIS
    Decide se a chamada cabe na alocacao do projeto no ciclo. Imprime o motivo
    da recusa e devolve $null; ou devolve a conta da chamada.
    #>
    param(
        [Parameter(Mandatory)][string]$Cli,
        [Parameter(Mandatory)][string]$Side,
        [Parameter(Mandatory)][string]$Pasta,
        [Parameter(Mandatory)][bool]$EhCli,
        [AllowEmptyCollection()][object[]]$Argumentos = @()
    )
    $api = $script:PlanoRota[$Cli].ApiKey
    $orc = Get-PlanoApiOrcamento -Cli $Cli
    if (-not $orc) { return $null }
    $aloc = Find-PlanoApiAlocacao -Orcamento $orc -Side $Side -Pasta $Pasta
    if (-not $aloc) {
        Write-Host ('  Recusado: sem alocacao de credito ' + $Side + ' para ' + $Pasta + '.') -ForegroundColor Red
        Write-Host ('  O orcamento e do repositorio que gerencia os planos (' + $api.BudgetFile + '): peca ao dono.') -ForegroundColor DarkGray
        return $null
    }
    $teto = $null
    $captura = $false
    if ($EhCli) {
        $texto = Get-PlanoArgValor -Lista $Argumentos -Nome '--max-budget-usd'
        $n = 0.0
        if ([string]::IsNullOrWhiteSpace($texto) -or
            -not [double]::TryParse($texto, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$n) -or
            $n -le 0) {
            Write-Host '  Recusado: toda chamada precisa de --max-budget-usd <valor> (ex.: --max-budget-usd 1).' -ForegroundColor Red
            return $null
        }
        $teto = $n
        $formato = Get-PlanoArgValor -Lista $Argumentos -Nome '--output-format'
        $captura = ($formato -eq 'json') -or ($formato -eq 'stream-json')
    }
    $ciclo = Get-PlanoApiCiclo -Orcamento $orc -Side $Side
    $gasto = 0.0
    foreach ($e in @(Get-PlanoApiRegistro -Arquivo $api.LedgerFile -Ciclo $ciclo)) {
        if ($e.Lado -eq $Side -and $e.Projeto -eq [string]$aloc.projeto) { $gasto += $e.Valor }
    }
    $limite = [double]$aloc.teto
    $reserva = 0.0
    if ($null -ne $teto) { $reserva = $teto }
    if (($gasto + $reserva) -gt ($limite + 0.000001)) {
        Write-Host ('  Recusado: ' + [string]$aloc.projeto + ' ja gastou US$ ' + $gasto.ToString('0.00', [Globalization.CultureInfo]::InvariantCulture) +
            ' de US$ ' + $limite.ToString('0.00', [Globalization.CultureInfo]::InvariantCulture) + ' (' + $Side + ', ciclo ' +
            $ciclo.Inicio.ToString('dd/MM') + ' a ' + $ciclo.Fim.AddDays(-1).ToString('dd/MM') + ')' +
            $(if ($null -ne $teto) { '; esta chamada pede ate US$ ' + $teto.ToString('0.00', [Globalization.CultureInfo]::InvariantCulture) } else { '' }) + '.') -ForegroundColor Red
        Write-Host '  Mais credito para o projeto e decisao do dono, no orcamento do repositorio que gerencia os planos.' -ForegroundColor DarkGray
        return $null
    }
    return [pscustomobject]@{
        Projeto = [string]$aloc.projeto
        Teto = $teto
        Limite = $limite
        Gasto = $gasto
        Captura = $captura
        Ciclo = $ciclo
    }
}

function Add-PlanoApiRegistro {
    # Uma linha JSON por chamada. Varias sessoes podem gravar juntas: tenta de novo.
    param([Parameter(Mandatory)][string]$Arquivo, [Parameter(Mandatory)]$Dados)
    $linha = ([pscustomobject]$Dados | ConvertTo-Json -Compress) + "`n"
    $pasta = Split-Path -Parent $Arquivo
    if (-not (Test-Path -LiteralPath $pasta)) { $null = New-Item -ItemType Directory -Path $pasta -Force }
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($linha)
    for ($i = 0; $i -lt 20; $i++) {
        try {
            $fs = [IO.File]::Open($Arquivo, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read)
            try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Close() }
            return
        } catch {
            Start-Sleep -Milliseconds 150
        }
    }
    Write-Host ('  atencao: nao consegui gravar o registro de credito em ' + $Arquivo) -ForegroundColor Red
}

function Show-PlanoApiSaldo {
    param([Parameter(Mandatory)][string]$Cli)
    $api = $script:PlanoRota[$Cli].ApiKey
    $orc = Get-PlanoApiOrcamento -Cli $Cli
    if (-not $orc) { return }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    Write-Host ''
    Write-Host ('  Credito de API - orcamento: ' + $api.BudgetFile) -ForegroundColor White
    foreach ($lado in @($api.Entry.Keys | Sort-Object)) {
        $ciclo = Get-PlanoApiCiclo -Orcamento $orc -Side $lado
        $entradas = @(Get-PlanoApiRegistro -Arquivo $api.LedgerFile -Ciclo $ciclo | Where-Object { $_.Lado -eq $lado })
        $alocs = @($orc.alocacoes | Where-Object { [string]$_.lado -eq $lado })
        $alocado = 0.0; foreach ($a in $alocs) { $alocado += [double]$a.teto }
        $gasto = 0.0; foreach ($e in $entradas) { $gasto += $e.Valor }
        $cor = 'Gray'
        if ($script:PlanoRota[$Cli].Color.ContainsKey($lado + '|blindado')) { $cor = $script:PlanoRota[$Cli].Color[$lado + '|blindado'] }
        Write-Host ''
        Write-Host ('  ' + $lado + '  ciclo ' + $ciclo.Inicio.ToString('dd/MM') + ' a ' + $ciclo.Fim.AddDays(-1).ToString('dd/MM') +
            '   US$ ' + $ciclo.PorCiclo.ToString('0', $inv) + ' por ciclo   alocado ' + $alocado.ToString('0.00', $inv) +
            '   gasto ' + $gasto.ToString('0.00', $inv) + '   livre ' + ($ciclo.PorCiclo - $gasto).ToString('0.00', $inv)) -ForegroundColor $cor
        if ($alocado -gt $ciclo.PorCiclo) {
            Write-Host ('     atencao: alocado passa do credito do ciclo') -ForegroundColor Red
        }
        foreach ($a in $alocs) {
            $doProjeto = @($entradas | Where-Object { $_.Projeto -eq [string]$a.projeto })
            $g = 0.0; foreach ($e in $doProjeto) { $g += $e.Valor }
            $estimadas = @($doProjeto | Where-Object { -not $_.Medido }).Count
            $nota = ''
            if ($estimadas -gt 0) { $nota = '   (' + $estimadas + ' sem custo medido, contadas pelo teto)' }
            Write-Host ('     {0,-16} teto {1,7}   gasto {2,7}   resta {3,7}   {4} chamada(s){5}' -f [string]$a.projeto,
                ([double]$a.teto).ToString('0.00', $inv), $g.ToString('0.00', $inv), ([double]$a.teto - $g).ToString('0.00', $inv),
                $doProjeto.Count, $nota) -ForegroundColor DarkGray
        }
    }
    Write-Host ''
}

function Invoke-PlanoApi {
    <#
    .SYNOPSIS
    Roda um comando com a chave de API do lado, so no processo filho.

    .DESCRIPTION
    A chave sai do cofre para uma variavel local, entra no ambiente so durante
    a chamada e e' removida no fim, com qualquer valor anterior devolvido. Nunca
    e' impressa. A CLI da rota so roda em modo nao interativo: a sessao
    interativa nao e' coberta pelo credito de API e cairia por falta de saldo.
    #>
    param(
        [Parameter(Mandatory)][string]$Cli,
        [Parameter(Mandatory)][string]$Side,
        [Parameter(ValueFromRemainingArguments)][object[]]$Rest
    )

    $rota = $script:PlanoRota[$Cli]
    $api = $rota.ApiKey
    $nome = $api.Command[$Side]
    $itens = @($Rest)
    if ($itens.Count -eq 0) {
        Write-Host ''
        Write-Host ('  Uso: ' + $nome + ' <comando> [argumentos]')
        Write-Host ('  ex.: ' + $nome + ' ' + $rota.Command + ' ' + ($api.PrintFlags | Select-Object -First 1) + ' "resuma o README"')
        Write-Host ('       ' + $nome + ' py -3 meu_agente.py')
        Write-Host ('  A chave vem do cofre (' + $api.Entry[$Side] + ') e existe so no processo filho.') -ForegroundColor DarkGray
        Write-Host ('  Cobra a organizacao de API vinculada ao plano ' + $Side + ', nunca o limite do plano.') -ForegroundColor DarkGray
        Write-Host ''
        return
    }

    $programa = [string]$itens[0]
    $resto = @($itens | Select-Object -Skip 1)
    $plano = $null
    if ($programa -eq $rota.Command) {
        $temPrint = $false
        foreach ($argumento in $resto) {
            if (($argumento -is [string]) -and ($api.PrintFlags -contains $argumento)) { $temPrint = $true }
        }
        if ((@($api.PrintFlags).Count -gt 0) -and -not $temPrint) {
            Write-Host ('  Recusado: ' + $nome + ' ' + $programa + ' sem ' + ($api.PrintFlags -join ' ou ') + '.') -ForegroundColor Red
            Write-Host '  Sessao interativa nao e coberta pelo credito de API e cairia por falta de saldo.' -ForegroundColor DarkGray
            Write-Host ('  Para conversar, use o comando do plano: ' + $rota.Command + '.') -ForegroundColor DarkGray
            return
        }
        $plano = Resolve-PlanoEstado -Cli $Cli -Path (Get-PlanoPastaAtual) -Side $Side
        $resto = (Get-PlanoArgumentoLimpo -Cli $Cli -Rest $resto).Argumentos
        $programa = Resolve-CliExecutable -Command $rota.Command
    }

    # Orcamento antes do cofre: recusa nao deve pedir senha a ninguem.
    $conta = $null
    if (-not [string]::IsNullOrWhiteSpace($api.BudgetFile)) {
        $conta = Test-PlanoApiOrcamento -Cli $Cli -Side $Side -Pasta (Get-PlanoPastaAtual) -EhCli ([bool]$plano) -Argumentos $resto
        if (-not $conta) { return }
    }

    if (-not (Test-Path -LiteralPath $api.VaultScript)) {
        Write-Host ('  Cofre indisponivel: script nao encontrado em ' + $api.VaultScript) -ForegroundColor Red
        return
    }
    if (-not (Test-Path -LiteralPath $api.VaultFile)) {
        Write-Host ('  Cofre indisponivel: arquivo nao encontrado em ' + $api.VaultFile) -ForegroundColor Red
        return
    }
    $runner = @($api.Runner)
    $argsCofre = @($runner | Select-Object -Skip 1) + @($api.VaultScript, '--vault', $api.VaultFile, 'get', $api.Entry[$Side], '--show')
    # Escopo proprio com Continue: no Windows PowerShell 5.1, sob Stop, o stderr
    # do cofre vira excecao mesmo com 2>$null e a mensagem abaixo nunca sairia.
    $valor = (& {
        $ErrorActionPreference = 'Continue'
        & $runner[0] @argsCofre 2>$null
    } | Out-String).Trim()
    if (($LASTEXITCODE -ne 0) -or [string]::IsNullOrEmpty($valor)) {
        $valor = $null
        Write-Host ('  Sem chave no cofre: ' + $api.Entry[$Side] + ' em ' + (Split-Path -Leaf $api.VaultFile) + '.') -ForegroundColor Red
        Write-Host '  Crie a chave na organizacao de API vinculada a este plano e guarde com:' -ForegroundColor DarkGray
        Write-Host ('    ' + ($runner -join ' ') + ' ' + $api.VaultScript + ' --vault ' + $api.VaultFile + ' set ' + $api.Entry[$Side]) -ForegroundColor DarkGray
        return
    }

    $cor = 'Gray'
    if ($plano) { $cor = $plano.Color } elseif ($rota.Color.ContainsKey($Side + '|blindado')) { $cor = $rota.Color[$Side + '|blindado'] }
    Write-Host ''
    Write-Host ('  API ' + $Side + ': cobra a organizacao vinculada ao plano ' + $Side + ', nao o limite do plano') -ForegroundColor $cor
    Write-Host ('    chave : cofre ' + (Split-Path -Leaf $api.VaultFile) + ' / ' + $api.Entry[$Side] + ' (so no processo filho)') -ForegroundColor DarkGray
    if ($conta) {
        $inv = [Globalization.CultureInfo]::InvariantCulture
        Write-Host ('    conta : ' + $conta.Projeto + ' gastou US$ ' + $conta.Gasto.ToString('0.00', $inv) + ' de US$ ' +
            $conta.Limite.ToString('0.00', $inv) + ' no ciclo' +
            $(if ($null -ne $conta.Teto) { '; teto desta chamada US$ ' + $conta.Teto.ToString('0.00', $inv) } else { '' })) -ForegroundColor DarkGray
    }
    if ($plano) {
        Write-Host ('    estado: ' + $plano.Home) -ForegroundColor DarkGray
        # O historico continua comum: a transcricao do -p cai no mesmo armazem.
        Assert-PlanoCompartilhado -Cli $Cli -Estado $plano.Home
    }
    Write-Host ''

    $had = Test-Path ('Env:\' + $rota.Variable)
    $anterior = [Environment]::GetEnvironmentVariable($rota.Variable)
    $guardadas = Save-PlanoCredencialEnv -Cli $Cli
    $inicio = Get-Date
    $custo = $null
    $sessao = $null
    $codigo = $null
    $falhaInicio = $null
    try {
        if ($plano) { [Environment]::SetEnvironmentVariable($rota.Variable, $plano.Home) }
        [Environment]::SetEnvironmentVariable($api.Variable, $valor)
        $valor = $null
        # "Nao reconhecido" para um caminho que existe ja aconteceu uma vez, sem
        # repetir: a pasta do node e' um link que o gerenciador de versoes troca.
        # Uma segunda tentativa cobre isso; se falhar de novo, sai o diagnostico.
        for ($tentativa = 1; $tentativa -le 2; $tentativa++) {
            try {
                if ($conta -and $conta.Captura) {
                    # Saida JSON so chega no fim: ler a linha no caminho nao atrasa nada.
                    # UTF-8 durante a chamada para acento nao virar lixo no console.
                    $codificacao = [Console]::OutputEncoding
                    try {
                        [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
                        & $programa @resto | ForEach-Object {
                            $_
                            $texto = [string]$_
                            if ($texto -match '"total_cost_usd"\s*:\s*([0-9.eE+-]+)') {
                                $custo = [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture)
                            }
                            if ($texto -match '"session_id"\s*:\s*"([^"]+)"') { $sessao = $Matches[1] }
                        }
                    } finally {
                        [Console]::OutputEncoding = $codificacao
                    }
                } else {
                    & $programa @resto
                }
                $falhaInicio = $null
                break
            } catch [System.Management.Automation.CommandNotFoundException] {
                $falhaInicio = $_.Exception.Message
                if ($tentativa -lt 2) { Start-Sleep -Milliseconds 800 }
            }
        }
        if ($falhaInicio) {
            Write-Host ('  Nao consegui iniciar o programa (2 tentativas): ' + $falhaInicio) -ForegroundColor Red
            Write-Host ('    caminho: [' + [string]$programa + '] tamanho ' + ([string]$programa).Length +
                ' | existe: ' + (Test-Path -LiteralPath ([string]$programa)) +
                ' | pasta: ' + (Get-PlanoPastaAtual) + ' | PowerShell ' + $PSVersionTable.PSVersion) -ForegroundColor DarkGray
            Write-Host '    Nada foi cobrado: o registro anota custo 0.' -ForegroundColor DarkGray
        } else {
            $codigo = $LASTEXITCODE
        }
    } finally {
        [Environment]::SetEnvironmentVariable($api.Variable, [NullString]::Value)
        if ($plano) {
            if ($had) {
                [Environment]::SetEnvironmentVariable($rota.Variable, $anterior)
            } else {
                [Environment]::SetEnvironmentVariable($rota.Variable, [NullString]::Value)
            }
        }
        Restore-PlanoCredencialEnv -Guardadas $guardadas
        if ($conta) {
            # Gravado mesmo se a chamada for interrompida: sem custo medido, conta o
            # teto. Programa que nem iniciou nao gastou nada: custo 0, com o motivo.
            if ($falhaInicio) { $custo = 0.0 }
            Add-PlanoApiRegistro -Arquivo $api.LedgerFile -Dados ([ordered]@{
                quando = $inicio.ToString('yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
                lado = $Side
                projeto = $conta.Projeto
                pasta = (Get-PlanoPastaAtual)
                programa = (Split-Path -Leaf ([string]$programa))
                modelo = (Get-PlanoArgValor -Lista $resto -Nome '--model')
                teto = $conta.Teto
                custo = $custo
                saida = $codigo
                duracao_s = [Math]::Round(((Get-Date) - $inicio).TotalSeconds, 1)
                sessao = $sessao
                nota = $(if ($falhaInicio) { 'nao iniciou: ' + $falhaInicio } else { $null })
            })
        }
    }
}

function Show-PlanoStatus {
    param([Parameter(Mandatory)][string]$Cli)

    $rota = $script:PlanoRota[$Cli]
    $pasta = Get-PlanoPastaAtual
    $automatico = Get-PlanoLado -Cli $Cli -Path $pasta
    $blindagem = Get-PlanoBlindagem -Cli $Cli -Path $pasta

    Write-Host ''
    Write-Host ('  Pasta      : ' + $pasta)
    Write-Host ('  Blindagem  : ' + $blindagem + '   (decidida pela pasta, nunca pelo comando)')
    $ativo = [Environment]::GetEnvironmentVariable($rota.Variable)
    if ([string]::IsNullOrWhiteSpace($ativo)) {
        Write-Host ('  ' + $rota.Variable + ': nao definida - a CLI usaria o diretorio padrao')
    } else {
        Write-Host ('  ' + $rota.Variable + ': ' + $ativo)
    }
    if (-not [string]::IsNullOrWhiteSpace($rota.SharedRoot)) {
        # Um plano solto nao e' visivel no uso: ele so grava em outro canto e
        # some do -r. Por isso o diagnostico conta os vinculos, e nao a pasta.
        $soltos = @()
        foreach ($chave in $rota.Dir.Keys) {
            $casa = $rota.Dir[$chave]
            if (-not (Test-Path -LiteralPath $casa -PathType Container)) { continue }
            foreach ($nome in $rota.SharedFolders) {
                $link = Get-Item -LiteralPath (Join-Path $casa $nome) -Force -ErrorAction SilentlyContinue
                if ($link -and ($link.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
                $soltos += ($rota.Label[$chave] + '\' + $nome)
            }
        }
        Write-Host ('  Historico  : ' + $rota.SharedRoot + '   (comum aos planos)')
        if ($soltos.Count -gt 0) {
            Write-Host ('               solto: ' + ($soltos -join ', ')) -ForegroundColor Red
        }
    }
    if (@($rota.CredentialEnv).Count -gt 0) {
        # So o nome e onde esta. O valor nunca e' lido para a tela.
        $achadas = @()
        foreach ($nome in @($rota.CredentialEnv)) {
            foreach ($alvo in @('Process', 'User', 'Machine')) {
                if (-not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($nome, $alvo))) {
                    $achadas += ($nome + ' (' + $alvo + ')')
                }
            }
        }
        if ($achadas.Count -eq 0) {
            Write-Host '  Chave API  : nenhuma no ambiente'
        } else {
            Write-Host ('  Chave API  : ' + ($achadas -join ', ')) -ForegroundColor Red
            Write-Host ('               o roteador retira das sessoes de plano; deixar no ambiente e risco') -ForegroundColor Red
        }
    }
    if ($rota.ApiKey) {
        foreach ($lado in $rota.Sides) {
            if (-not $rota.ApiKey.Entry.ContainsKey($lado)) { continue }
            Write-Host ('  API ' + $lado + (' ' * [Math]::Max(0, 7 - $lado.Length)) + ': ' + $rota.ApiKey.Command[$lado] +
                ' -> cofre ' + (Split-Path -Leaf $rota.ApiKey.VaultFile) + ' / ' + $rota.ApiKey.Entry[$lado]) -ForegroundColor DarkGray
        }
    }
    Write-Host ''
    foreach ($lado in $rota.Sides) {
        $plano = Resolve-PlanoEstado -Cli $Cli -Path $pasta -Side $lado
        $marca = '   '
        if ($lado -eq $automatico) { $marca = ' > ' }
        Write-Host ($marca + $plano.Label) -ForegroundColor $plano.Color
        Write-Host ('      estado : ' + $plano.Home) -ForegroundColor DarkGray
        $resumo = Get-PlanoResumo -Path $plano.Home
        $cor = 'DarkGray'
        $nota = ''
        if ($rota.Accounts.ContainsKey($lado)) {
            $esperada = $rota.Accounts[$lado]
            if (-not $resumo.TemToken) {
                $cor = 'DarkYellow'
                $nota = '   <- falta /login com ' + $esperada
            } elseif (($resumo.Conta -ne 'sem login') -and ($resumo.Conta -notlike ($esperada + '*'))) {
                $cor = 'Red'
                $nota = '   <- DEVERIA SER ' + $esperada
            }
        }
        Write-Host ('      conta  : ' + $resumo.Texto + $nota) -ForegroundColor $cor
        Write-Host ('      skills : ' + (Get-PlanoSkill -Path $plano.Home)) -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Host ('  " > " e o que ' + $rota.Command + ' abre nesta pasta.') -ForegroundColor DarkGray
    Write-Host ''
}

function Select-PlanoLado {
    param([Parameter(Mandatory)][string]$Cli)

    $rota = $script:PlanoRota[$Cli]
    $pasta = Get-PlanoPastaAtual
    $automatico = Get-PlanoLado -Cli $Cli -Path $pasta

    Write-Host ''
    Write-Host '  Qual plano?' -ForegroundColor White
    $indice = 1
    foreach ($lado in $rota.Sides) {
        $plano = Resolve-PlanoEstado -Cli $Cli -Path $pasta -Side $lado
        $sufixo = ''
        if ($lado -eq $automatico) { $sufixo = '   (o padrao nesta pasta)' }
        Write-Host ('    [' + $indice + '] ' + $plano.Label + $sufixo) -ForegroundColor $plano.Color
        Write-Host ('        ' + $plano.Home) -ForegroundColor DarkGray
        $indice++
    }
    $escolha = (Read-Host ('  Escolha (1-' + $rota.Sides.Count + ', Enter para o padrao)')).Trim()
    if ([string]::IsNullOrWhiteSpace($escolha)) { return $automatico }
    $numero = 0
    if (-not [int]::TryParse($escolha, [ref]$numero)) { return '' }
    if ($numero -lt 1 -or $numero -gt $rota.Sides.Count) { return '' }
    return $rota.Sides[$numero - 1]
}
'@

function New-RoutingLines {
    <#
    .SYNOPSIS
    Gera os dados de rota de uma CLI e os comandos que o usuario digita.

    .DESCRIPTION
    A pasta decide a blindagem, o comando decide o lado. Por isso nao existe
    comando por diretorio de estado: existem comandos por lado, e o diretorio
    sai do cruzamento com a pasta corrente.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Cli,
        [Parameter(Mandatory)]$Routing,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Profile
    )

    $catalog = $cliCatalog[$Cli]
    $sides = @($Routing.commands.PSObject.Properties.Name)
    $lines = [Collections.Generic.List[string]]::new()

    $lines.Add('')
    $lines.Add("# ===== $Cli : planos por pasta =====")
    $lines.Add("# A pasta decide a blindagem. O comando decide o lado.")
    $lines.Add("`$script:PlanoRota['$Cli'] = @{")
    $lines.Add("    Command = '$($catalog.Command)'")
    $lines.Add("    Variable = '$($catalog.Variable)'")
    $lines.Add("    DefaultSide = '$([string]$Routing.defaultSide)'")
    $lines.Add("    Sides = @(" + (($sides | ForEach-Object { "'$_'" }) -join ', ') + ")")

    $flags = if (Test-MapProperty -InputObject $Routing -Name 'flags') { @($Routing.flags) } else { @() }
    $lines.Add("    Flags = @(" + (($flags | ForEach-Object { "'" + ([string]$_).Replace("'", "''") + "'" }) -join ', ') + ")")

    $zones = if (Test-MapProperty -InputObject $Routing -Name 'openZones') { @($Routing.openZones) } else { @() }
    $lines.Add("    OpenZones = " + (ConvertTo-GeneratedList -Item @($zones | ForEach-Object { [string]$_ })))

    $warn = if (Test-MapProperty -InputObject $Routing -Name 'warnPersonalUnder') { @($Routing.warnPersonalUnder) } else { @() }
    $lines.Add("    WarnPersonalUnder = " + (ConvertTo-GeneratedList -Item @($warn | ForEach-Object { [string]$_ })))

    $compartilha = (Test-MapProperty -InputObject $Routing -Name 'shareCredentials') -and [bool]$Routing.shareCredentials
    $lines.Add("    ShareCredentials = `$" + $compartilha.ToString().ToLowerInvariant())

    # Store comum de historico. Sem a secao no mapa os campos saem vazios e o
    # perfil se comporta como antes: cada plano com o proprio historico.
    if (Test-MapProperty -InputObject $Routing -Name 'sharedState') {
        $shared = $Routing.sharedState
        $sharedFolders = if (Test-MapProperty -InputObject $shared -Name 'folders') { @($shared.folders) } else { @() }
        $sharedFiles = if (Test-MapProperty -InputObject $shared -Name 'files') { @($shared.files) } else { @() }
        $lines.Add('    SharedRoot = ' + (ConvertTo-GeneratedPath -Path ([string]$shared.root)))
        $lines.Add("    SharedFolders = @(" + (($sharedFolders | ForEach-Object { "'" + ([string]$_).Replace("'", "''") + "'" }) -join ', ') + ")")
        $lines.Add("    SharedFiles = @(" + (($sharedFiles | ForEach-Object { "'" + ([string]$_).Replace("'", "''") + "'" }) -join ', ') + ")")
    } else {
        $lines.Add("    SharedRoot = ''")
        $lines.Add('    SharedFolders = @()')
        $lines.Add('    SharedFiles = @()')
    }
    $lines.Add('    Accounts = @{')
    if (Test-MapProperty -InputObject $Routing -Name 'accounts') {
        foreach ($side in @($Routing.accounts.PSObject.Properties.Name)) {
            $email = ([string]$Routing.accounts.$side).Replace("'", "''")
            $lines.Add("        '$side' = '$email'")
        }
    }
    $lines.Add('    }')

    # Sem as secoes no mapa, nada e' retirado do ambiente e nao ha comando de
    # API: o perfil se comporta como antes.
    $credentialEnv = if (Test-MapProperty -InputObject $Routing -Name 'credentialEnv') { @($Routing.credentialEnv) } else { @() }
    $lines.Add("    CredentialEnv = @(" + (($credentialEnv | ForEach-Object { "'" + ([string]$_).Replace("'", "''") + "'" }) -join ', ') + ")")
    $apiSides = @()
    if (Test-MapProperty -InputObject $Routing -Name 'apiKeys') {
        $api = $Routing.apiKeys
        $apiSides = @($api.sides.PSObject.Properties | ForEach-Object { $_.Name })
        $runner = if (Test-MapProperty -InputObject $api -Name 'runner') { @($api.runner) } else { @('py', '-3') }
        $printFlags = if (Test-MapProperty -InputObject $api -Name 'printFlags') { @($api.printFlags) } else { @() }
        $lines.Add('    ApiKey = @{')
        $lines.Add("        Variable = '" + ([string]$api.variable).Replace("'", "''") + "'")
        $lines.Add('        VaultScript = ' + (ConvertTo-GeneratedPath -Path ([string]$api.vaultScript)))
        $lines.Add('        VaultFile = ' + (ConvertTo-GeneratedPath -Path ([string]$api.vaultFile)))
        $lines.Add('        Runner = @(' + (($runner | ForEach-Object { "'" + ([string]$_).Replace("'", "''") + "'" }) -join ', ') + ')')
        $lines.Add('        PrintFlags = @(' + (($printFlags | ForEach-Object { "'" + ([string]$_).Replace("'", "''") + "'" }) -join ', ') + ')')
        # Sem orcamento declarado, nada e' conferido nem registrado: comportamento anterior.
        foreach ($par in @(@('BudgetFile', 'budgetFile'), @('LedgerFile', 'ledgerFile'))) {
            if (Test-MapProperty -InputObject $api -Name $par[1]) {
                $lines.Add('        ' + $par[0] + ' = ' + (ConvertTo-GeneratedPath -Path ([string]$api.($par[1]))))
            } else {
                $lines.Add('        ' + $par[0] + " = ''")
            }
        }
        foreach ($campo in @('Entry', 'Command')) {
            $lines.Add("        $campo = @{")
            foreach ($side in $apiSides) {
                $valor = if ($campo -eq 'Entry') { [string]$api.sides.$side.entry } else { [string]@($api.sides.$side.commands)[0] }
                $lines.Add("            '$side' = '" + $valor.Replace("'", "''") + "'")
            }
            $lines.Add('        }')
        }
        $lines.Add('    }')
    } else {
        $lines.Add('    ApiKey = $null')
    }

    $routes = if (Test-MapProperty -InputObject $Routing -Name 'routes') { @($Routing.routes) } else { @() }
    if (@($routes).Count -eq 0) {
        $lines.Add('    Routes = @()')
    } else {
        $lines.Add('    Routes = @(')
        foreach ($route in $routes) {
            $lines.Add(
                '        @{ Path = ' + (ConvertTo-GeneratedPath -Path ([string]$route.path)) +
                "; Side = '$([string]$route.side)' }"
            )
        }
        $lines.Add('    )')
    }

    foreach ($campo in @('Dir', 'Label', 'Color')) {
        $lines.Add("    $campo = @{")
        foreach ($entry in $Profile) {
            if (-not (Test-MapProperty -InputObject $entry -Name 'side')) { continue }
            $chave = "$($entry.side)|$($entry.shield)"
            $valor = switch ($campo) {
                'Dir' { ConvertTo-GeneratedPath -Path ([string]$entry.home) }
                'Label' { "'" + ([string]$entry.label).Replace("'", "''") + "'" }
                default { "'$([string]$entry.color)'" }
            }
            $lines.Add("        '$chave' = $valor")
        }
        $lines.Add('    }')
    }
    $lines.Add('}')

    $lines.Add('')
    $lines.Add("# ---- comandos de $Cli ----")
    $lines.Add("function $($catalog.Command) {")
    $lines.Add('    # Sem param(): um parametro proprio faria o binder casar -r ou -c da CLI')
    $lines.Add('    # como prefixo dele e a chamada morreria antes de abrir a CLI.')
    $lines.Add("    `$lado = Get-PlanoLado -Cli '$Cli' -Path (Get-PlanoPastaAtual)")
    $lines.Add("    Invoke-PlanoCli -Cli '$Cli' -Side `$lado -Rest `$args")
    $lines.Add('}')

    foreach ($side in $sides) {
        $nomes = @($Routing.commands.$side)
        $canonico = [string]$nomes[0]
        $lines.Add("function $canonico {")
        $lines.Add("    Invoke-PlanoCli -Cli '$Cli' -Side '$side' -Rest `$args")
        $lines.Add('}')
        foreach ($apelido in @($nomes | Select-Object -Skip 1)) {
            $lines.Add("Set-Alias -Name $apelido -Value $canonico -Scope Global -Force")
        }
    }

    if (Test-MapProperty -InputObject $Routing -Name 'statusCommand') {
        $nome = [string]$Routing.statusCommand
        $lines.Add("function $nome {")
        $lines.Add("    Show-PlanoStatus -Cli '$Cli'")
        $lines.Add('}')
        if (Test-MapProperty -InputObject $Routing -Name 'statusAliases') {
            foreach ($apelido in @($Routing.statusAliases)) {
                $lines.Add("Set-Alias -Name $apelido -Value $nome -Scope Global -Force")
            }
        }
    }

    if (Test-MapProperty -InputObject $Routing -Name 'askCommand') {
        $nome = [string]$Routing.askCommand
        $lines.Add("function $nome {")
        $lines.Add("    `$lado = Select-PlanoLado -Cli '$Cli'")
        $lines.Add('    if ([string]::IsNullOrWhiteSpace($lado)) {')
        $lines.Add("        Write-Host '  Opcao invalida. Abortado.' -ForegroundColor Red")
        $lines.Add('        return')
        $lines.Add('    }')
        $lines.Add("    Invoke-PlanoCli -Cli '$Cli' -Side `$lado -Rest `$args")
        $lines.Add('}')
        if (Test-MapProperty -InputObject $Routing -Name 'askAliases') {
            foreach ($apelido in @($Routing.askAliases)) {
                $lines.Add("Set-Alias -Name $apelido -Value $nome -Scope Global -Force")
            }
        }
    }

    foreach ($side in $apiSides) {
        $nomes = @($Routing.apiKeys.sides.$side.commands)
        $canonico = [string]$nomes[0]
        $lines.Add("function $canonico {")
        $lines.Add('    # Sem param(), pelo mesmo motivo dos comandos de plano.')
        $lines.Add("    Invoke-PlanoApi -Cli '$Cli' -Side '$side' -Rest `$args")
        $lines.Add('}')
        foreach ($apelido in @($nomes | Select-Object -Skip 1)) {
            $lines.Add("Set-Alias -Name $apelido -Value $canonico -Scope Global -Force")
        }
    }

    if ((Test-MapProperty -InputObject $Routing -Name 'apiKeys') -and
        (Test-MapProperty -InputObject $Routing.apiKeys -Name 'budgetCommand')) {
        $nome = [string]$Routing.apiKeys.budgetCommand
        $lines.Add("function $nome {")
        $lines.Add("    Show-PlanoApiSaldo -Cli '$Cli'")
        $lines.Add('}')
    }

    return $lines
}

function New-ManagedBlock {
    <#
    .SYNOPSIS
    Gera a regiao gerenciada em ASCII puro.

    .DESCRIPTION
    Somente ASCII de proposito: perfil sem BOM e lido como ANSI pelo Windows
    PowerShell 5.1, e acento viraria ruido no meio do codigo.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Map)

    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add($regionStart)
    $lines.Add('# Fonte: local\perfis-cli.json. Regenere com scripts\sync-cli-profiles.ps1.')
    $lines.Add('# Somente ASCII: perfil sem BOM e lido como ANSI pelo PowerShell 5.1.')
    $lines.Add('')
    $lines.Add('function Resolve-CliExecutable {')
    $lines.Add('    param([Parameter(Mandatory)][string]$Command)')
    $lines.Add('    $found = Get-Command $Command -CommandType Application, ExternalScript -ErrorAction SilentlyContinue |')
    $lines.Add('        Select-Object -First 1')
    $lines.Add('    if (-not $found) { throw "$Command nao encontrado no PATH" }')
    $lines.Add('    return $found.Source')
    $lines.Add('}')
    # Um atalho por diretorio de estado so existe para CLI sem rota declarada.
    # Sem nenhuma delas, esta funcao seria codigo morto no perfil do usuario.
    $legacyEntries = @(
        $Map.profiles | Where-Object {
            $cliDoPerfil = [string]$_.cli
            $temAlias = (Test-MapProperty -InputObject $_ -Name 'alias') -and
                -not [string]::IsNullOrWhiteSpace([string]$_.alias)
            $temRota = (Test-MapProperty -InputObject $Map -Name 'routing') -and
                (Test-MapProperty -InputObject $Map.routing -Name $cliDoPerfil)
            $temAlias -and -not $temRota
        }
    )

    if (@($legacyEntries).Count -gt 0) {
    $lines.Add('')
    $lines.Add('function Invoke-CliProfile {')
    $lines.Add('    param(')
    $lines.Add('        [Parameter(Mandatory)][string]$Command,')
    $lines.Add('        [Parameter(Mandatory)][string]$Variable,')
    # $Home tambem e automatica: o parametro gerado usa outro nome.
    $lines.Add('        [Parameter(Mandatory)][string]$ProfileHome,')
    $lines.Add('        [Parameter(Mandatory)][string]$Label,')
    $lines.Add('        [Parameter(Mandatory)][ConsoleColor]$Color,')
    $lines.Add('        [Parameter(ValueFromRemainingArguments)][object[]]$Rest')
    $lines.Add('    )')
    $lines.Add('')
    $lines.Add('    # Restaurar o valor anterior evita que a aba continue apontando para o')
    $lines.Add('    # perfil trocado depois que a CLI sai.')
    $lines.Add('    $had = Test-Path "Env:\$Variable"')
    $lines.Add('    $previous = [Environment]::GetEnvironmentVariable($Variable)')
    $lines.Add('    try {')
    $lines.Add('        [Environment]::SetEnvironmentVariable($Variable, $ProfileHome)')
    $lines.Add('        Write-Host "  > $Command -> perfil: $Label" -ForegroundColor $Color')
    $lines.Add('        & (Resolve-CliExecutable -Command $Command) @Rest')
    $lines.Add('    } finally {')
    $lines.Add('        if ($had) {')
    $lines.Add('            [Environment]::SetEnvironmentVariable($Variable, $previous)')
    $lines.Add('        } else {')
    $lines.Add('            # $null vira string vazia no binding, e o .NET do PowerShell 7')
    $lines.Add('            # mantem a variavel com valor vazio em vez de remove-la.')
    $lines.Add('            # [NullString]::Value passa um nulo de verdade nos dois hosts.')
    $lines.Add('            [Environment]::SetEnvironmentVariable($Variable, [NullString]::Value)')
    $lines.Add('        }')
    $lines.Add('    }')
    $lines.Add('}')
    }

    $hasRouting = Test-MapProperty -InputObject $Map -Name 'routing'
    if ($hasRouting) {
        $lines.Add('')
        $lines.Add('$script:PlanoRota = @{}')
        foreach ($coreLine in ($routingCore -split "\r?\n")) {
            $lines.Add($coreLine.TrimEnd())
        }
    }

    foreach ($cli in $cliCatalog.Keys) {
        $entries = @($Map.profiles | Where-Object { [string]$_.cli -eq $cli })
        if ($entries.Count -eq 0) {
            continue
        }

        if ($hasRouting -and (Test-MapProperty -InputObject $Map.routing -Name $cli)) {
            foreach ($routingLine in (
                New-RoutingLines -Cli $cli -Routing $Map.routing.$cli -Profile $entries
            )) {
                $lines.Add($routingLine)
            }
            continue
        }

        # Sem rota, vale o formato antigo: um atalho por diretorio de estado.
        # Perfil sem alias existe so para o inventario de cobertura e nao gera
        # funcao nenhuma.
        $entries = @(
            $entries | Where-Object {
                (Test-MapProperty -InputObject $_ -Name 'alias') -and
                -not [string]::IsNullOrWhiteSpace([string]$_.alias)
            }
        )
        if ($entries.Count -eq 0) {
            continue
        }

        $catalog = $cliCatalog[$cli]
        $lines.Add('')
        $lines.Add("# ===== $cli : $($entries.Count) perfis via $($catalog.Variable) =====")
        foreach ($entry in $entries) {
            $lines.Add("function $($entry.alias) {")
            $lines.Add(
                "    Invoke-CliProfile -Command '$($catalog.Command)' " +
                "-Variable '$($catalog.Variable)' " +
                "-ProfileHome $(ConvertTo-GeneratedPath -Path ([string]$entry.home)) " +
                "-Label '$([string]$entry.label -replace "'", "''")' " +
                "-Color $($entry.color) -Rest `$args"
            )
            $lines.Add('}')
        }

        $askAlias = "cc-ask$($catalog.AliasSuffix)"
        $lines.Add("function $askAlias {")
        $lines.Add('    Write-Host ""')
        $lines.Add("    Write-Host '  Qual perfil $cli ?' -ForegroundColor White")
        $index = 1
        foreach ($entry in $entries) {
            $lines.Add("    Write-Host '    [$index] $([string]$entry.label)' -ForegroundColor $($entry.color)")
            $index++
        }
        $lines.Add("    switch ((Read-Host '  Escolha (1-$($entries.Count))').Trim()) {")
        $index = 1
        foreach ($entry in $entries) {
            $lines.Add("        '$index' { $($entry.alias) @args }")
            $index++
        }
        $lines.Add("        default { Write-Host '  Opcao invalida. Abortado.' -ForegroundColor Red }")
        $lines.Add('    }')
        $lines.Add('}')
    }

    $lines.Add($regionEnd)
    return $lines
}

function Get-AliasConflict {
    <#
    .SYNOPSIS
    Aponta alias definido fora da regiao gerenciada.

    .DESCRIPTION
    Reescrever codigo escrito a mao nao e atribuicao deste script. Duas
    definicoes do mesmo nome nao quebram o shell — vale a ultima — mas escondem
    qual delas esta no ar, e isso o usuario precisa saber para decidir.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [Parameter(Mandatory)][string[]]$AliasName
    )

    $startIndex = $Content.IndexOf($regionStart)
    $endIndex = $Content.IndexOf($regionEnd)
    $outside = if ($startIndex -ge 0 -and $endIndex -gt $startIndex) {
        $Content.Substring(0, $startIndex) +
        $Content.Substring($endIndex + $regionEnd.Length)
    } else {
        $Content
    }

    foreach ($alias in $AliasName) {
        if ($outside -match "(?im)^\s*function\s+$([regex]::Escape($alias))\s*[\{\r\n]") {
            $alias
        }
    }
}

function Get-GeneratedCommandName {
    <#
    .SYNOPSIS
    Lista os nomes de funcao que o bloco vai definir.

    .DESCRIPTION
    Serve para dois fins: apontar conflito com codigo escrito a mao fora da
    regiao, e dizer ao usuario quantos comandos existem depois da sincronizacao.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Map)

    $nomes = [Collections.Generic.List[string]]::new()
    $comRota = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    if (Test-MapProperty -InputObject $Map -Name 'routing') {
        foreach ($cli in @($Map.routing.PSObject.Properties.Name)) {
            $null = $comRota.Add($cli)
            $routing = $Map.routing.$cli
            $nomes.Add($cliCatalog[$cli].Command)
            foreach ($side in @($routing.commands.PSObject.Properties.Name)) {
                foreach ($nome in @($routing.commands.$side)) { $nomes.Add([string]$nome) }
            }
            foreach ($campo in @('statusCommand', 'askCommand')) {
                if (-not (Test-MapProperty -InputObject $routing -Name $campo)) { continue }
                if ([string]::IsNullOrWhiteSpace([string]$routing.$campo)) { continue }
                $nomes.Add([string]$routing.$campo)
            }
            foreach ($campo in @('statusAliases', 'askAliases')) {
                if (-not (Test-MapProperty -InputObject $routing -Name $campo)) { continue }
                foreach ($nome in @($routing.$campo)) { $nomes.Add([string]$nome) }
            }
            if (Test-MapProperty -InputObject $routing -Name 'apiKeys') {
                foreach ($side in @($routing.apiKeys.sides.PSObject.Properties | ForEach-Object { $_.Name })) {
                    foreach ($nome in @($routing.apiKeys.sides.$side.commands)) { $nomes.Add([string]$nome) }
                }
                if (Test-MapProperty -InputObject $routing.apiKeys -Name 'budgetCommand') {
                    $nomes.Add([string]$routing.apiKeys.budgetCommand)
                }
            }
        }
    }

    foreach ($entry in @($Map.profiles)) {
        if ($comRota.Contains([string]$entry.cli)) { continue }
        if (-not (Test-MapProperty -InputObject $entry -Name 'alias')) { continue }
        if ([string]::IsNullOrWhiteSpace([string]$entry.alias)) { continue }
        $nomes.Add([string]$entry.alias)
    }

    return @($nomes)
}

function Remove-LegacyRegion {
    <#
    .SYNOPSIS
    Tira do perfil um bloco antigo delimitado por comentarios, sem resquicio.

    .DESCRIPTION
    Codigo escrito a mao que a regiao gerenciada substitui nao pode ficar para
    tras: duas definicoes do mesmo comando nao quebram o shell, mas escondem
    qual esta no ar. Os delimitadores vem do mapa, nunca do script, porque sao
    detalhe da maquina.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Region
    )

    $texto = $Content
    $removidos = [Collections.Generic.List[string]]::new()

    foreach ($regiao in $Region) {
        foreach ($campo in @('start', 'end')) {
            if (-not (Test-MapProperty -InputObject $regiao -Name $campo)) {
                throw "Regiao legada sem o campo '$campo' no mapa."
            }
        }
        $inicio = [string]$regiao.start
        $fim = [string]$regiao.end

        while ($true) {
            $i = $texto.IndexOf($inicio, [StringComparison]::Ordinal)
            if ($i -lt 0) { break }
            $j = $texto.IndexOf($fim, $i, [StringComparison]::Ordinal)
            if ($j -lt 0) {
                throw (
                    "Bloco legado aberto e nao fechado: '$inicio' sem '$fim'. " +
                    'Corrija a mao antes de sincronizar.'
                )
            }
            $corte = $j + $fim.Length
            # Leva junto a quebra de linha que sobraria sozinha no lugar.
            while ($corte -lt $texto.Length -and ($texto[$corte] -eq "`r" -or $texto[$corte] -eq "`n")) {
                $corte++
            }
            $texto = $texto.Substring(0, $i) + $texto.Substring($corte)
            $removidos.Add($inicio)
        }
    }

    return [pscustomobject]@{
        Content = $texto
        Removed = @($removidos)
    }
}

function Set-ManagedRegion {
    <#
    .SYNOPSIS
    Substitui ou acrescenta a regiao gerenciada num perfil de host.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        # O bloco tem linhas em branco de proposito; sem AllowEmptyString o
        # binding de parametro obrigatorio recusa cada uma delas.
        [Parameter(Mandatory)][AllowEmptyString()][string[]]$BlockLine,
        [AllowEmptyCollection()][object[]]$LegacyRegion = @(),
        [switch]$Apply
    )

    $original = if (Test-Path -LiteralPath $Path -PathType Leaf) {
        [IO.File]::ReadAllText($Path)
    } else {
        ''
    }

    $limpeza = Remove-LegacyRegion -Content $original -Region $LegacyRegion
    $existing = $limpeza.Content

    $newline = if ($existing -match "\r\n") { "`r`n" } else { "`n" }
    $block = ($BlockLine -join $newline)
    $startIndex = $existing.IndexOf($regionStart)
    $endIndex = $existing.IndexOf($regionEnd)

    $action = if ($startIndex -ge 0 -and $endIndex -gt $startIndex) {
        'regiao substituida'
    } elseif ($startIndex -ge 0 -or $endIndex -ge 0) {
        throw "Marcadores incompletos em $Path. Corrija a mao antes de sincronizar."
    } elseif ($existing -eq '') {
        'perfil criado'
    } else {
        'regiao acrescentada'
    }

    $updated = if ($action -eq 'regiao substituida') {
        $existing.Substring(0, $startIndex) +
        $block +
        $existing.Substring($endIndex + $regionEnd.Length)
    } else {
        $prefix = if ($existing -eq '') { '' } elseif ($existing.EndsWith("`n")) { $existing } else { $existing + $newline }
        $prefix + $newline + $block + $newline
    }

    if (@($limpeza.Removed).Count -gt 0) {
        $action = "$action, $(@($limpeza.Removed).Count) bloco(s) legado(s) removido(s)"
    }

    $result = [pscustomobject]@{
        Path = $Path
        Action = $action
        Changed = ($updated -ne $original)
        Backup = ''
        LegacyRemoved = @($limpeza.Removed)
    }

    if (-not $result.Changed) {
        $result.Action = 'sem mudanca'
        return $result
    }
    if (-not $Apply) {
        return $result
    }
    if (-not $PSCmdlet.ShouldProcess($Path, "sincronizar perfis de CLI ($action)")) {
        $result.Action = 'ignorado pelo usuario'
        return $result
    }

    $directory = [IO.Path]::GetDirectoryName($Path)
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $directory
    }
    if ($original -ne '') {
        $result.Backup = "$Path.bak-$(Get-Date -Format 'yyyy-MM-dd_HHmm')"
        Copy-Item -LiteralPath $Path -Destination $result.Backup
    }

    # ASCII garante leitura identica nos dois hosts, com ou sem BOM.
    [IO.File]::WriteAllText($Path, $updated, [Text.Encoding]::ASCII)

    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) {
        throw "O perfil gerado nao parseia: $Path. Restaure $($result.Backup)."
    }

    return $result
}

function Sync-TerminalTab {
    <#
    .SYNOPSIS
    Alinha as abas do Windows Terminal com os comandos do mapa.

    .DESCRIPTION
    Aba que chama um comando que deixou de existir nao da erro visivel: ela abre,
    o shell reclama de comando desconhecido e o usuario descobre no pior momento.
    Por isso as abas saem do mesmo mapa que gera os comandos.

    "managedGuids" e a lista do que este script pode mexer, incluindo aba
    aposentada. Um GUID declarado ali e ausente de "tabs" e removido; nenhum
    perfil fora dessa lista e tocado.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]$Map,
        [switch]$Apply
    )

    if (-not (Test-MapProperty -InputObject $Map -Name 'terminal')) {
        return $null
    }

    $terminal = $Map.terminal
    $settingsPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) `
        'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'
    if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
        Write-Warning "Windows Terminal nao encontrado; abas nao sincronizadas: $settingsPath"
        return $null
    }

    $originalText = [IO.File]::ReadAllText($settingsPath)
    try {
        $settings = $originalText | ConvertFrom-Json
    } catch {
        # settings.json aceita comentario; ConvertFrom-Json nao. Reescrever as
        # cegas apagaria anotacao do usuario.
        Write-Warning "settings.json do Windows Terminal nao e JSON puro (comentario?): abas nao sincronizadas."
        return $null
    }

    $managed = @()
    if (Test-MapProperty -InputObject $terminal -Name 'managedGuids') {
        $managed = @($terminal.managedGuids | ForEach-Object { [string]$_ })
    }
    $tabs = @()
    if (Test-MapProperty -InputObject $terminal -Name 'tabs') {
        $tabs = @($terminal.tabs)
    }
    $desejados = @($tabs | ForEach-Object { [string]$_.guid })

    foreach ($guid in $desejados) {
        if ($guid -notin $managed) {
            throw "Aba $guid nao esta em terminal.managedGuids. Declare o GUID antes de usa-lo."
        }
    }

    $lista = [Collections.Generic.List[object]]::new()
    $removidas = [Collections.Generic.List[string]]::new()
    foreach ($perfil in @($settings.profiles.list)) {
        $guid = if (Test-MapProperty -InputObject $perfil -Name 'guid') { [string]$perfil.guid } else { '' }
        if (($guid -in $managed) -and ($guid -notin $desejados)) {
            $nome = if (Test-MapProperty -InputObject $perfil -Name 'name') { [string]$perfil.name } else { $guid }
            $removidas.Add($nome)
            continue
        }
        $lista.Add($perfil)
    }

    $criadas = [Collections.Generic.List[string]]::new()
    $atualizadas = [Collections.Generic.List[string]]::new()
    foreach ($tab in $tabs) {
        $guid = [string]$tab.guid
        $comando = 'pwsh.exe -NoExit -Command ' + [string]$tab.command
        $existente = $lista | Where-Object {
            (Test-MapProperty -InputObject $_ -Name 'guid') -and ([string]$_.guid -eq $guid)
        } | Select-Object -First 1

        if ($null -eq $existente) {
            $novo = [pscustomobject]@{
                guid = $guid
                name = [string]$tab.name
                commandline = $comando
                startingDirectory = [string]$tab.startingDirectory
                tabColor = [string]$tab.tabColor
                hidden = $false
            }
            $lista.Add($novo)
            $criadas.Add([string]$tab.name)
            continue
        }

        $mudou = $false
        foreach ($par in @(
            @{ Nome = 'name'; Valor = [string]$tab.name }
            @{ Nome = 'commandline'; Valor = $comando }
            @{ Nome = 'startingDirectory'; Valor = [string]$tab.startingDirectory }
            @{ Nome = 'tabColor'; Valor = [string]$tab.tabColor }
            @{ Nome = 'hidden'; Valor = $false }
        )) {
            $atual = if (Test-MapProperty -InputObject $existente -Name $par.Nome) { $existente.($par.Nome) } else { $null }
            if ($atual -ne $par.Valor) {
                $existente | Add-Member -NotePropertyName $par.Nome -NotePropertyValue $par.Valor -Force
                $mudou = $true
            }
        }
        if ($mudou) { $atualizadas.Add([string]$tab.name) }
    }

    $settings.profiles.list = @($lista)
    $novoTexto = ($settings | ConvertTo-Json -Depth 100)

    $resultado = [pscustomobject]@{
        Path = $settingsPath
        Criadas = @($criadas)
        Atualizadas = @($atualizadas)
        Removidas = @($removidas)
        Changed = ($novoTexto -ne $originalText)
        Backup = ''
    }

    if (-not $resultado.Changed -or -not $Apply) { return $resultado }
    if (-not $PSCmdlet.ShouldProcess($settingsPath, 'sincronizar abas do Windows Terminal')) {
        return $resultado
    }

    $resultado.Backup = "$settingsPath.bak-$(Get-Date -Format 'yyyy-MM-dd_HHmm')"
    Copy-Item -LiteralPath $settingsPath -Destination $resultado.Backup
    # UTF8 sem BOM: e o que o Windows Terminal grava, e BOM aqui vira aviso dele.
    [IO.File]::WriteAllText($settingsPath, $novoTexto, [Text.UTF8Encoding]::new($false))

    try {
        $null = [IO.File]::ReadAllText($settingsPath) | ConvertFrom-Json
    } catch {
        Copy-Item -LiteralPath $resultado.Backup -Destination $settingsPath -Force
        throw "settings.json gerado nao e JSON valido; restaurado de $($resultado.Backup)."
    }

    return $resultado
}

if ($Bootstrap) {
    if ((Test-Path -LiteralPath $resolvedMapPath -PathType Leaf) -and -not $Force) {
        throw "Mapa ja existe: $resolvedMapPath. Use -Force para substituir."
    }

    $discovered = New-ProfileMap -Root $SearchRoot
    Write-Host "Perfis descobertos: $(@($discovered.profiles).Count)"
    foreach ($entry in @($discovered.profiles)) {
        Write-Host ("  {0,-24} {1}" -f $entry.alias, $entry.home)
    }

    $mapDirectory = [IO.Path]::GetDirectoryName($resolvedMapPath)
    if (-not (Test-Path -LiteralPath $mapDirectory -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $mapDirectory
    }

    if ($Execute) {
        if ($PSCmdlet.ShouldProcess($resolvedMapPath, 'gravar mapa de perfis')) {
            $discovered | ConvertTo-Json -Depth 5 |
                Set-Content -LiteralPath $resolvedMapPath -Encoding utf8
            Write-Host "Mapa gravado em $resolvedMapPath"
            Write-Host 'Revise rotulo, cor e alias antes de sincronizar os perfis.'
        }
    } else {
        Write-Host ''
        Write-Host "Dry-run: nada gravado. Repita com -Execute para criar $resolvedMapPath"
    }

    return [pscustomobject]@{
        Mode = 'bootstrap'
        Executed = [bool]$Execute
        MapPath = $resolvedMapPath
        Discovered = @($discovered.profiles).Count
    }
}

if (-not (Test-Path -LiteralPath $resolvedMapPath -PathType Leaf)) {
    throw (
        "Mapa ausente: $resolvedMapPath. " +
        'Rode com -Bootstrap -Execute para monta-lo por descoberta, ou copie ' +
        'scripts\perfis-cli.example.json e ajuste.'
    )
}

$map = Get-Content -LiteralPath $resolvedMapPath -Raw | ConvertFrom-Json
Test-ProfileMap -Map $map

if ($Report) {
    $drift = Get-MapDrift -Map $map -Root $SearchRoot
    Write-Host "Mapa: $resolvedMapPath"
    Write-Host "  perfis declarados: $($drift.Mapped)   ignorados de proposito: $($drift.Ignored)"
    Write-Host "  raizes observadas: $(@($drift.Roots) -join ', ')"
    Write-Host ''

    if (@($drift.Novos).Count -eq 0) {
        Write-Host 'Nenhum diretorio de estado fora do mapa.'
    } else {
        Write-Host "Diretorios sem decisao no mapa: $(@($drift.Novos).Count)"
        foreach ($novo in @($drift.Novos)) {
            Write-Host ("  {0,-24} {1}" -f $novo.alias, $novo.home)
        }
        Write-Host ''
        Write-Host 'Acrescente em "profiles" para virar atalho, ou em "ignore" para calar o aviso.'
    }

    if (@($drift.Ausentes).Count -gt 0) {
        Write-Host ''
        Write-Warning (
            'Perfis declarados que nao existem no disco: ' +
            (@($drift.Ausentes) -join ', ')
        )
    }

    return [pscustomobject]@{
        Mode = 'report'
        MapPath = $resolvedMapPath
        Mapped = $drift.Mapped
        Ignored = $drift.Ignored
        # ForEach-Object em lugar de acesso direto: com a lista vazia, o
        # StrictMode reclamaria da propriedade ausente.
        Novos = @(@($drift.Novos) | ForEach-Object { $_.home })
        Ausentes = @($drift.Ausentes)
    }
}

$aliasNames = @(Get-GeneratedCommandName -Map $map)
$legacyRegions = if (Test-MapProperty -InputObject $map -Name 'legacyRegions') {
    @($map.legacyRegions)
} else {
    @()
}
$blockLines = New-ManagedBlock -Map $map
$targets = @(Get-ProfileTarget)

Write-Host "Mapa: $resolvedMapPath ($($aliasNames.Count) comandos)"
Write-Host ("Comandos: " + (@($aliasNames) -join ', '))
Write-Host "Bloco gerado: $($blockLines.Count) linhas, ASCII"
Write-Host ''

if (-not [string]::IsNullOrWhiteSpace($BlockOutPath)) {
    $resolvedBlockOutPath = [IO.Path]::GetFullPath($BlockOutPath)
    if ($PSCmdlet.ShouldProcess($resolvedBlockOutPath, 'gravar bloco gerado para revisao')) {
        [IO.File]::WriteAllText(
            $resolvedBlockOutPath,
            (($blockLines -join "`r`n") + "`r`n"),
            [Text.Encoding]::ASCII
        )
        Write-Host "Bloco gravado para revisao em $resolvedBlockOutPath"
        Write-Host ''
    }
}

$results = foreach ($target in $targets) {
    $existingContent = if ($target.Exists) { [IO.File]::ReadAllText($target.Path) } else { '' }
    # O conflito e medido no texto ja sem os blocos legados: apontar como
    # duplicado algo que a propria sincronizacao vai remover so gera ruido.
    $conflicts = @(
        Get-AliasConflict `
            -Content (Remove-LegacyRegion -Content $existingContent -Region $legacyRegions).Content `
            -AliasName $aliasNames
    )

    $outcome = Set-ManagedRegion `
        -Path $target.Path `
        -BlockLine $blockLines `
        -LegacyRegion $legacyRegions `
        -Apply:$Execute

    Write-Host ("{0,-24} {1}" -f $target.Name, $outcome.Action)
    Write-Host ("  perfil: {0}" -f $target.Path)
    if ($outcome.Backup) {
        Write-Host ("  backup: {0}" -f $outcome.Backup)
    }
    foreach ($legado in @($outcome.LegacyRemoved)) {
        Write-Host ("  legado removido: {0}" -f $legado) -ForegroundColor DarkYellow
    }
    if ($conflicts.Count -gt 0) {
        Write-Warning (
            "$($target.Name): estes alias tambem estao definidos a mao fora da " +
            "regiao gerenciada, e a definicao gerada e a que vale por vir depois: " +
            ($conflicts -join ', ')
        )
    }

    [pscustomobject]@{
        Host = $target.Name
        Path = $target.Path
        Action = $outcome.Action
        Changed = $outcome.Changed
        Backup = $outcome.Backup
        Conflicts = $conflicts
    }
}

$terminal = Sync-TerminalTab -Map $map -Apply:$Execute
if ($null -ne $terminal) {
    Write-Host ''
    Write-Host ("{0,-24} {1}" -f 'Windows Terminal', $(if ($terminal.Changed) { 'abas alinhadas' } else { 'sem mudanca' }))
    Write-Host ("  settings: {0}" -f $terminal.Path)
    if ($terminal.Backup) { Write-Host ("  backup: {0}" -f $terminal.Backup) }
    foreach ($nome in @($terminal.Criadas)) { Write-Host ("  aba criada: {0}" -f $nome) }
    foreach ($nome in @($terminal.Atualizadas)) { Write-Host ("  aba atualizada: {0}" -f $nome) }
    foreach ($nome in @($terminal.Removidas)) { Write-Host ("  aba removida: {0}" -f $nome) -ForegroundColor DarkYellow }
}

if (-not $Execute) {
    Write-Host ''
    Write-Host 'Dry-run: nada alterado. Repita com -Execute para aplicar.'
}

[pscustomobject]@{
    Mode = 'sync'
    Executed = [bool]$Execute
    MapPath = $resolvedMapPath
    Aliases = $aliasNames.Count
    BlockLines = $blockLines.Count
    Targets = @($results)
    Terminal = $terminal
}
