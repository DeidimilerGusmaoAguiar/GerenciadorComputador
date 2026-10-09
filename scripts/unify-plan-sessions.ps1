<#
.SYNOPSIS
Unifica sessoes, memoria e anexos dos planos de IA num store unico.

.DESCRIPTION
Cada plano da CLI tem um diretorio de estado proprio, e e' isso que mantem as
contas separadas. Mas o historico nao e' propriedade da conta: uma sessao aberta
no plano corporativo descreve o mesmo repositorio que o plano dev vai abrir
amanha, e a memoria do projeto mora dentro de projects\<slug>\memory. Com um
store por plano, "claude -r" so enxerga o que aquele plano gravou.

Este script move os stores para uma raiz comum e deixa, no lugar de cada um,
uma junction. O que continua separado por plano: .claude.json (conta),
.credentials.json (token), settings.json, skills e agents (blindagem).

Nada e' apagado. Arquivo com nome repetido e conteudo diferente e' preservado
ao lado, com sufixo do plano de origem; MEMORY.md, que e' indice de ponteiros,
e' fundido pela uniao das linhas. Arquivo aberto por sessao viva e' pulado e
denunciado no fim - rode de novo depois de fechar a sessao.

.PARAMETER MapPath
Mapa de perfis. Padrao: local\perfis-cli.json na raiz do repositorio.

.PARAMETER Execute
Sem este switch nada e' movido: o script so mede e imprime o plano.

.EXAMPLE
pwsh -NoProfile -File .\scripts\unify-plan-sessions.ps1
Mostra o que seria movido, sem tocar em nada.

.EXAMPLE
pwsh -NoProfile -File .\scripts\unify-plan-sessions.ps1 -Execute
Executa a unificacao e grava o manifesto de reversao em reports\.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$MapPath,
    [string]$Cli = 'claude',
    [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $MapPath) { $MapPath = Join-Path $repoRoot 'local\perfis-cli.json' }
if (-not (Test-Path -LiteralPath $MapPath -PathType Leaf)) {
    throw "Mapa de perfis nao encontrado: $MapPath"
}

$mapa = Get-Content -LiteralPath $MapPath -Raw | ConvertFrom-Json
if (-not $mapa.routing.PSObject.Properties.Name.Contains($Cli)) {
    throw "O mapa nao tem routing para a CLI '$Cli'."
}
$routing = $mapa.routing.$Cli
if ($routing.PSObject.Properties.Name -notcontains 'sharedState') {
    throw "routing.$Cli sem a secao 'sharedState'. Declare a raiz comum antes de unificar."
}
$compartilhado = $routing.sharedState

$raizComum = [IO.Path]::GetFullPath([string]$compartilhado.root)
$pastas = @($compartilhado.folders | ForEach-Object { [string]$_ })
$arquivos = @(
    if ($compartilhado.PSObject.Properties.Name -contains 'files') {
        $compartilhado.files | ForEach-Object { [string]$_ }
    }
)

# Um plano so entra na unificacao se declara lado: perfil de inventario, sem
# side, existe para medir cobertura de antimalware e nao tem historico proprio.
$planos = @(
    $mapa.profiles |
        Where-Object { $_.cli -eq $Cli -and $_.PSObject.Properties.Name -contains 'side' } |
        ForEach-Object {
            [pscustomobject]@{
                Rotulo = '{0}-{1}' -f $_.side, $_.shield
                Home = [IO.Path]::GetFullPath([string]$_.home)
            }
        }
)
if ($planos.Count -eq 0) { throw "Nenhum perfil de '$Cli' declara lado." }

$carimbo = Get-Date -Format 'yyyy-MM-dd_HHmm'
$manifesto = [Collections.Generic.List[object]]::new()
$travados = [Collections.Generic.List[string]]::new()
$aviso = [Collections.Generic.List[string]]::new()

# Em dry-run o destino ainda nao existe, e sem isso todo plano pareceria cair
# numa pasta vazia: o relatorio esconderia justamente os conflitos. O indice
# virtual guarda o que uma execucao real ja teria colocado la, e de qual origem,
# para que a comparacao de conteudo seja a mesma dos dois modos.
$script:Virtual = @{}
$script:VirtualDirs = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

