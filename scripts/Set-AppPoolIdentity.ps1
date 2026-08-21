#Requires -Version 7.0
<#
.SYNOPSIS
    Grava a identidade de dominio de app pools do IIS de forma idempotente, sem
    que a senha passe por linha de comando, arquivo em claro ou log.

.DESCRIPTION
    Pool que roda como conta de dominio guarda a senha no applicationHost.config.
    Quando a senha e' trocada, o pool passa a falhar com o evento 5021 e devolve
    HTTP 503 - e, depois de algumas tentativas, a protecao de falha rapida para
    o pool de vez. O sintoma nao diz o que houve: parece aplicacao quebrada.

    Reconfigurar isso na mao e' o tipo de tarefa que se repete a cada rotacao de
    senha. Este script existe para que repetir custe UM comando.

    Tres cuidados que a versao anterior nao tinha, e que sao a razao deste
    arquivo:

    1. A senha NUNCA vai para a linha de comando. `appcmd set apppool
       /processModel.password:...` deixa a senha visivel para qualquer processo
       da maquina, via Win32_Process.CommandLine, enquanto o comando roda. Aqui
       a escrita e' feita em processo, pela API Microsoft.Web.Administration.
    2. A senha NUNCA e' lida de arquivo em claro. Ela vem de PSCredential -
       digitada, ou vinda do cofre - e a copia em texto e' zerada da memoria
       logo apos o uso.
    3. A senha NUNCA aparece no log. O log registra pool, usuario e resultado.

    Dry-run e' o padrao. Nada e' escrito sem -Execute.

.PARAMETER Pool
    Nomes dos app pools a configurar. Sem valor, configura todos os pools que
    ja' estao com identityType SpecificUser.

.PARAMETER Credencial
    Credencial de dominio do pool. Se omitida, o script pergunta. Nunca passe a
    senha como texto em outro parametro.

.PARAMETER Execute
    Executa de verdade. Sem este switch o script so' mostra o que faria.

.PARAMETER SemBackup
    Pula o backup do applicationHost.config. Use apenas se voce ja' tem um.

.PARAMETER Log
    Caminho do relatorio. Padrao: reports\iis-identidade_<data>.md do repositorio.

.EXAMPLE
    pwsh -NoProfile -File .\scripts\Set-AppPoolIdentity.ps1
    Mostra quais pools rodam como conta de dominio e o que seria alterado.

.EXAMPLE
    pwsh -NoProfile -File .\scripts\Set-AppPoolIdentity.ps1 -Execute
    Pergunta a credencial e regrava a identidade de todos os pools SpecificUser.

.EXAMPLE
    pwsh -NoProfile -File .\scripts\Set-AppPoolIdentity.ps1 -Pool 'Um','Dois' -Execute
    Regrava apenas os dois pools nomeados.

.NOTES
    Precisa de terminal elevado: escreve no applicationHost.config.

    Se o appcmd falhar com 80090016 numa sessao remota, o conjunto de chaves da
    maquina nao esta acessivel para o usuario corrente. Isso acontece em logon
    de rede sem perfil carregado. Rode numa sessao interativa da maquina.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string[]]$Pool,
    [pscredential]$Credencial,
    [switch]$Execute,
    [switch]$SemBackup,
    [string]$Log
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------- pre-requisitos

$inetsrv = Join-Path $env:windir 'System32\inetsrv'
$dll     = Join-Path $inetsrv 'Microsoft.Web.Administration.dll'
$appcmd  = Join-Path $inetsrv 'appcmd.exe'

if (-not (Test-Path -LiteralPath $dll)) {
    throw "IIS nao encontrado nesta maquina (ausente: $dll)."
}

$elevado = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
          ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($Execute -and -not $elevado) {
    throw 'Execucao real exige terminal elevado: o applicationHost.config so aceita escrita de administrador.'
}

Add-Type -Path $dll

