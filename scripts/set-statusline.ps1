<#
.SYNOPSIS
Mostra ou grava a barra de status do Claude Code em cada diretorio de estado
do mapa de perfis.

.DESCRIPTION
A barra e scripts\statusline.py: plano, nome da sessao, modelo, pasta,
contexto e as janelas de cota de 5 h e 7 dias. O plano e a cor de cada
diretorio vem do mapa (label e color de cada perfil claude), entao a mesma
barra diz em qual conta a sessao esta.

Grava so a chave statusLine do settings.json de cada perfil claude do mapa.
O resto do arquivo fica como estava. Repositorio que define statusLine no
proprio projeto continua com a dele, porque a configuracao do projeto vence a
do usuario.

Sem -Execute, mostra o comando atual e o novo de cada diretorio, sem mudar
nada. Com -Execute, guarda o settings.json anterior ao lado, como
settings.json.antes-statusline-<data>, e grava o novo por troca atomica. A
sessao aberta le a mudanca sozinha.

Reversao: copiar o settings.json.antes-statusline-<data> de volta.

.EXAMPLE
pwsh -NoProfile -File .\scripts\set-statusline.ps1

.EXAMPLE
pwsh -NoProfile -File .\scripts\set-statusline.ps1 -Execute
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [switch]$Execute,

    [AllowEmptyString()]
    [string]$MapPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $MapPath) { $MapPath = Join-Path $repoRoot 'local\perfis-cli.json' }
$MapPath = [IO.Path]::GetFullPath($MapPath)
if (-not (Test-Path -LiteralPath $MapPath -PathType Leaf)) {
    throw "Mapa de perfis nao encontrado: $MapPath (modelo em scripts\perfis-cli.example.json)"
}

$barra = Join-Path $PSScriptRoot 'statusline.py'
if (-not (Test-Path -LiteralPath $barra -PathType Leaf)) { throw "Barra nao encontrada: $barra" }
$python = Get-Command python -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $python) { throw 'python nao esta no PATH: a barra precisa dele.' }

# A barra roda pelo shell da CLI. Barra normal no caminho evita depender de
# como esse shell trata a barra invertida.
$barraCmd = $barra.Replace('\', '/')
& $python.Source -I $barra --teste | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'O autoteste da barra falhou: nada foi gravado.' }

$mapa = Get-Content -LiteralPath $MapPath -Raw -Encoding utf8 | ConvertFrom-Json
$perfis = @($mapa.profiles | Where-Object { $_.cli -eq 'claude' })
if ($perfis.Count -eq 0) { throw "O mapa nao tem perfil claude: $MapPath" }

function ConvertTo-Argumento {
    param([Parameter(Mandatory)][string]$Valor)
    if ($Valor -notmatch '^[\w .-]+$') { throw "Valor fora do formato para a linha de comando: '$Valor'" }
    return '"' + $Valor + '"'
}

$stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$gravados = 0
foreach ($perfil in $perfis) {
    $home_ = [IO.Path]::GetFullPath([string]$perfil.home)
    $arquivo = Join-Path $home_ 'settings.json'
    $rotulo = [string]$perfil.label
    $cor = if ($perfil.PSObject.Properties['color']) { ([string]$perfil.color).ToLowerInvariant() } else { '' }
    if (-not (Test-Path -LiteralPath $home_ -PathType Container)) {
        Write-Output "[$rotulo] $home_ nao existe: pulado"
        continue
    }

    $comando = 'python -I "{0}" --plano {1}' -f $barraCmd, (ConvertTo-Argumento $rotulo)
    if ($cor) { $comando += ' --cor ' + (ConvertTo-Argumento $cor) }
    $novo = [ordered]@{ type = 'command'; command = $comando; padding = 0 }

    if (Test-Path -LiteralPath $arquivo -PathType Leaf) {
        $texto = Get-Content -LiteralPath $arquivo -Raw -Encoding utf8
        $config = if ([string]::IsNullOrWhiteSpace($texto)) { [pscustomobject]@{} } else { $texto | ConvertFrom-Json }
    } else {
        $texto = $null
        $config = [pscustomobject]@{}
    }
    $atual = if ($config.PSObject.Properties['statusLine']) { $config.statusLine } else { $null }
    $atualCmd = if ($atual -and $atual.PSObject.Properties['command']) { [string]$atual.command } else { '(nenhuma)' }

    if ($atualCmd -eq $comando) {
        Write-Output "[$rotulo] ja esta com a barra nova"
        continue
    }
    Write-Output "[$rotulo] $arquivo"
    Write-Output "    atual: $atualCmd"
    Write-Output "    nova:  $comando"
    if (-not $Execute) { continue }
    if (-not $PSCmdlet.ShouldProcess($arquivo, 'gravar statusLine')) { continue }

    if ($null -ne $texto) {
        $copia = "$arquivo.antes-statusline-$stamp"
        Copy-Item -LiteralPath $arquivo -Destination $copia
        Write-Output "    anterior em $copia"
    }
    $config | Add-Member -NotePropertyName statusLine -NotePropertyValue ([pscustomobject]$novo) -Force
    $json = ($config | ConvertTo-Json -Depth 32) -replace "`r`n", "`n"
    $temporario = "$arquivo.gravando-$stamp"
    [IO.File]::WriteAllText($temporario, $json + "`n", [Text.UTF8Encoding]::new($false))
    $relido = Get-Content -LiteralPath $temporario -Raw -Encoding utf8 | ConvertFrom-Json
    if ([string]$relido.statusLine.command -ne $comando) {
        Remove-Item -LiteralPath $temporario
        throw "[$rotulo] releitura nao confere: nada foi trocado em $arquivo"
    }
    Move-Item -LiteralPath $temporario -Destination $arquivo -Force
    $gravados++
    Write-Output '    gravado'
}

if (-not $Execute) {
    Write-Output ''
    Write-Output 'Dry-run: nada foi gravado. Rode com -Execute para aplicar.'
} else {
    Write-Output "Gravados: $gravados"
}
