<#
.SYNOPSIS
    Inventaria repositorios Git e arquivos ignorados relevantes antes de uma
    troca de maquina, de forma serializada e retomavel.

.DESCRIPTION
    Responde a pergunta que so importa no fechamento de uma migracao: o que
    ainda existe SO nesta maquina.

    Tres fases, todas somente leitura:
      1. descoberta   - varre as raizes atras de diretorios .git;
      2. repositorios - por repo, mede commits fora de qualquer remoto,
                        trabalho nao commitado, stashes e ausencia de remoto;
      3. ignorados    - por repo, lista arquivos ignorados que casam com uma
                        allowlist de nomes (configuracao, certificado, banco
                        local). Lista caminhos; nunca le conteudo.

    A varredura e' SERIALIZADA de proposito. Enumeracao concorrente de
    diretorio derruba maquinas afetadas pelo bug do minifiltro WOF sobre o
    NTFS, e o inventario de migracao e' exatamente esse workload. Nao
    paralelize para "ir mais rapido".

    O progresso e' gravado em disco continuamente. Se a maquina cair no meio,
    -Retomar continua de onde parou em vez de recomecar do zero.

    Somente leitura: nao altera repositorio, nao move arquivo, nao le conteudo
    de arquivo ignorado. Credenciais embutidas em URL de remoto sao removidas
    antes de qualquer gravacao.

.EXAMPLE
    pwsh -NoProfile -File .\scripts\report-migration-inventory.ps1 -Raiz C:\Projetos

.EXAMPLE
    pwsh -NoProfile -File .\scripts\report-migration-inventory.ps1 -Retomar
