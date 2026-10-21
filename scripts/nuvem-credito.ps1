<#
.SYNOPSIS
Lanca sessoes na nuvem do Claude Code contra o credito de sessao na nuvem,
com orcamento e registro geridos por este repositorio.

.DESCRIPTION
O credito de sessao na nuvem e' um valor unico por conta, com data de
validade, que se aplica sozinho a sessoes na nuvem e, quando acaba, passa a
gastar o limite do plano. A CLI nao mostra o saldo. Por isso este script:

- recusa projeto sem alocacao em local\creditos-nuvem\orcamento.json;
- recusa credito vencido, sessao sem teto e soma de tetos acima da alocacao
  ou do saldo informado pelo dono;
- registra cada sessao em local\creditos-nuvem\registro.jsonl;
- mostra o saldo estimado com -Saldo.

A sessao e' criada como rotina de execucao unica (API de rotinas do
claude.ai), pela CLI logada na conta do lado, rodando numa pasta vazia:
"claude --cloud" so cria sessao no modo interativo. A credencial nunca passa
por este script. O dry-run e' o padrao; -Execute cria a sessao.

O custo real de cada sessao nao chega ate aqui: o teto declarado conta como
gasto ate o dono informar o saldo da pagina (saldoInformado no orcamento).

.EXAMPLE
pwsh -NoProfile -File .\scripts\nuvem-credito.ps1 -Saldo

.EXAMPLE
pwsh -NoProfile -File .\scripts\nuvem-credito.ps1 -ArquivoTarefa .\tarefa.md -Titulo 'FAR-123' -Teto 5 -Modelo sonnet