if (-not $Log) {
    $raiz = Split-Path -Parent $PSScriptRoot
    $dir  = Join-Path $raiz 'reports'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $Log = Join-Path $dir ("iis-identidade_{0}.md" -f (Get-Date -Format 'yyyy-MM-dd_HHmm'))
}

$linhas = [System.Collections.Generic.List[string]]::new()
function Registrar {
    param([string]$Texto)
    $linhas.Add($Texto)
    Write-Host $Texto
}

Registrar "# Identidade de app pools do IIS"
Registrar ''
Registrar ("- host: ``{0}``" -f $env:COMPUTERNAME)
Registrar ("- quando: {0}" -f (Get-Date -Format 'dd/MM/yyyy HH:mm'))
Registrar ("- modo: {0}" -f $(if ($Execute) { '**EXECUCAO REAL**' } else { 'dry-run (nada sera escrito)' }))
Registrar ''

# ------------------------------------------------------------------ inventario

$gerenciador = [Microsoft.Web.Administration.ServerManager]::new()
try {
    $todos = @($gerenciador.ApplicationPools)

    $alvos = if ($Pool) {
        $faltando = @($Pool | Where-Object { $n = $_; -not ($todos | Where-Object { $_.Name -eq $n }) })
        if ($faltando.Count) { throw ("Pool(s) inexistente(s) nesta maquina: {0}" -f ($faltando -join ', ')) }
        @($todos | Where-Object { $Pool -contains $_.Name })
    }
    else {
        @($todos | Where-Object { $_.ProcessModel.IdentityType -eq 'SpecificUser' })
    }

    if (-not $alvos.Count) {
        Registrar 'Nenhum pool roda como conta de dominio nesta maquina. Nada a fazer.'
        $linhas | Set-Content -LiteralPath $Log -Encoding UTF8
        return
    }

    Registrar ("## {0} pool(s) alvo" -f $alvos.Count)
    Registrar ''
    Registrar '| Pool | Identidade atual | Usuario | Estado |'
    Registrar '|---|---|---|---|'
    foreach ($p in $alvos) {
        Registrar ('| `{0}` | {1} | {2} | {3} |' -f $p.Name, $p.ProcessModel.IdentityType,
            $(if ($p.ProcessModel.UserName) { '`' + $p.ProcessModel.UserName + '`' } else { '-' }), $p.State)
    }
    Registrar ''

    if (-not $Execute) {
        Registrar '> Dry-run. Rode de novo com `-Execute` para gravar a identidade.'
        Registrar '> A senha sera pedida na hora e nao passa por linha de comando nem por arquivo.'
        $linhas | Set-Content -LiteralPath $Log -Encoding UTF8
        Write-Host ''
        Write-Host "Relatorio: $Log" -ForegroundColor DarkGray
        return
    }

    # ------------------------------------------------------------- credencial

    if (-not $Credencial) {
        $sugestao = ($alvos | Where-Object { $_.ProcessModel.UserName } |
                     Select-Object -First 1 -ExpandProperty ProcessModel).UserName
        $Credencial = Get-Credential -UserName $sugestao -Message 'Senha de dominio dos app pools'
    }
    if (-not $Credencial) { throw 'Sem credencial: nada foi alterado.' }

    # ----------------------------------------------------------------- backup

    if (-not $SemBackup) {
        $nomeBackup = 'antes-identidade-{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss')
        $saida = & $appcmd add backup $nomeBackup 2>&1
        $rc = $LASTEXITCODE
        # Decida por codigo de saida, nunca pelo texto: mensagem localizada
        # chega com codificacao trocada e a comparacao nunca casa.
        if ($rc -ne 0) { throw ("Backup do applicationHost.config falhou (rc={0}). Nada foi alterado. Saida: {1}" -f $rc, ($saida -join ' ')) }
        Registrar ("**Backup criado:** ``{0}`` (restaure com ``appcmd restore backup {0}``)" -f $nomeBackup)
        Registrar ''
    }

    # ------------------------------------------------------------- a gravacao

    # A senha vira texto apenas dentro deste bloco, e a copia e' zerada logo
    # depois. Nada de guardar em variavel de escopo maior.
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Credencial.Password)
    try {
        $senha = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        $usuario = $Credencial.UserName

        $aplicados = 0
        foreach ($p in $alvos) {
            if (-not $PSCmdlet.ShouldProcess($p.Name, "gravar identidade de dominio como $usuario")) { continue }
            $p.ProcessModel.IdentityType = [Microsoft.Web.Administration.ProcessModelIdentityType]::SpecificUser
            $p.ProcessModel.UserName = $usuario
            $p.ProcessModel.Password = $senha
            $aplicados++
        }
        if ($aplicados -gt 0) { $gerenciador.CommitChanges() }
        Registrar ("Identidade gravada em **{0}** pool(s) como ``{1}``." -f $aplicados, $usuario)
        Registrar ''
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        if (Get-Variable -Name senha -Scope 0 -ErrorAction SilentlyContinue) { Remove-Variable -Name senha -Force }
    }
}
finally {
    $gerenciador.Dispose()
}