#>
[CmdletBinding()]
param(
    [string[]]$Raiz,
    [string]$OutDir = (Join-Path $PSScriptRoot '..\reports\migracao-inventario'),
    [switch]$Retomar,
    [switch]$SemIgnorados,
    [ValidateRange(1, 100000)][int]$CheckpointACada = 200,
    [string[]]$PodarDiretorio = @(
        'node_modules', '.vs', '.vscode-server', 'bin', 'obj', 'packages',
        'dist', 'build', '.next', '.nuxt', 'venv', '.venv', '__pycache__',
        'AppData', 'Windows', 'Recovery', 'System Volume Information'
    ),
    [string[]]$NomeIgnoradoDeInteresse = @(
        '.env', '.env.*', '*.env', 'appsettings*.json', 'local.settings.json',
        'secrets.json', '*.pfx', '*.p12', '*.pem', '*.key', '*.keystore',
        '*.jks', 'nuget.config', '.npmrc', '.netrc', '*.publishsettings',
        'docker-compose.override.yml', 'docker-compose.override.yaml',
        '*.sqlite', '*.sqlite3', '*.db', '*.mdf', '*.bak',
        'connection*.json', 'credentials*'
    )
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# git escreve em stderr em situacoes normais. No PowerShell 7.4+ isso vira
# excecao com ErrorActionPreference = Stop, o que mataria o inventario no
# primeiro repositorio sem upstream.
$PSNativeCommandUseErrorActionPreference = $false

# ---------------------------------------------------------------- utilitarios

function Write-Etapa {
    param([string]$Texto, [string]$Marca = '..')
    Write-Host ("[{0}] {1}" -f $Marca, $Texto)
}

function ConvertTo-ListaSegura {
    # ConvertFrom-Json devolve $null para lista vazia, e @($null) vira um array
    # de um elemento nulo. Este helper existe so para evitar esse acidente.
    param($Valor)
    if ($null -eq $Valor) { return @() }
    return @($Valor | Where-Object { $null -ne $_ })
}

function Resolve-RaizSegura {
    param([string]$Caminho)
    $completo = [IO.Path]::GetFullPath($Caminho)
    if (-not (Test-Path -LiteralPath $completo -PathType Container)) {
        throw "Raiz inexistente ou nao e' um diretorio: $completo"
    }
    # Raiz de unidade nao pode perder a barra: 'C:' e' um caminho RELATIVO ao
    # diretorio atual daquela unidade, nao a raiz dela. Trimar aqui faz a
    # varredura inteira acontecer dentro do diretorio de trabalho e voltar
    # vazia, sem erro nenhum.
    if ($completo -match '^[A-Za-z]:\\$') { return $completo }
    return $completo.TrimEnd('\')
}

function Get-RaizesPadrao {
    # Volumes fixos, sem presumir letra de unidade nem nome de usuario.
    Get-CimInstance Win32_LogicalDisk -Filter 'DriveType = 3' |
        ForEach-Object { "$($_.DeviceID)\" }
}

function Remove-CredencialDaUrl {
    # https://usuario:token@host/caminho  ->  https://host/caminho
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return '' }
    return ($Url -replace '://[^/@\s]+@', '://')
}

function Invoke-Git {
    param([string]$RepoDir, [string[]]$Argumentos)
    $saida = & git -C $RepoDir @Argumentos 2>$null
    if ($LASTEXITCODE -ne 0) { return @() }
    # Sem o idioma da virgula (return , $array): ele devolveria o array como UM
    # objeto, e todo .Count no chamador daria 1 - a contagem inteira do
    # inventario viraria "tem ou nao tem". Quem precisa de array garantido
    # envolve a chamada em @().
    return ConvertTo-ListaSegura $saida
}

function Test-EhReparsePoint {
    param([string]$Caminho)
    try {
        $item = Get-Item -LiteralPath $Caminho -Force -ErrorAction Stop
        return ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
    } catch {
        return $true   # inacessivel: trate como a evitar
    }
}

function ConvertFrom-CaminhoGit {
    <#
        Normaliza um caminho devolvido pelo git.

        Dois problemas se somam e o resultado e' silencioso:

        1. O PowerShell termina cada item enviado a um executavel nativo com
           CRLF, mas o 'git check-ignore --stdin' separa por LF. O CR sobra
           dentro do nome do arquivo.
        2. Nome com caractere de controle e' "especial" para o git, que entao
           devolve o caminho ENTRE ASPAS e com escapes em C ("a\\b\tc").

        Sem esta normalizacao, o Get-Item nao acha o arquivo, o try/catch
        engole a falha e o campo 'bytes' sai nulo em todas as linhas: o
        relatorio diz QUAIS arquivos, mas nunca QUANTO. Foi o que aconteceu
        na execucao de 19/08/2026.
    #>
    param([string]$Caminho)

    $c = $Caminho -replace "`r", ''
    if ($c.Length -ge 2 -and $c[0] -eq '"' -and $c[-1] -eq '"') {
        $c = $c.Substring(1, $c.Length - 2)
        $c = [regex]::Replace($c, '\\([\\"abfnrtv])|\\([0-7]{3})', {
            param($m)
            if ($m.Groups[2].Success) {
                return [string][char][Convert]::ToInt32($m.Groups[2].Value, 8)
            }
            switch ($m.Groups[1].Value) {
                'a'     { "`a" }
                'b'     { "`b" }
                'f'     { "`f" }
                'n'     { "`n" }
                'r'     { "`r" }
                't'     { "`t" }
                'v'     { "`v" }
                default { $m.Groups[1].Value }
            }
        })
    }
    # De novo, e' de proposito: o CR pode chegar como caractere (item a item)
    # OU como a sequencia de escape \r dentro das aspas, e nesse caso so
    # aparece depois de desescapar. Nome de arquivo com CR nao existe no
    # Windows, entao remover no fim e' seguro.
    return ($c -replace "`r", '')
}

# ------------------------------------------------------------------- arranjo

if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}
$OutDir = [IO.Path]::GetFullPath($OutDir)

$estadoPath = Join-Path $OutDir 'estado.json'
$reposPath  = Join-Path $OutDir 'repos.jsonl'
$ignorPath  = Join-Path $OutDir 'ignorados.jsonl'

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "git nao encontrado no PATH."
}

