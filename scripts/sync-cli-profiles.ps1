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

Dry-run e o padrao. Nenhuma credencial, token ou conteudo de perfil de CLI e
lido: o script so mexe em arquivo de perfil do shell.

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

function Test-ProfileMap {
    <#
    .SYNOPSIS
    Recusa mapa incompleto antes de gerar codigo a partir dele.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Map)

    if ($Map.PSObject.Properties.Name -notcontains 'profiles') {
        throw 'Mapa sem a lista "profiles".'
    }

    $seen = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($entry in @($Map.profiles)) {
        foreach ($required in @('cli', 'alias', 'label', 'color', 'home')) {
            if (
                $entry.PSObject.Properties.Name -notcontains $required -or
                [string]::IsNullOrWhiteSpace([string]$entry.$required)
            ) {
                throw "Perfil sem o campo obrigatorio '$required': $($entry | ConvertTo-Json -Compress)"
            }
        }
        if (-not $cliCatalog.Contains([string]$entry.cli)) {
            throw "CLI desconhecida no mapa: $($entry.cli)"
        }
        if ([string]$entry.alias -notmatch '^[A-Za-z][\w\-]*$') {
            throw "Alias invalido para funcao do PowerShell: $($entry.alias)"
        }
        if ([string]$entry.color -notin [Enum]::GetNames([ConsoleColor])) {
            throw "Cor invalida para o alias $($entry.alias): $($entry.color)"
        }
        if (-not $seen.Add([string]$entry.alias)) {
            throw "Alias repetido no mapa: $($entry.alias)"
        }
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

    foreach ($cli in $cliCatalog.Keys) {
        $entries = @($Map.profiles | Where-Object { [string]$_.cli -eq $cli })
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
                "-Color $($entry.color) @args"
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
        [switch]$Apply
    )

    $existing = if (Test-Path -LiteralPath $Path -PathType Leaf) {
        [IO.File]::ReadAllText($Path)
    } else {
        ''
    }

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

    $result = [pscustomobject]@{
        Path = $Path
        Action = $action
        Changed = ($updated -ne $existing)
        Backup = ''
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
    if ($existing -ne '') {
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

$aliasNames = @(@($map.profiles).alias)
$blockLines = New-ManagedBlock -Map $map
$targets = @(Get-ProfileTarget)

Write-Host "Mapa: $resolvedMapPath ($($aliasNames.Count) perfis)"
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
    $conflicts = @(Get-AliasConflict -Content $existingContent -AliasName $aliasNames)

    $outcome = Set-ManagedRegion `
        -Path $target.Path `
        -BlockLine $blockLines `
        -Apply:$Execute

    Write-Host ("{0,-24} {1}" -f $target.Name, $outcome.Action)
    Write-Host ("  perfil: {0}" -f $target.Path)
    if ($outcome.Backup) {
        Write-Host ("  backup: {0}" -f $outcome.Backup)
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

if (-not $Execute) {
    Write-Host ''
    Write-Host 'Dry-run: nenhum perfil alterado. Repita com -Execute para aplicar.'
}

[pscustomobject]@{
    Mode = 'sync'
    Executed = [bool]$Execute
    MapPath = $resolvedMapPath
    Aliases = $aliasNames.Count
    BlockLines = $blockLines.Count
    Targets = @($results)
}
