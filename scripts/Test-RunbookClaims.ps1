#Requires -Version 7.0
<#
.SYNOPSIS
    Confere, contra a maquina atual, as afirmacoes factuais de um runbook de
    migracao. Somente leitura.

.DESCRIPTION
    Runbook de migracao envelhece. Um deles foi reaproveitado dez dias depois,
    numa troca seguinte, e SEIS afirmacoes dele ja eram falsas: mandava instalar
    uma versao de IDE que nao estava mais em uso, esperava uma distro de WSL que
    nao existia na maquina, mandava restaurar um volume de container ja removido,
    e errava a contagem de imagens locais, de credenciais de acesso remoto e de
    extensoes do editor. Nenhuma quebrou nada sozinha - mas cada uma custou
    tempo, e uma delas (a do servidor web local) so foi descoberta porque o dono
    desconfiou.

    Este script nao decide nada. Ele imprime, lado a lado, o que o runbook AFIRMA
    e o que a maquina RESPONDE, para que a divergencia apareca antes de virar
    trabalho perdido.

    Use ANTES de comecar a executar qualquer runbook de migracao.

.PARAMETER Esperado
    JSON com as afirmacoes do runbook. Sem ele, o script so inventaria a maquina
    (util para GERAR o arquivo na primeira vez).

.PARAMETER Json
    Emite o resultado como JSON em vez de tabela.

.EXAMPLE
    pwsh -NoProfile -File .\scripts\Test-RunbookClaims.ps1
    Inventaria a maquina. Use para criar a linha de base.

.EXAMPLE
    pwsh -NoProfile -File .\scripts\Test-RunbookClaims.ps1 -Esperado .\local\migracao\afirmacoes-runbook.json
    Compara maquina x runbook e lista o que divergiu.
#>
[CmdletBinding()]
param(
    [string]$Esperado,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

function Get-Fato {
    <#
        Cada fato e' uma pergunta objetiva com resposta verificavel. O bloco
        NUNCA escreve; se falhar, o fato vira '(indisponivel)' em vez de
        derrubar a checagem inteira - maquina de destino costuma estar pela
        metade, e abortar no primeiro buraco esconde os outros.
    #>
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Pergunta,
        [Parameter(Mandatory)][scriptblock]$Medir
    )
    $valor = '(indisponivel)'
    try {
        $r = & $Medir
        if ($null -ne $r -and "$r".Trim()) { $valor = ($r -join ', ').Trim() }
        elseif ($null -ne $r) { $valor = "$r" }
    }
    catch { $valor = '(indisponivel)' }
    [pscustomobject]@{ Id = $Id; Pergunta = $Pergunta; Maquina = $valor }
}