if ($Retomar -and (Test-Path -LiteralPath $estadoPath)) {
    $estado = Get-Content -LiteralPath $estadoPath -Raw | ConvertFrom-Json
    Write-Etapa ("Retomando: fase '{0}', {1} repos descobertos, {2} diretorios visitados." -f `
        $estado.fase, $estado.reposEncontrados, $estado.diretoriosVisitados) 'ok'
} else {
    if (-not $Raiz -or $Raiz.Count -eq 0) { $Raiz = Get-RaizesPadrao }
    $raizes = @($Raiz | ForEach-Object { Resolve-RaizSegura $_ })
    $estado = [pscustomobject]@{
        iniciado             = (Get-Date).ToString('o')
        atualizado           = ''
        host                 = $env:COMPUTERNAME
        raizes               = $raizes
        fase                 = 'descoberta'
        pilha                = $raizes
        repos                = @()
        reposEncontrados     = 0
        diretoriosVisitados  = 0
        reposMedidos         = @()
        reposIgnoradosFeitos = @()
    }
    # Zera os arquivos de resultado escrevendo vazio em cima, em vez de apagar.
    # Este script e' somente leitura em relacao ao host, e um Remove-Item o
    # tiraria dessa categoria - inclusive aos olhos do teste de superficie.
    Set-Content -LiteralPath $reposPath -Value $null -Encoding utf8
    Set-Content -LiteralPath $ignorPath -Value $null -Encoding utf8
    Write-Etapa ("Novo inventario. Raizes: {0}" -f ($raizes -join ', ')) 'ok'
}

function Save-Estado {
    param($Estado)
    $Estado.atualizado = (Get-Date).ToString('o')
    $tmp = "$estadoPath.tmp"
    $Estado | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $tmp -Encoding utf8
    Move-Item -LiteralPath $tmp -Destination $estadoPath -Force
}

$listaRepos = @(ConvertTo-ListaSegura $estado.repos)

# ------------------------------------------------------------ fase 1: varrer

if ($estado.fase -eq 'descoberta') {
    Write-Etapa "Fase 1/3 - descoberta de repositorios (serializada, um diretorio por vez)."

    $pilha = [System.Collections.Generic.Stack[string]]::new()
    foreach ($d in (ConvertTo-ListaSegura $estado.pilha)) { $pilha.Push([string]$d) }

    $repos = [System.Collections.Generic.List[string]]::new()
    foreach ($r in $listaRepos) { $repos.Add([string]$r) }

    $visitados = [int]$estado.diretoriosVisitados
    $desdeCheckpoint = 0

    while ($pilha.Count -gt 0) {
        $atual = $pilha.Pop()
        $visitados++
        $desdeCheckpoint++

        if (Test-Path -LiteralPath (Join-Path $atual '.git')) {
            $repos.Add($atual)
            Write-Etapa ("repo: {0}" -f $atual) '+'
            # Nao desce dentro do repositorio: submodulo quem descobre e' o git.
            continue
        }

        try {
            $filhos = [IO.Directory]::GetDirectories($atual)
        } catch {
            continue   # sem permissao, ou o diretorio sumiu durante a varredura
        }

        foreach ($f in $filhos) {
            $nome = Split-Path $f -Leaf
            if ($PodarDiretorio -contains $nome) { continue }
            if ($nome.StartsWith('$')) { continue }
            if (Test-EhReparsePoint $f) { continue }
            $pilha.Push($f)
        }

        if ($desdeCheckpoint -ge $CheckpointACada) {
            $estado.pilha = @($pilha.ToArray())
            $estado.repos = @($repos.ToArray())
            $estado.reposEncontrados = $repos.Count
            $estado.diretoriosVisitados = $visitados
            Save-Estado $estado
            $desdeCheckpoint = 0
            Write-Etapa ("checkpoint: {0} diretorios, {1} repos, {2} na fila" -f `
                $visitados, $repos.Count, $pilha.Count)
        }
    }

    $estado.pilha = @()
    $estado.repos = @($repos.ToArray())
    $estado.reposEncontrados = $repos.Count
    $estado.diretoriosVisitados = $visitados
    $estado.fase = 'repositorios'
    Save-Estado $estado
    $listaRepos = @($repos.ToArray())
    Write-Etapa ("Fase 1 concluida: {0} repositorios em {1} diretorios." -f $repos.Count, $visitados) 'ok'
}

# --------------------------------------------------- fase 2: estado dos repos