# ------------------------------------------------------------- e a conferencia

# Reabre o gerenciador: o objeto anterior ja' foi confirmado e descartado, e ler
# do disco e' o unico jeito honesto de saber o que ficou gravado.
Start-Sleep -Seconds 2
$conf = [Microsoft.Web.Administration.ServerManager]::new()
try {
    $nomes = @($alvos | Select-Object -ExpandProperty Name)
    foreach ($nome in $nomes) {
        $p = $conf.ApplicationPools[$nome]
        if ($null -eq $p) { continue }
        if ($p.State -eq [Microsoft.Web.Administration.ObjectState]::Stopped) {
            # Protecao de falha rapida derruba o pool depois de N falhas de
            # logon. Reiniciar faz parte de verificar se a senha nova vale.
            try { $p.Start() } catch { }
        }
    }
    Start-Sleep -Seconds 3

    Registrar '## Conferencia (lida do disco depois de gravar)'
    Registrar ''
    Registrar '| Pool | Identidade | Usuario | Senha gravada | Estado |'
    Registrar '|---|---|---|---|---|'
    foreach ($nome in $nomes) {
        $p = $conf.ApplicationPools[$nome]
        if ($null -eq $p) { Registrar ('| `{0}` | (sumiu) | - | - | - |' -f $nome); continue }
        # Presenca, nunca o valor: o log e' arquivo, e arquivo vaza.
        $temSenha = -not [string]::IsNullOrEmpty($p.ProcessModel.Password)
        Registrar ('| `{0}` | {1} | `{2}` | {3} | {4} |' -f $p.Name, $p.ProcessModel.IdentityType,
            $p.ProcessModel.UserName, $(if ($temSenha) { 'sim' } else { '**NAO**' }), $p.State)
    }
    Registrar ''

    # O evento 5021 e' o que realmente diz se a senha vale. Pool "Started" nao
    # prova nada enquanto nao houver um w3wp de pe: sem requisicao, o IIS nao
    # tenta o logon, e o pool parece saudavel estando quebrado.
    $desde = (Get-Date).AddMinutes(-5)
    $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 5021; StartTime = $desde } -ErrorAction SilentlyContinue)
    if ($ev.Count) {
        Registrar ("> **Atencao:** {0} evento(s) 5021 nos ultimos 5 minutos - a senha continua sendo recusada." -f $ev.Count)
    }
    else {
        Registrar '> Nenhum evento 5021 recente. Faca uma requisicao real a uma aplicacao de cada pool:'
        Registrar '> sem requisicao o IIS nao tenta o logon, e o pool parece saudavel estando quebrado.'
    }
}
finally {
    $conf.Dispose()
}

$linhas | Set-Content -LiteralPath $Log -Encoding UTF8
Write-Host ''
Write-Host "Relatorio: $Log" -ForegroundColor DarkGray