function Resolve-Destino {
    <#
    .SYNOPSIS
    Diz se o destino ja esta ocupado e por qual arquivo de origem.
    #>
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path -LiteralPath $Path) { return $Path }
    if (-not $Execute -and $script:Virtual.ContainsKey($Path.ToLowerInvariant())) {
        return $script:Virtual[$Path.ToLowerInvariant()]
    }
    return ''
}

function Register-Destino {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Origem
    )
    if ($Execute) { return }
    $script:Virtual[$Path.ToLowerInvariant()] = $Origem
    $pai = Split-Path -Parent $Path
    while ($pai -and -not $script:VirtualDirs.Contains($pai)) {
        $null = $script:VirtualDirs.Add($pai)
        $pai = Split-Path -Parent $pai
    }
}

function Test-DestinoPasta {
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Container) { return $true }
    return (-not $Execute) -and $script:VirtualDirs.Contains($Path)
}

function Register-Arvore {
    <#
    .SYNOPSIS
    Registra no indice virtual toda a arvore que um rename levaria de uma vez.
    #>
    param(
        [Parameter(Mandatory)][string]$Origem,
        [Parameter(Mandatory)][string]$Destino
    )
    if ($Execute) { return }
    foreach ($f in @(Get-ChildItem -LiteralPath $Origem -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        $relativo = $f.FullName.Substring($Origem.Length).TrimStart('\')
        Register-Destino -Path (Join-Path $Destino $relativo) -Origem $f.FullName
    }
}

function Test-Vinculo {
    param([Parameter(Mandatory)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return $false }
    return [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
}

function Remove-Vinculo {
    <#
    .SYNOPSIS
    Apaga o ponto de reparse sem seguir para o alvo.

    .DESCRIPTION
    Remove-Item -Recurse ja apagou conteudo de alvo de junction em versoes
    antigas do PowerShell. Directory.Delete sem recursao so pode apagar o link.
    #>
    param([Parameter(Mandatory)][string]$Path)
    [IO.Directory]::Delete($Path, $false)
}

function Get-Hash {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Merge-IndiceMemoria {
    <#
    .SYNOPSIS
    Funde dois MEMORY.md pela uniao das linhas, preservando a ordem do destino.

    .DESCRIPTION
    MEMORY.md e' indice: uma linha por memoria. Sobrescrever perde ponteiros dos
    dois lados, e guardar duas copias faz a CLI carregar um indice e ignorar o
    outro. A uniao e' a unica fusao que nao perde nem duplica.
    #>
    param(
        [Parameter(Mandatory)][string]$Destino,
        [Parameter(Mandatory)][string]$Origem
    )
    $atuais = @(Get-Content -LiteralPath $Destino -ErrorAction SilentlyContinue)
    $vistos = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($linha in $atuais) { $null = $vistos.Add($linha.Trim()) }
    $novas = @(
        Get-Content -LiteralPath $Origem -ErrorAction SilentlyContinue |
            Where-Object { -not $vistos.Contains($_.Trim()) }
    )
    if ($novas.Count -eq 0) { return 0 }
    $saida = @($atuais) + @($novas)
    Set-Content -LiteralPath $Destino -Value $saida -Encoding utf8NoBOM
    return $novas.Count
}

function Merge-Pasta {
    <#
    .SYNOPSIS
    Move o conteudo de uma pasta para dentro de outra, sem sobrescrever.

    .DESCRIPTION
    Pasta inexistente no destino vira rename - instantaneo, sem copiar byte, por
    estarem no mesmo volume. Pasta que ja existe e' percorrida arquivo a arquivo.
    #>
    param(
        [Parameter(Mandatory)][string]$Origem,
        [Parameter(Mandatory)][string]$Destino,
        [Parameter(Mandatory)][string]$Rotulo,
        [Parameter(Mandatory)][hashtable]$Conta,
        [Parameter(Mandatory)][string]$RaizOrigem,
        [Parameter(Mandatory)][string]$RaizConflito
    )

    if (-not (Test-Path -LiteralPath $Destino -PathType Container)) {
        if ($Execute) { $null = New-Item -ItemType Directory -Path $Destino -Force }
    }

    foreach ($filho in @(Get-ChildItem -LiteralPath $Origem -Force -ErrorAction SilentlyContinue)) {
        $alvo = Join-Path $Destino $filho.Name
        $ehVinculo = [bool]($filho.Attributes -band [IO.FileAttributes]::ReparsePoint)

        if ($ehVinculo) {
            # Junction de projeto aponta para o store de outro plano: o conteudo
            # entra pela origem dele, nao por aqui. Some o link, nao o alvo.
            $Conta.Vinculos++
            if ($Execute) {
                try { Remove-Vinculo -Path $filho.FullName }
                catch { $travados.Add("vinculo preso: $($filho.FullName)") }
            }
            continue
        }

        if ($filho.PSIsContainer) {
            if (-not (Test-DestinoPasta -Path $alvo)) {
                $Conta.PastasMovidas++
                if ($Execute) {
                    try { Move-Item -LiteralPath $filho.FullName -Destination $alvo -ErrorAction Stop }
                    catch { $travados.Add("pasta em uso: $($filho.FullName)") }
                } else {
                    Register-Arvore -Origem $filho.FullName -Destino $alvo
                }
            } else {
                Merge-Pasta -Origem $filho.FullName -Destino $alvo -Rotulo $Rotulo -Conta $Conta `
                    -RaizOrigem $RaizOrigem -RaizConflito $RaizConflito
                if ($Execute -and @(Get-ChildItem -LiteralPath $filho.FullName -Force).Count -eq 0) {
                    Remove-Item -LiteralPath $filho.FullName -Force
                }
            }
            continue
        }

        $ocupado = Resolve-Destino -Path $alvo
        if (-not $ocupado) {
            $Conta.ArquivosMovidos++
            if ($Execute) {
                try { Move-Item -LiteralPath $filho.FullName -Destination $alvo -ErrorAction Stop }
                catch { $travados.Add("arquivo em uso: $($filho.FullName)") }
            } else {
                Register-Destino -Path $alvo -Origem $filho.FullName
            }
            continue
        }

        if ($filho.Name -eq 'MEMORY.md') {
            $Conta.IndicesFundidos++
            if ($Execute) {
                $null = Merge-IndiceMemoria -Destino $alvo -Origem $filho.FullName
                Remove-Item -LiteralPath $filho.FullName -Force
            }
            continue
        }

        if ((Get-Hash -Path $filho.FullName) -eq (Get-Hash -Path $ocupado)) {
            $Conta.Identicos++
            if ($Execute) { Remove-Item -LiteralPath $filho.FullName -Force }
            continue
        }

        # Mesmo nome, conteudo diferente. O perdedor nao pode ficar ao lado do
        # vencedor: file-history e projects sao namespaces que a CLI le por
        # padrao de nome - "<hash>@v2" com sufixo colado deixa de ser uma versao
        # e vira arquivo que ninguem abre. Ele sai inteiro para .conflitos,
        # preservando o caminho relativo, de onde da' para conferir a mao.
        $relativo = $filho.FullName.Substring($RaizOrigem.Length).TrimStart('\')
        $lado = Join-Path (Join-Path $RaizConflito $Rotulo) $relativo
        $Conta.Conflitos++
        if ($Execute) {
            $paiConflito = Split-Path -Parent $lado
            if (-not (Test-Path -LiteralPath $paiConflito)) {
                $null = New-Item -ItemType Directory -Path $paiConflito -Force
            }
            try { Move-Item -LiteralPath $filho.FullName -Destination $lado -ErrorAction Stop }
            catch { $travados.Add("arquivo em uso: $($filho.FullName)") }
        }
    }
}

function Set-Junction {
    param(
        [Parameter(Mandatory)][string]$Link,
        [Parameter(Mandatory)][string]$Alvo
    )
    if ($Execute) {
        $null = New-Item -ItemType Junction -Path $Link -Target $Alvo -ErrorAction Stop
    }
}

Write-Host ''
Write-Host ('  Unificacao de planos - ' + $(if ($Execute) { 'EXECUCAO' } else { 'DRY-RUN (nada sera movido)' })) -ForegroundColor $(if ($Execute) { 'Yellow' } else { 'Cyan' })
Write-Host ('  store comum : ' + $raizComum) -ForegroundColor DarkGray
Write-Host ('  planos      : ' + (@($planos.Rotulo) -join ', ')) -ForegroundColor DarkGray
Write-Host ''

if ($Execute -and -not (Test-Path -LiteralPath $raizComum -PathType Container)) {
    if ($PSCmdlet.ShouldProcess($raizComum, 'criar store comum')) {
        $null = New-Item -ItemType Directory -Path $raizComum -Force
    }
}

# ---- pastas ----
foreach ($pasta in $pastas) {
    $destino = Join-Path $raizComum $pasta
    Write-Host ("  [$pasta]") -ForegroundColor White

    foreach ($plano in $planos) {
        $origem = Join-Path $plano.Home $pasta
        $existe = Test-Path -LiteralPath $origem

        if (-not $existe) {
            Write-Host ('    {0,-24} ausente -> junction nova' -f $plano.Rotulo) -ForegroundColor DarkGray
            if ($Execute -and $PSCmdlet.ShouldProcess($origem, 'criar junction')) {
                if (-not (Test-Path -LiteralPath $destino)) { $null = New-Item -ItemType Directory -Path $destino -Force }
                Set-Junction -Link $origem -Alvo $destino
            }
            continue
        }

        if (Test-Vinculo -Path $origem) {
            $atual = (Get-Item -LiteralPath $origem -Force).Target -join ','
            if ([IO.Path]::GetFullPath($atual).TrimEnd('\') -eq $destino.TrimEnd('\')) {
                Write-Host ('    {0,-24} ja aponta para o store comum' -f $plano.Rotulo) -ForegroundColor DarkGreen
                continue
            }
            Write-Host ('    {0,-24} junction antiga -> {1}' -f $plano.Rotulo, $atual) -ForegroundColor DarkYellow
            if ($Execute -and $PSCmdlet.ShouldProcess($origem, 'refazer junction')) {
                Remove-Vinculo -Path $origem
                if (-not (Test-Path -LiteralPath $destino)) { $null = New-Item -ItemType Directory -Path $destino -Force }
                Set-Junction -Link $origem -Alvo $destino
            }
            continue
        }

        $conta = @{
            PastasMovidas = 0; ArquivosMovidos = 0; Identicos = 0
            Conflitos = 0; IndicesFundidos = 0; Vinculos = 0
        }
        $antes = @(Get-ChildItem -LiteralPath $origem -Recurse -File -Force -ErrorAction SilentlyContinue)
        Merge-Pasta -Origem $origem -Destino $destino -Rotulo $plano.Rotulo -Conta $conta `
            -RaizOrigem $origem -RaizConflito (Join-Path (Join-Path $raizComum '.conflitos') $pasta)

        $bytes = if ($antes.Count -gt 0) { ($antes | Measure-Object Length -Sum).Sum } else { 0 }
        Write-Host (
            '    {0,-24} {1} arq / {2} MB  ->  pastas={3} arq={4} identicos={5} fundidos={6} conflitos={7} links={8}' -f
                $plano.Rotulo, $antes.Count,
                [math]::Round($bytes / 1MB, 1),
                $conta.PastasMovidas, $conta.ArquivosMovidos, $conta.Identicos,
                $conta.IndicesFundidos, $conta.Conflitos, $conta.Vinculos
        ) -ForegroundColor Gray

        $manifesto.Add([pscustomobject]@{
            plano = $plano.Rotulo; asset = $pasta; origem = $origem; destino = $destino
            arquivos = $antes.Count; resultado = $conta
        })

        if (-not $Execute) { continue }

        $resto = @(Get-ChildItem -LiteralPath $origem -Recurse -Force -ErrorAction SilentlyContinue)
        if ($resto.Count -gt 0) {
            $aviso.Add("$($plano.Rotulo)\$pasta continuou como pasta real: $($resto.Count) itens em uso")
            Write-Host ('      NAO virou junction: {0} itens ainda em uso' -f $resto.Count) -ForegroundColor Red
            continue
        }
        if ($PSCmdlet.ShouldProcess($origem, 'trocar pasta vazia por junction')) {
            Remove-Item -LiteralPath $origem -Force
            Set-Junction -Link $origem -Alvo $destino
        }
    }
    Write-Host ''
}

# ---- arquivos ----
foreach ($arquivo in $arquivos) {
    $destino = Join-Path $raizComum $arquivo
    Write-Host ("  [$arquivo]") -ForegroundColor White

    # Uniao das linhas, ordenada por timestamp. O historico e' JSONL append-only:
    # linha repetida e' a mesma digitacao, nao duas.
    $linhas = [Collections.Generic.List[string]]::new()
    $vistas = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $fontes = @(
        if (Test-Path -LiteralPath $destino -PathType Leaf) { $destino }
        $planos | ForEach-Object { Join-Path $_.Home $arquivo }
    )
    foreach ($fonte in $fontes) {
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
    Write-Host ('    uniao: {0} linhas de {1} fontes' -f $ordenadas.Count, @($fontes).Count) -ForegroundColor Gray

    if (-not $Execute) { Write-Host ''; continue }
    if (-not $PSCmdlet.ShouldProcess($destino, 'gravar uniao e religar planos')) { continue }

    Set-Content -LiteralPath $destino -Value $ordenadas -Encoding utf8NoBOM

    foreach ($plano in $planos) {
        $link = Join-Path $plano.Home $arquivo
        if (-not (Test-Path -LiteralPath $plano.Home -PathType Container)) { continue }
        if (Test-Path -LiteralPath $link -PathType Leaf) {
            # O conteudo ja esta na uniao; o original vira copia datada, nao lixo.
            $backup = '{0}.antes-da-uniao-{1}' -f $link, $carimbo
            try { Move-Item -LiteralPath $link -Destination $backup -ErrorAction Stop }
            catch { $travados.Add("arquivo em uso: $link"); continue }
        }
        try {
            $null = New-Item -ItemType HardLink -Path $link -Target $destino -ErrorAction Stop
            Write-Host ('    {0,-24} hardlink criado' -f $plano.Rotulo) -ForegroundColor DarkGreen
        } catch {
            $aviso.Add("hardlink falhou em $link : $($_.Exception.Message)")
            Write-Host ('    {0,-24} hardlink FALHOU' -f $plano.Rotulo) -ForegroundColor Red
        }
    }
    Write-Host ''
}

# ---- fecho ----
if ($travados.Count -gt 0) {
    Write-Host '  Itens em uso, deixados no lugar:' -ForegroundColor Red
    foreach ($t in $travados | Select-Object -Unique) { Write-Host ('    ' + $t) -ForegroundColor Red }
    Write-Host '  Feche as sessoes que os seguram e rode o script de novo.' -ForegroundColor Red
    Write-Host ''
}
foreach ($a in $aviso) { Write-Host ('  atencao: ' + $a) -ForegroundColor DarkYellow }

if ($Execute -and $manifesto.Count -gt 0) {
    $pastaRelatorio = Join-Path $repoRoot 'reports'
    if (-not (Test-Path -LiteralPath $pastaRelatorio)) { $null = New-Item -ItemType Directory -Path $pastaRelatorio -Force }
    $destinoManifesto = Join-Path $pastaRelatorio ('unificacao-planos_' + $carimbo + '.json')
    [pscustomobject]@{
        host = $env:COMPUTERNAME
        quando = (Get-Date).ToString('o')
        cli = $Cli
        storeComum = $raizComum
        travados = @($travados | Select-Object -Unique)
        avisos = @($aviso)
        movimentos = @($manifesto)
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $destinoManifesto -Encoding utf8NoBOM
    Write-Host ('  manifesto de reversao: ' + $destinoManifesto) -ForegroundColor DarkGray
}

if (-not $Execute) {
    Write-Host '  Dry-run. Para executar: -Execute' -ForegroundColor Cyan
}
Write-Host ''