if ($estado.fase -eq 'repositorios') {
    Write-Etapa "Fase 2/3 - estado de cada repositorio."

    $feitos = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($x in (ConvertTo-ListaSegura $estado.reposMedidos)) { [void]$feitos.Add([string]$x) }

    $total = $listaRepos.Count
    $i = 0

    foreach ($repo in $listaRepos) {
        $i++
        if ($feitos.Contains($repo)) { continue }

        $remotos = @()
        foreach ($linha in (Invoke-Git $repo @('remote', '-v'))) {
            $partes = $linha -split '\s+'
            if ($partes.Count -ge 2) { $remotos += (Remove-CredencialDaUrl $partes[1]) }
        }
        $remotos = @($remotos | Sort-Object -Unique)

        $branch = (Invoke-Git $repo @('rev-parse', '--abbrev-ref', 'HEAD')) -join ''
        $status = @(Invoke-Git $repo @('status', '--porcelain=v1'))

        $staged   = @($status | Where-Object { $_.Length -ge 1 -and $_[0] -ne ' ' -and $_[0] -ne '?' }).Count
        $naoStage = @($status | Where-Object { $_.Length -ge 2 -and $_[1] -ne ' ' -and $_[1] -ne '?' }).Count
        $naoRastr = @($status | Where-Object { $_.StartsWith('??') }).Count
        $stashes  = @(Invoke-Git $repo @('stash', 'list')).Count

        # Commits que existem localmente e em nenhum remoto: exatamente o que
        # uma formatacao leva embora.
        if ($remotos.Count -gt 0) {
            $foraDoRemoto = @(Invoke-Git $repo @('log', '--branches', '--not', '--remotes', '--format=%H')).Count
        } else {
            $foraDoRemoto = @(Invoke-Git $repo @('log', '--branches', '--format=%H')).Count
        }

        $registro = [pscustomobject]@{
            caminho             = $repo
            branch              = $branch
            temRemoto           = ($remotos.Count -gt 0)
            remotos             = $remotos
            commitsForaDoRemoto = $foraDoRemoto
            staged              = $staged
            naoStaged           = $naoStage
            naoRastreados       = $naoRastr
            stashes             = $stashes
            ultimoCommit        = ((Invoke-Git $repo @('log', '-1', '--format=%cI')) -join '')
            medidoEm            = (Get-Date).ToString('o')
        }
        $registro | ConvertTo-Json -Depth 4 -Compress |
            Add-Content -LiteralPath $reposPath -Encoding utf8

        $marca = if (-not $registro.temRemoto -or $foraDoRemoto -gt 0) { '!' } else { '.' }
        Write-Etapa ("[{0}/{1}] {2}  fora-do-remoto={3} staged={4} stash={5}" -f `
            $i, $total, (Split-Path $repo -Leaf), $foraDoRemoto, $staged, $stashes) $marca

        [void]$feitos.Add($repo)
        $estado.reposMedidos = @($feitos)
        Save-Estado $estado
    }

    $estado.fase = if ($SemIgnorados) { 'resumo' } else { 'ignorados' }
    Save-Estado $estado
    Write-Etapa "Fase 2 concluida." 'ok'
}

# ------------------------------------------------------ fase 3: ignorados

if ($estado.fase -eq 'ignorados') {
    Write-Etapa "Fase 3/3 - arquivos ignorados de interesse (allowlist de nomes)."

    $feitos = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($x in (ConvertTo-ListaSegura $estado.reposIgnoradosFeitos)) { [void]$feitos.Add([string]$x) }

    $total = $listaRepos.Count
    $i = 0

    foreach ($repo in $listaRepos) {
        $i++
        if ($feitos.Contains($repo)) { continue }

        # Varredura propria, com poda na origem. 'git ls-files --ignored'
        # percorre a arvore inteira: o pathspec :(exclude) filtra a SAIDA, nao a
        # travessia, e um node_modules grande passa a dominar o tempo do
        # inventario todo. Aqui o diretorio pesado nunca chega a ser aberto.
        $candidatos = [System.Collections.Generic.List[string]]::new()
        $pilhaRepo = [System.Collections.Generic.Stack[string]]::new()
        $pilhaRepo.Push($repo)

        while ($pilhaRepo.Count -gt 0) {
            $dir = $pilhaRepo.Pop()

            try { $arquivos = [IO.Directory]::GetFiles($dir) } catch { $arquivos = @() }
            foreach ($a in $arquivos) {
                $nomeArq = Split-Path $a -Leaf
                foreach ($padrao in $NomeIgnoradoDeInteresse) {
                    if ($nomeArq -like $padrao) { $candidatos.Add($a); break }
                }
            }

            try { $subs = [IO.Directory]::GetDirectories($dir) } catch { continue }
            foreach ($s in $subs) {
                $nomeDir = Split-Path $s -Leaf
                if ($nomeDir -eq '.git') { continue }
                if ($PodarDiretorio -contains $nomeDir) { continue }
                if (Test-EhReparsePoint $s) { continue }
                $pilhaRepo.Push($s)
            }
        }

        # Dos candidatos, ficam so os que o git realmente ignora: o resto ja
        # viaja por clone e nao e' problema de migracao.
        $achados = @()
        if ($candidatos.Count -gt 0) {
            $relativos = @($candidatos | ForEach-Object { $_.Substring($repo.Length).TrimStart('\') })
            # UMA string com LF entre os caminhos. Enviar item a item faz o
            # PowerShell terminar cada linha com CRLF, e o CR entra no nome do
            # arquivo (ver ConvertFrom-CaminhoGit). quotePath=false reduz o
            # aspeamento; a normalizacao cobre o que sobrar.
            # O LF final e' de proposito: sem ele o CRLF que o PowerShell
            # acrescenta ao fim gruda um CR no ULTIMO caminho da lista.
            $entrada = ($relativos -join "`n") + "`n"
            $bruto   = @($entrada | & git -C $repo -c core.quotePath=false check-ignore --stdin 2>$null)
            $achados = @($bruto | ForEach-Object { ConvertFrom-CaminhoGit $_ } | Where-Object { $_ })
        }

        foreach ($rel in $achados) {
            $tam = $null
            try { $tam = (Get-Item -LiteralPath (Join-Path $repo $rel) -Force -ErrorAction Stop).Length } catch { }
            [pscustomobject]@{ repo = $repo; relativo = $rel; bytes = $tam } |
                ConvertTo-Json -Depth 3 -Compress |
                Add-Content -LiteralPath $ignorPath -Encoding utf8
        }

        if ($achados.Count -gt 0) {
            Write-Etapa ("[{0}/{1}] {2}: {3} arquivo(s) ignorado(s) de interesse" -f `
                $i, $total, (Split-Path $repo -Leaf), $achados.Count) '!'
        }

        [void]$feitos.Add($repo)
        $estado.reposIgnoradosFeitos = @($feitos)
        Save-Estado $estado
    }

    $estado.fase = 'resumo'
    Save-Estado $estado
    Write-Etapa "Fase 3 concluida." 'ok'
}