$fatos = @(
    Get-Fato 'wsl.distros' 'Quais distros do WSL existem?' {
        $s = (& wsl.exe --list --quiet 2>&1 | Out-String) -replace "`0", ''
        $d = @($s -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($d.Count) { $d -join ', ' } else { '(nenhuma)' }
    }

    Get-Fato 'docker.volumes' 'Quais volumes o Docker tem?' {
        @(& docker.exe volume ls --format '{{.Name}}' 2>&1 |
            Where-Object { $_ -and $_ -notmatch '^[0-9a-f]{64}$' -and $_ -notmatch 'error|Cannot' })
    }

    Get-Fato 'docker.imagens.suspeitas' 'Quais imagens podem ser build local (nao viajam por pull)?' {
        # NAO use "RepoDigests vazio": build local TAMBEM ganha digest local.
        # Foi assim que a checagem mentiu em 20/08/2026, dizendo que nao havia
        # imagem local quando havia uma, construida no proprio repositorio.
        # Criterio honesto: repositorio SEM host de registro (sem ponto) e SEM
        # namespace (sem barra) e' candidato - inclui oficiais como 'redis',
        # entao o resultado pede confirmacao, nao e' veredito.
        $c = @(& docker.exe image ls --format '{{.Repository}}' 2>&1 |
               Where-Object { $_ -and $_ -notmatch '<none>|error' } |
               Where-Object { $_ -notmatch '[./]' } | Sort-Object -Unique)
        if ($c) { ($c -join ', ') + '  (conferir quais tem Dockerfile no repo: essas precisam de build, nao de pull)' }
        else { '(nenhuma sem namespace)' }
    }

    Get-Fato 'vs.edicoes' 'Quais Visual Studio estao instalados?' {
        $vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
        if (-not (Test-Path -LiteralPath $vswhere)) { return '(vswhere ausente)' }
        @(& $vswhere -products * -format value -property displayName 2>&1 | Where-Object { $_ })
    }

    Get-Fato 'vscode.extensoes' 'Quantas extensoes o VS Code tem?' {
        @(& code --list-extensions 2>&1 | Where-Object { $_ -and $_ -notmatch '^\s*$' }).Count
    }

    Get-Fato 'rdp.credenciais' 'Quantas credenciais TERMSRV existem?' {
        $blocos = (cmdkey /list 2>&1 | Out-String) -split '(?=Destino:|Target:)'
        @($blocos | Where-Object { $_ -match 'TERMSRV' }).Count
    }

    Get-Fato 'iis.pools' 'Quantos app pools o IIS tem?' {
        $cfg = Join-Path $env:windir 'System32\inetsrv\config\applicationHost.config'
        if (-not (Test-Path -LiteralPath $cfg)) { return '(IIS ausente)' }
        [xml]$x = Get-Content -LiteralPath $cfg -Raw
        @($x.configuration.'system.applicationHost'.applicationPools.add).Count
    }

    Get-Fato 'iisexpress.sites' 'Quantos sites REAIS o IIS Express tem?' {
        # A pegadinha de 19/08: o arquivo existe, mas so com o WebSite1 de
        # fabrica. Existir nao e' o mesmo que estar em uso.
        $f = Join-Path $HOME 'Documents\IISExpress\config\applicationhost.config'
        if (-not (Test-Path -LiteralPath $f)) { return '(sem config)' }
        [xml]$x = Get-Content -LiteralPath $f -Raw
        $sites = @($x.configuration.'system.applicationHost'.sites.site)
        $reais = @($sites | Where-Object { $_.name -ne 'WebSite1' })
        '{0} site(s), {1} alem do WebSite1 padrao; config de {2:yyyy-MM-dd}' -f `
            $sites.Count, $reais.Count, (Get-Item -LiteralPath $f).LastWriteTime
    }

    Get-Fato 'dotnet.sdks' 'Quais SDKs .NET estao instalados?' {
        @(& dotnet --list-sdks 2>&1 | ForEach-Object { ($_ -split ' ')[0] } | Where-Object { $_ -match '^\d' })
    }

    Get-Fato 'node.versoes' 'Quais versoes de Node o nvm tem?' {
        @((& nvm list 2>&1) -split "`r?`n" |
            ForEach-Object { ($_ -replace '[*]', '').Trim() } |
            Where-Object { $_ -match '^\d+\.\d+\.\d+' } |
            ForEach-Object { ($_ -split ' ')[0] })
    }

    Get-Fato 'npm.globais' 'Quantos pacotes npm globais existem?' {
        $g = & npm ls -g --depth=0 --json 2>$null | ConvertFrom-Json
        if ($g.PSObject.Properties.Name -contains 'dependencies') {
            @($g.dependencies.PSObject.Properties).Count
        } else { 0 }
    }

    Get-Fato 'localdb' 'Qual LocalDB responde?' {
        $sl = Get-ChildItem 'C:\Program Files\Microsoft SQL Server' -Directory -EA SilentlyContinue |
              ForEach-Object { Join-Path $_.FullName 'Tools\Binn\SqlLocalDB.exe' } |
              Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if (-not $sl) { return '(nao instalado)' }
        @(& $sl versions 2>&1 | Where-Object { $_ })
    }

    Get-Fato 'gpg.chaves' 'Existem chaves secretas GPG?' {
        $gpg = Get-Command gpg -EA SilentlyContinue
        if (-not $gpg) { return '(gpg ausente)' }
        $o = & $gpg.Source --list-secret-keys 2>&1 | Where-Object { $_ -match '^sec' }
        if ($o) { "$(@($o).Count) chave(s)" } else { 'nenhuma (cofres simetricos dispensam chaveiro)' }
    }

    Get-Fato 'vault.cofres' 'Quantos cofres GPG existem?' {
        $v = Join-Path $HOME '.vault'
        if (-not (Test-Path -LiteralPath $v)) { return '(sem ~/.vault)' }
        @(Get-ChildItem -LiteralPath $v -Filter '*.gpg' -EA SilentlyContinue).Name
    }

    Get-Fato 'favoritos' 'Quais navegadores tem favoritos EM ARQUIVO?' {
        # Outra pegadinha: favorito sincronizado na nuvem nao deixa arquivo.
        $r = foreach ($n in @(
                @{ Nome = 'Chrome'; P = 'Google\Chrome\User Data\Default\Bookmarks' }
                @{ Nome = 'Edge'; P = 'Microsoft\Edge\User Data\Default\Bookmarks' })) {
            $f = Join-Path $env:LOCALAPPDATA $n.P
            if (Test-Path -LiteralPath $f) { '{0} ({1:N0} bytes)' -f $n.Nome, (Get-Item -LiteralPath $f).Length }
        }
        if ($r) { $r } else { '(nenhum: favoritos so na nuvem)' }
    }

    Get-Fato 'nuget.credencial' 'O NuGet.Config do usuario tem credencial de feed?' {
        $f = Join-Path $env:APPDATA 'NuGet\NuGet.Config'
        if (-not (Test-Path -LiteralPath $f)) { return '(sem NuGet.Config)' }
        $t = Get-Content -LiteralPath $f -Raw
        if ($t -match 'ClearTextPassword|<add key="Password"') { 'SIM - precisa viajar, e sensivel' } else { 'nao' }
    }
)

# ------------------------------------------------------------ comparacao
$saida = $fatos
if ($Esperado) {
    if (-not (Test-Path -LiteralPath $Esperado)) { throw "Arquivo de afirmacoes nao encontrado: $Esperado" }
    $claims = Get-Content -LiteralPath $Esperado -Raw | ConvertFrom-Json
    $saida = foreach ($f in $fatos) {
        $c = $claims.PSObject.Properties | Where-Object { $_.Name -eq $f.Id } | Select-Object -First 1
        $diz = if ($c) { "$($c.Value)" } else { '(runbook nao afirma)' }
        $status = if (-not $c) { '-' }
                  elseif ("$($f.Maquina)".Trim() -eq $diz.Trim()) { 'CONFERE' }
                  else { 'DIVERGE' }
        $f | Add-Member -NotePropertyName Runbook -NotePropertyValue $diz -PassThru |
             Add-Member -NotePropertyName Status -NotePropertyValue $status -PassThru
    }
}

if ($Json) { $saida | ConvertTo-Json -Depth 4; return }

Write-Host ''
Write-Host 'AFIRMACOES DO RUNBOOK x MAQUINA ATUAL' -ForegroundColor Cyan
Write-Host ("  host: {0}   em {1:dd/MM/yyyy HH:mm}" -f $env:COMPUTERNAME, (Get-Date)) -ForegroundColor DarkGray
Write-Host ''
foreach ($f in $saida) {
    $temStatus = $f.PSObject.Properties.Name -contains 'Status'
    $cor = if (-not $temStatus) { 'Gray' }
           elseif ($f.Status -eq 'DIVERGE') { 'Red' }
           elseif ($f.Status -eq 'CONFERE') { 'Green' }
           else { 'DarkGray' }
    Write-Host ("  {0,-22} {1}" -f $f.Id, $f.Pergunta) -ForegroundColor DarkGray
    Write-Host ("  {0,-22} maquina : {1}" -f '', $f.Maquina) -ForegroundColor $cor
    if ($temStatus -and $f.Status -ne '-') {
        Write-Host ("  {0,-22} runbook : {1}   [{2}]" -f '', $f.Runbook, $f.Status) -ForegroundColor $cor
    }
    Write-Host ''
}

if ($saida[0].PSObject.Properties.Name -contains 'Status') {
    $div = @($saida | Where-Object { $_.Status -eq 'DIVERGE' })
    if ($div.Count) {
        Write-Host ("{0} AFIRMACAO(OES) DO RUNBOOK ESTAO DESATUALIZADAS:" -f $div.Count) -ForegroundColor Red
        $div | ForEach-Object { Write-Host ("  - {0}" -f $_.Id) -ForegroundColor Red }
        Write-Host ''
        Write-Host 'Corrija o runbook ANTES de executa-lo. Repetir afirmacao velha' -ForegroundColor Yellow
        Write-Host 'nao quebra nada de imediato - so faz voce trabalhar por engano.' -ForegroundColor Yellow
    }
    else { Write-Host 'Nenhuma divergencia: o runbook confere com esta maquina.' -ForegroundColor Green }
}
else {
    Write-Host 'Inventario apenas (sem -Esperado). Para comparar, gere o JSON de' -ForegroundColor DarkGray
    Write-Host 'afirmacoes com os campos Id acima e passe em -Esperado.' -ForegroundColor DarkGray
}