.EXAMPLE
pwsh -NoProfile -File .\scripts\nuvem-credito.ps1 -ArquivoTarefa .\tarefa.md -Titulo 'FAR-123' -Teto 5 -Modelo sonnet -Execute
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium', DefaultParameterSetName = 'Saldo')]
param(
    [Parameter(ParameterSetName = 'Saldo')]
    [switch]$Saldo,

    [Parameter(ParameterSetName = 'Lancar', Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Titulo,

    [Parameter(ParameterSetName = 'Lancar')]
    [string]$Tarefa,

    [Parameter(ParameterSetName = 'Lancar')]
    [string]$ArquivoTarefa,

    [Parameter(ParameterSetName = 'Lancar', Mandatory)]
    [ValidateRange(0.01, 100)]
    [double]$Teto,

    [Parameter(ParameterSetName = 'Lancar')]
    [ValidateSet('haiku', 'sonnet', 'opus')]
    [string]$Modelo = 'sonnet',

    [Parameter(ParameterSetName = 'Lancar')]
    [ValidateNotNullOrEmpty()]
    [string[]]$Ferramentas = @('Bash', 'Read', 'Write', 'Edit', 'Glob', 'Grep'),

    [Parameter(ParameterSetName = 'Lancar')]
    [string]$Pasta = (Get-Location).ProviderPath,

    [Parameter(ParameterSetName = 'Lancar')]
    [ValidateSet('pessoal', 'dev')]
    [string]$Lado,

    [Parameter(ParameterSetName = 'Lancar')]
    [switch]$Execute,

    [ValidateRange(30, 900)]
    [int]$PrazoSegundos = 240
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$inv = [Globalization.CultureInfo]::InvariantCulture
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$pastaCredito = Join-Path $repoRoot 'local\creditos-nuvem'
$arquivoOrcamento = Join-Path $pastaCredito 'orcamento.json'
$arquivoRegistro = Join-Path $pastaCredito 'registro.jsonl'
$modelos = @{ haiku = 'claude-haiku-5-5'; sonnet = 'claude-sonnet-5-5'; opus = 'claude-opus-5-5' }

function Test-Propriedade {
    param($Objeto, [string]$Nome)
    return ($null -ne $Objeto) -and ($Objeto.PSObject.Properties.Name -contains $Nome)
}

function Test-DentroDe {
    param([string]$Caminho, [string]$Raiz)
    $c = [IO.Path]::GetFullPath($Caminho).TrimEnd('\') + '\'
    $r = [IO.Path]::GetFullPath($Raiz).TrimEnd('\') + '\'
    return $c.StartsWith($r, [StringComparison]::OrdinalIgnoreCase)
}

function Get-Orcamento {
    if (-not (Test-Path -LiteralPath $arquivoOrcamento)) {
        throw "Orcamento do credito de nuvem nao encontrado: $arquivoOrcamento"
    }
    return (Get-Content -LiteralPath $arquivoOrcamento -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Get-Registro {
    $saida = @()
    if (-not (Test-Path -LiteralPath $arquivoRegistro)) { return $saida }
    foreach ($linha in Get-Content -LiteralPath $arquivoRegistro -Encoding UTF8) {
        if ([string]::IsNullOrWhiteSpace($linha)) { continue }
        try {
            $e = $linha | ConvertFrom-Json
        } catch {
            # Linha ilegivel subconta o gasto: avisa em vez de pular calado.
            Write-Host "  atencao: linha ilegivel no registro, fora da conta: $($linha.Substring(0, [Math]::Min(80, $linha.Length)))" -ForegroundColor Red
            continue
        }
        $quando = $e.quando
        if ($quando -isnot [datetime]) {
            $quando = [datetime]::ParseExact([string]$quando, 'yyyy-MM-ddTHH:mm:ss', $inv)
        }
        $saida += [pscustomobject]@{
            Quando = $quando; Lado = [string]$e.lado; Projeto = [string]$e.projeto
            Teto = [double]$e.teto; Rotina = [string]$e.rotina; Titulo = [string]$e.titulo
        }
    }
    return $saida
}

function Add-Registro {
    # Uma linha JSON por sessao. Varias sessoes podem gravar juntas: tenta de novo.
    param([Parameter(Mandatory)]$Dados)
    if (-not (Test-Path -LiteralPath $pastaCredito)) { $null = New-Item -ItemType Directory -Path $pastaCredito }
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes((([pscustomobject]$Dados) | ConvertTo-Json -Compress) + "`n")
    for ($i = 0; $i -lt 20; $i++) {
        try {
            $fs = [IO.File]::Open($arquivoRegistro, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read)
            try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Close() }
            return
        } catch {
            Start-Sleep -Milliseconds 150
        }
    }
    Write-Host "  atencao: nao consegui gravar o registro em $arquivoRegistro" -ForegroundColor Red
}

function Get-SituacaoLado {
    # Saldo estimado: o ultimo saldo informado pelo dono menos os tetos lancados depois dele.
    param($Orcamento, [string]$Lado, $Registro)
    $cfg = $Orcamento.lados.$Lado
    $credito = [double]$cfg.credito
    $base = $credito
    $desde = [datetime]::MinValue
    if ((Test-Propriedade $cfg 'saldoInformado') -and $null -ne $cfg.saldoInformado) {
        $base = [double]$cfg.saldoInformado.valor
        $desde = [datetime]::Parse([string]$cfg.saldoInformado.em, $inv)
    }
    $depois = 0.0
    foreach ($e in @($Registro | Where-Object { $_.Lado -eq $Lado -and $_.Quando -ge $desde })) { $depois += $e.Teto }
    $expira = $null
    if ((Test-Propriedade $cfg 'expira') -and $cfg.expira) { $expira = [datetimeoffset]::Parse([string]$cfg.expira, $inv) }
    return [pscustomobject]@{
        Credito = $credito; Base = $base; Desde = $desde; DepoisDaBase = $depois
        Estimado = ($base - $depois); Expira = $expira
        Vencido = ($null -ne $expira -and [datetimeoffset]::Now -ge $expira)
    }
}

function Show-Saldo {
    $orc = Get-Orcamento
    $reg = @(Get-Registro)
    Write-Host ''
    Write-Host "  Credito de sessao na nuvem - orcamento: $arquivoOrcamento" -ForegroundColor White
    foreach ($lado in @($orc.lados.PSObject.Properties.Name | Sort-Object)) {
        $s = Get-SituacaoLado -Orcamento $orc -Lado $lado -Registro $reg
        $validade = 'sem validade informada'
        if ($s.Expira) {
            $dias = [Math]::Floor(($s.Expira - [datetimeoffset]::Now).TotalDays)
            $validade = 'vence ' + $s.Expira.ToLocalTime().ToString('dd/MM HH:mm', $inv) + $(if ($s.Vencido) { ' (VENCIDO)' } else { " (faltam $dias dia(s))" })
        }
        Write-Host ''
        Write-Host ("  {0}  credito US$ {1}   {2}   saldo estimado US$ {3}" -f $lado, $s.Credito.ToString('0.00', $inv), $validade, $s.Estimado.ToString('0.00', $inv))
        if ($s.Desde -ne [datetime]::MinValue) {
            Write-Host ("     base: US$ {0} informado pelo dono em {1}; tetos lancados depois: US$ {2}" -f $s.Base.ToString('0.00', $inv),
                $s.Desde.ToString('dd/MM HH:mm', $inv), $s.DepoisDaBase.ToString('0.00', $inv)) -ForegroundColor DarkGray
        }
        foreach ($a in @($orc.alocacoes | Where-Object { [string]$_.lado -eq $lado })) {
            $doProjeto = @($reg | Where-Object { $_.Lado -eq $lado -and $_.Projeto -eq [string]$a.projeto })
            $g = 0.0; foreach ($e in $doProjeto) { $g += $e.Teto }
            Write-Host ('     {0,-16} teto {1,7}   comprometido {2,7}   resta {3,7}   {4} sessao(oes)' -f [string]$a.projeto,
                ([double]$a.teto).ToString('0.00', $inv), $g.ToString('0.00', $inv), ([double]$a.teto - $g).ToString('0.00', $inv),
                $doProjeto.Count) -ForegroundColor DarkGray
        }
    }
    Write-Host ''
    Write-Host '  O custo real nao chega a CLI: cada sessao conta pelo teto declarado ate o dono informar o saldo da pagina.' -ForegroundColor DarkGray
    Write-Host ''
}

function Invoke-ClaudeConta {
    # Roda "claude -p" na conta do lado, numa pasta vazia, com prazo e entrada fechada.
    param([string]$Estado, [string]$PastaTrabalho, [string]$Pedido)
    $exe = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $exe) { throw 'CLI claude nao encontrada no PATH.' }
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $exe.Source
    # Sonnet: o haiku quebrou o JSON ao copiar um pedido longo para a chamada (11/10/2026).
    foreach ($a in @('-p', $Pedido, '--model', 'sonnet', '--allowedTools', 'ToolSearch,RemoteTrigger,Read', '--output-format', 'json')) {
        $psi.ArgumentList.Add($a)
    }
    $psi.WorkingDirectory = $PastaTrabalho
    $psi.UseShellExecute = $false
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.CreateNoWindow = $true
    $psi.Environment['CLAUDE_CONFIG_DIR'] = $Estado
    # Sessao na nuvem e' do plano: chave de API no ambiente mudaria a conta cobrada.
    foreach ($v in @('ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN')) { $null = $psi.Environment.Remove($v) }
    $p = [Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    $saida = $p.StandardOutput.ReadToEndAsync()
    $null = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($PrazoSegundos * 1000)) {
        try { $p.Kill($true) } catch { }
        return [pscustomobject]@{ Texto = ''; Estourou = $true; Codigo = $null }
    }
    $p.WaitForExit()
    return [pscustomobject]@{ Texto = [string]$saida.Result; Estourou = $false; Codigo = $p.ExitCode }
}

if ($PSCmdlet.ParameterSetName -eq 'Saldo') {
    Show-Saldo
    return
}

# --- Lancar ---
if ([string]::IsNullOrWhiteSpace($Tarefa) -eq [string]::IsNullOrWhiteSpace($ArquivoTarefa)) {
    throw 'Informe a tarefa por -Tarefa ou por -ArquivoTarefa (um dos dois).'
}
if ($ArquivoTarefa) {
    $caminhoTarefa = [IO.Path]::GetFullPath($ArquivoTarefa)
    if (-not (Test-Path -LiteralPath $caminhoTarefa -PathType Leaf)) { throw "Arquivo da tarefa nao encontrado: $caminhoTarefa" }
    $Tarefa = Get-Content -LiteralPath $caminhoTarefa -Raw -Encoding UTF8
}
$Pasta = [IO.Path]::GetFullPath($Pasta)

$orc = Get-Orcamento
$reg = @(Get-Registro)

if ($Lado -and (Test-Propriedade $orc.lados $Lado) -and [double]$orc.lados.$Lado.credito -le 0) {
    Write-Host "  Recusado: a conta $Lado nao tem credito de sessao na nuvem. Sessao na nuvem por ela gastaria o limite do plano." -ForegroundColor Red
    exit 2
}

# Alocacao da pasta; a raiz mais especifica vence. Lado opcional desempata.
$aloc = $null
$tamanho = -1
foreach ($a in @($orc.alocacoes)) {
    if ($Lado -and [string]$a.lado -ne $Lado) { continue }
    if (-not (Test-DentroDe -Caminho $Pasta -Raiz ([string]$a.raiz))) { continue }
    if (([string]$a.raiz).Length -gt $tamanho) { $aloc = $a; $tamanho = ([string]$a.raiz).Length }
}
if (-not $aloc) {
    Write-Host "  Recusado: sem alocacao de credito de nuvem para $Pasta." -ForegroundColor Red
    Write-Host "  O orcamento e do repositorio que gerencia os planos ($arquivoOrcamento): peca ao dono." -ForegroundColor DarkGray
    exit 2
}
$ladoAloc = [string]$aloc.lado
$cfg = $orc.lados.$ladoAloc
if ((Test-Propriedade $cfg 'pausa') -and -not [string]::IsNullOrWhiteSpace([string]$cfg.pausa)) {
    Write-Host ("  Recusado: lancamentos na nuvem pelo lado $ladoAloc estao PAUSADOS: " + [string]$cfg.pausa) -ForegroundColor Red
    Write-Host '  So o dono tira a pausa, no orcamento deste repositorio.' -ForegroundColor DarkGray
    exit 2
}
$s = Get-SituacaoLado -Orcamento $orc -Lado $ladoAloc -Registro $reg
if ($s.Vencido) {
    Write-Host ("  Recusado: o credito de nuvem do lado $ladoAloc venceu em " + $s.Expira.ToLocalTime().ToString('dd/MM HH:mm', $inv) +
        '. Depois disso a sessao gastaria o limite do plano.') -ForegroundColor Red
    exit 2
}
$comprometido = 0.0
foreach ($e in @($reg | Where-Object { $_.Lado -eq $ladoAloc -and $_.Projeto -eq [string]$aloc.projeto })) { $comprometido += $e.Teto }
if (($comprometido + $Teto) -gt ([double]$aloc.teto + 0.000001)) {
    Write-Host ("  Recusado: {0} ja comprometeu US$ {1} de US$ {2}; esta sessao pede US$ {3}." -f [string]$aloc.projeto,
        $comprometido.ToString('0.00', $inv), ([double]$aloc.teto).ToString('0.00', $inv), $Teto.ToString('0.00', $inv)) -ForegroundColor Red
    Write-Host '  Mais credito para o projeto e decisao do dono, no orcamento deste repositorio.' -ForegroundColor DarkGray
    exit 2
}
if ($Teto -gt ($s.Estimado + 0.000001)) {
    Write-Host ("  Recusado: saldo estimado do lado {0} e US$ {1}; esta sessao pede US$ {2}. Passar disso gastaria o plano." -f $ladoAloc,
        $s.Estimado.ToString('0.00', $inv), $Teto.ToString('0.00', $inv)) -ForegroundColor Red
    Write-Host '  Peca ao dono o saldo atual da pagina (Creditos de sessao na nuvem) para atualizar saldoInformado.' -ForegroundColor DarkGray
    exit 2
}
foreach ($campo in @('estado', 'ambiente')) {
    if (-not (Test-Propriedade $cfg $campo) -or [string]::IsNullOrWhiteSpace([string]$cfg.$campo)) {
        throw "Orcamento sem lados.$ladoAloc.$campo."
    }
}
if (-not (Test-Propriedade $aloc 'repositorio') -or [string]::IsNullOrWhiteSpace([string]$aloc.repositorio)) {
    throw "Alocacao de $([string]$aloc.projeto) sem repositorio."
}

# Marca de fim: depois de criar, a rotina e' lida de volta e, sem a marca, desativada.
# Pedido truncado ao ser copiado para a chamada ja aconteceu (11/10/2026).
$marca = 'fim-do-pedido-' + [guid]::NewGuid().ToString('N')
$Tarefa = $Tarefa.TrimEnd() + "`n`n<!-- $marca -->`n"
# Folga para criar, conferir e, se preciso, desativar antes do disparo.
$quandoRoda = [datetimeoffset]::UtcNow.AddMinutes([Math]::Ceiling($PrazoSegundos / 60) + 2)
$quandoRoda = $quandoRoda.AddSeconds(-$quandoRoda.Second)
$nomeRotina = ('nuvem-' + [string]$aloc.projeto + '-' + ($Titulo -replace '[^A-Za-z0-9._-]', '-') + '-' + (Get-Date).ToString('yyyyMMdd-HHmm', $inv))
$corpo = [ordered]@{
    name = $nomeRotina
    cron_expression = ''
    run_once_at = $quandoRoda.ToString('yyyy-MM-ddTHH:mm:ssZ', $inv)
    enabled = $true
    job_config = @{
        ccr = @{
            environment_id = [string]$cfg.ambiente
            events = @(@{
                data = @{
                    message = @{ content = $Tarefa; role = 'user' }
                    parent_tool_use_id = $null
                    session_id = ''
                    type = 'user'
                    uuid = [guid]::NewGuid().ToString()
                }
            })
            session_context = @{
                allowed_tools = @($Ferramentas)
                model = $modelos[$Modelo]
                sources = @(@{ git_repository = @{ url = [string]$aloc.repositorio } })
            }
        }
    }
}

Write-Host ''
Write-Host ("  Nuvem {0}: credito de sessao na nuvem da conta {1}" -f $ladoAloc, [string]$cfg.conta) -ForegroundColor Cyan
Write-Host ("    projeto: {0} ({1})   repositorio: {2}" -f [string]$aloc.projeto, $Titulo, [string]$aloc.repositorio) -ForegroundColor DarkGray
Write-Host ("    modelo : {0}   teto: US$ {1}   comprometido: US$ {2} de US$ {3}   saldo estimado: US$ {4}" -f $modelos[$Modelo],
    $Teto.ToString('0.00', $inv), $comprometido.ToString('0.00', $inv), ([double]$aloc.teto).ToString('0.00', $inv),
    $s.Estimado.ToString('0.00', $inv)) -ForegroundColor DarkGray
Write-Host ("    roda   : {0} (execucao unica)   ferramentas: {1}" -f $quandoRoda.ToLocalTime().ToString('dd/MM HH:mm', $inv), ($Ferramentas -join ',')) -ForegroundColor DarkGray

if (-not $Execute) {
    Write-Host ''
    Write-Host '  Dry-run: nada foi criado. Repita com -Execute para lancar a sessao.' -ForegroundColor Yellow
    Write-Host ''
    return
}
if (-not $PSCmdlet.ShouldProcess("$nomeRotina em $([string]$aloc.repositorio)", 'Criar sessao na nuvem')) { return }

$trabalho = Join-Path ([IO.Path]::GetTempPath()) ('nuvem-credito-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $trabalho
$registro = [ordered]@{
    quando = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss', $inv)
    lado = $ladoAloc
    projeto = [string]$aloc.projeto
    pasta = $Pasta
    titulo = $Titulo
    modelo = $modelos[$Modelo]
    teto = $Teto
    rotina = $null
    roda = $quandoRoda.ToString('yyyy-MM-ddTHH:mm:ssZ', $inv)
    nota = $null
}
try {
    $corpo | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $trabalho 'corpo.json') -Encoding UTF8
    $pedido = "Carregue a ferramenta RemoteTrigger (ToolSearch 'select:RemoteTrigger'). " +
        "1) Leia o arquivo corpo.json desta pasta e chame RemoteTrigger action=create com o conteudo EXATO dele como body, " +
        "passado como objeto JSON (nao como texto). Nao altere nada no conteudo. " +
        "2) Chame action=get com o id criado e procure, no texto de job_config.ccr.events[0].data.message.content, " +
        "a marca '$marca'. " +
        "3) Se a marca NAO estiver la, chame action=update com o mesmo id e body {""enabled"": false}. " +
        "Nao chame run e nao crie mais nada. Responda numa linha so, sem mais texto: " +
        "'CRIADA <id> MARCA-OK $marca' se a marca estava la; 'TRUNCADA <id> DESATIVADA' se nao estava; " +
        "ou 'ERRO <mensagem exata>' se o create falhou."
    $r = Invoke-ClaudeConta -Estado ([string]$cfg.estado) -PastaTrabalho $trabalho -Pedido $pedido
    $resultado = ''
    if (-not $r.Estourou) {
        try { $resultado = [string](($r.Texto | ConvertFrom-Json).result) } catch { $resultado = $r.Texto }
    }
    $id = [regex]::Match($resultado, 'trig_[A-Za-z0-9]+').Value
    $conferida = $resultado.Contains("MARCA-OK $marca")
    if ($id -and -not $conferida) {
        # Criou mas nao conferiu a marca: nao conta como lancada, e o dono precisa saber.
        $registro.teto = 0.0
        $registro.rotina = $id
        $registro.nota = 'criada sem conferencia da marca (truncada ou nao lida): ' + ($resultado -replace '\s+', ' ').Trim()
        Add-Registro -Dados $registro
        Write-Host ("  Falhou: a rotina $id foi criada, mas o pedido nao conferiu. Resposta: " + ($resultado -replace '\s+', ' ').Trim()) -ForegroundColor Red
        if ($resultado -notmatch 'DESATIVADA') {
            Write-Host "  Confira em claude.ai/code (conta $([string]$cfg.conta)) e desative $id antes de $($quandoRoda.ToLocalTime().ToString('HH:mm', $inv))." -ForegroundColor Red
        }
        exit 1
    }
    if ($r.Estourou -or -not $id) {
        # Nao criou: registra com teto zero, como o credito de API faz com chamada que nao iniciou.
        $registro.teto = 0.0
        $registro.nota = $(if ($r.Estourou) { "nao criou: sem resposta em $PrazoSegundos s" } else { 'nao criou: ' + ($resultado -replace '\s+', ' ').Trim() })
        Add-Registro -Dados $registro
        Write-Host ('  Falhou: ' + $registro.nota) -ForegroundColor Red
        exit 1
    }
    $registro.rotina = $id
    Add-Registro -Dados $registro
    Write-Host ''
    Write-Host ("  Criada: {0}. Roda em {1}; acompanhe em claude.ai/code (conta {2})." -f $id,
        $quandoRoda.ToLocalTime().ToString('dd/MM HH:mm', $inv), [string]$cfg.conta) -ForegroundColor Green
    Write-Host ''
} finally {
    # Pasta criada acima, sempre dentro da temporaria do usuario.
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $alvo = [IO.Path]::GetFullPath($trabalho)
    if ((Test-DentroDe -Caminho $alvo -Raiz $temp) -and ((Split-Path -Leaf $alvo) -like 'nuvem-credito-*')) {
        Remove-Item -LiteralPath $alvo -Recurse -ErrorAction SilentlyContinue
    }
}