# ---------------------------------------------------------------- resumo

Write-Etapa "Gerando resumo."

$repos = @()
if (Test-Path -LiteralPath $reposPath) {
    $repos = @(Get-Content -LiteralPath $reposPath | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
}
$ignorados = @()
if (Test-Path -LiteralPath $ignorPath) {
    $ignorados = @(Get-Content -LiteralPath $ignorPath | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
}

# Uma varredura honesta acha tambem repositorio que nao e' trabalho do dono:
# SDK baixado, cache de gerenciador de pacote, plugin de CLI. Isso nao e' lixo
# a ignorar - e' ruido a SEPARAR, para a decisao do fechamento cair sobre a
# lista curta. A marcacao e' palpite por nome de diretorio, nao veredito.
$segmentoDeRuido = @(
    '.codex', '.codex-pessoal', '.claude', '.claude-pessoal', '.gemini', '.grok',
    '.claude-ce-root', '.claude-ce-root-pessoal', 'dev-cache', 'flutter',
    'marketplaces', 'plugins', '.tmp', '.nuget', '.cargo', '.rustup', 'go', 'sdk'
)
function Test-PareceRuido {
    param([string]$Caminho)
    foreach ($seg in ($Caminho -split '\\')) {
        if ($segmentoDeRuido -contains $seg) { return $true }
    }
    return $false
}

$semRemoto   = @($repos | Where-Object { -not $_.temRemoto })
$comPendente = @($repos | Where-Object { $_.temRemoto -and $_.commitsForaDoRemoto -gt 0 })
$comTrabalho = @($repos | Where-Object { ($_.staged + $_.naoStaged + $_.naoRastreados) -gt 0 })
$comStash    = @($repos | Where-Object { $_.stashes -gt 0 })
$totalFora   = 0
if ($repos.Count -gt 0) {
    $totalFora = ($repos | Measure-Object -Property commitsForaDoRemoto -Sum).Sum
}

$stamp = Get-Date -Format 'yyyy-MM-dd_HHmm'
$md = Join-Path $OutDir "resumo_$stamp.md"

$l = [System.Collections.Generic.List[string]]::new()
$l.Add("# Inventario de migracao - $($estado.host)")
$l.Add('')
$l.Add("Gerado em $(Get-Date -Format 'dd/MM/yyyy HH:mm'). Raizes: $((ConvertTo-ListaSegura $estado.raizes) -join ', ')")
$l.Add("Diretorios visitados: $($estado.diretoriosVisitados). Repositorios: $($repos.Count).")
$l.Add('')
$l.Add('## O que se perde se a maquina for formatada agora')
$l.Add('')
$l.Add('| Situacao | Repositorios |')
$l.Add('|---|---|')
$l.Add("| Sem remoto nenhum | **$($semRemoto.Count)** |")
$l.Add("| Com commits fora de qualquer remoto | **$($comPendente.Count)** |")
$l.Add("| Com trabalho nao commitado | $($comTrabalho.Count) |")
$l.Add("| Com stash | $($comStash.Count) |")
$l.Add("| Arquivos ignorados de interesse | $($ignorados.Count) |")
$l.Add('')
$l.Add("Total de commits que existem so nesta maquina: **$totalFora**.")
$l.Add('')

function Add-SecaoRepos {
    param([string]$Titulo, [object[]]$Itens, [string]$Formato)
    if ($Itens.Count -eq 0) { return }
    $seus  = @($Itens | Where-Object { -not (Test-PareceRuido $_.caminho) })
    $ruido = @($Itens | Where-Object { Test-PareceRuido $_.caminho })

    $l.Add("## $Titulo")
    $l.Add('')
    if ($seus.Count -gt 0) {
        foreach ($r in $seus) { $l.Add(($Formato -f $r.caminho, $r.commitsForaDoRemoto, $r.branch, $r.ultimoCommit, $r.staged, $r.naoStaged, $r.naoRastreados, $r.stashes)) }
    } else {
        $l.Add('Nenhum repositorio de trabalho nesta situacao.')
    }
    if ($ruido.Count -gt 0) {
        $l.Add('')
        $l.Add("<details><summary>Provavel estado de ferramenta, nao trabalho seu ($($ruido.Count)) - conferir, nao presumir</summary>")
        $l.Add('')
        foreach ($r in $ruido) { $l.Add(($Formato -f $r.caminho, $r.commitsForaDoRemoto, $r.branch, $r.ultimoCommit, $r.staged, $r.naoStaged, $r.naoRastreados, $r.stashes)) }
        $l.Add('')
        $l.Add('</details>')
    }
    $l.Add('')
}

Add-SecaoRepos -Titulo 'Sem remoto - decidir: sobe, viaja como arquivo, ou morre com a maquina' `
    -Itens @($semRemoto | Sort-Object caminho) `
    -Formato '- `{0}` - {1} commit(s), ultimo em {3}'

Add-SecaoRepos -Titulo 'Commits locais fora do remoto' `
    -Itens @($comPendente | Sort-Object -Property commitsForaDoRemoto -Descending) `
    -Formato '- `{0}` - **{1}** commit(s), branch `{2}`'

Add-SecaoRepos -Titulo 'Trabalho nao commitado - some sem deixar rastro numa formatacao' `
    -Itens @($comTrabalho | Sort-Object caminho) `
    -Formato '- `{0}` - staged {4}, modificado {5}, nao rastreado {6}, stash {7}'

if ($ignorados.Count -gt 0) {
    $l.Add('## Arquivos ignorados de interesse')
    $l.Add('')
    $l.Add('Ignorados pelo Git, logo nao viajam por clone. Apenas caminhos; conteudo nunca foi lido.')
    $l.Add('')
    foreach ($g in ($ignorados | Group-Object repo | Sort-Object Count -Descending)) {
        $l.Add("- ``$($g.Name)`` - $($g.Count) arquivo(s)")
    }
    $l.Add('')
}

$l.Add('## Como usar')
$l.Add('')
$l.Add('Rode de novo perto do fechamento e compare com este resumo: o valor esta no delta.')
$l.Add('Repositorio sem remoto e commit fora do remoto sao as unicas perdas irreversiveis')
$l.Add('de uma formatacao. O resto se reinstala.')

Set-Content -LiteralPath $md -Value ($l -join [Environment]::NewLine) -Encoding utf8

Write-Host ''
Write-Etapa "Resumo: $md" 'ok'
Write-Host ''
Write-Host ("  repositorios .............. {0}" -f $repos.Count)
Write-Host ("  sem remoto nenhum ......... {0}" -f $semRemoto.Count)
$comCommitSoAqui = @($repos | Where-Object { $_.commitsForaDoRemoto -gt 0 })
$seusComCommit   = @($comCommitSoAqui | Where-Object { -not (Test-PareceRuido $_.caminho) })
Write-Host ("  commits so nesta maquina .. {0} em {1} repo(s), sendo {2} de trabalho seu" -f `
    $totalFora, $comCommitSoAqui.Count, $seusComCommit.Count)
Write-Host ("  trabalho nao commitado .... {0} repo(s)" -f $comTrabalho.Count)
Write-Host ("  ignorados de interesse .... {0} arquivo(s)" -f $ignorados.Count)
