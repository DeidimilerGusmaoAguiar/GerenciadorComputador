<#
.SYNOPSIS
Valida o runner de trabalho pesado sem carga relevante (poucos segundos).

.DESCRIPTION
Casos: sintaxe, propagacao do codigo de saida, serializacao por vaga,
desistencia por espera maxima, teto de memoria e -WhatIf. Usa um prefixo de
mutex proprio, entao nao disputa vaga com trabalho real. Os arquivos temporarios
ficam numa pasta propria sob o temporario do usuario e so ela e removida.
Somente o proprio teste cria processos; nenhum processo e encerrado a forca.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$runner = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\scripts\Invoke-TrabalhoPesado.ps1'))
$pwshExe = (Get-Process -Id $PID).Path
$work = Join-Path ([IO.Path]::GetTempPath()) ('gc-trabalho-pesado-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $work
$vaga = 'Local\GC-Teste-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
$results = [Collections.Generic.List[object]]::new()

function Add-Result {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    $script:results.Add([pscustomobject]@{ Name = $Name; Ok = $Ok })
    $tag = if ($Ok) { 'PASS' } else { 'FAIL' }
    $suffix = if ($Detail) { " ($Detail)" } else { '' }
    Write-Host "$tag  $Name$suffix"
}

function Invoke-Runner {
    param([string[]]$RunnerArgs)
    $out = & $pwshExe -NoProfile -File $runner @RunnerArgs 2>&1 | Out-String
    [pscustomobject]@{ Code = $LASTEXITCODE; Output = $out }
}

try {
    # 1. Sintaxe
    $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile($runner, [ref]$null, [ref]$errors)
    Add-Result 'sintaxe do runner' ($errors.Count -eq 0) "$($errors.Count) erro(s)"

    # 2. Codigo de saida propagado
    $r = Invoke-Runner @('-NomeVaga', $vaga, '--', $pwshExe, '-NoProfile', '-c', 'exit 7')
    Add-Result 'codigo de saida do filho propagado (7)' ($r.Code -eq 7) "recebido $($r.Code)"
    Add-Result 'resumo impresso' ($r.Output -match 'resumo: duracao .*pico de memoria do job') ''

    # 3. -WhatIf nao roda nada
    $marca = Join-Path $work 'whatif.txt'
    $r = Invoke-Runner @('-NomeVaga', $vaga, '-WhatIf', '--', $pwshExe, '-NoProfile', '-c', "Set-Content -LiteralPath '$marca' -Value x")
    Add-Result '-WhatIf nao executa o comando' ($r.Code -eq 0 -and -not (Test-Path -LiteralPath $marca) -and $r.Output -match 'What if') "codigo $($r.Code)"

    # 4. Serializacao com uma vaga
    $filho = Join-Path $work 'filho.ps1'
    $log = Join-Path $work 'intervalos.log'
    Set-Content -LiteralPath $filho -Value @'
param($Tag, $Log)
Add-Content -LiteralPath $Log -Value "$Tag start $([DateTime]::UtcNow.Ticks)"
Start-Sleep -Seconds 3
Add-Content -LiteralPath $Log -Value "$Tag end $([DateTime]::UtcNow.Ticks)"
'@
    $procs = foreach ($tag in 'A', 'B') {
        $a = @('-NoProfile', '-File', "`"$runner`"", '-NomeVaga', $vaga, '-Vagas', '1', '--', "`"$pwshExe`"", '-NoProfile', '-File', "`"$filho`"", $tag, "`"$log`"")
        Start-Process -FilePath $pwshExe -ArgumentList $a -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput (Join-Path $work "saida-$tag.txt")
    }
    foreach ($p in $procs) { $null = $p.WaitForExit(60000) }
    $ok = $true; $detail = ''
    $linhas = if (Test-Path -LiteralPath $log) { @(Get-Content -LiteralPath $log) } else { @() }
    $t = @{}
    foreach ($l in $linhas) { $f = $l -split ' '; $t["$($f[0])$($f[1])"] = [int64]$f[2] }
    if ($t.Count -ne 4 -or ($procs | Where-Object { $_.ExitCode -ne 0 })) {
        $ok = $false; $detail = 'execucao incompleta'
    } else {
        $ok = ($t['Aend'] -le $t['Bstart']) -or ($t['Bend'] -le $t['Astart'])
        $detail = 'intervalos ' + $(if ($ok) { 'disjuntos' } else { 'SOBREPOSTOS' })
    }
    Add-Result 'duas invocacoes com -Vagas 1 nao se sobrepoem' $ok $detail

    # 5. Espera maxima: vaga ocupada por este processo, runner desiste com 124
    $m = [Threading.Mutex]::new($false, "$vaga-1")
    try {
        $null = $m.WaitOne(0)
        $r = Invoke-Runner @('-NomeVaga', $vaga, '-EsperaMaxMinutos', '0', '--', $pwshExe, '-NoProfile', '-c', 'exit 0')
        Add-Result 'vaga ocupada e espera 0: sai com 124' ($r.Code -eq 124) "recebido $($r.Code)"
    } finally {
        $m.ReleaseMutex(); $m.Dispose()
    }

    # 6. Teto de memoria: alocacao nativa acima de 0,6 GB e barrada e o resumo avisa
    $aloca = '$n=0; try { 1..60 | % { $p=[Runtime.InteropServices.Marshal]::AllocHGlobal(33554432); [Runtime.InteropServices.Marshal]::WriteByte($p,1); $n++ }; "ALOCOU-"+"TUDO" } catch { "BARRADO-"+"APOS-$n" }'
    $r = Invoke-Runner @('-NomeVaga', $vaga, '-MemoriaGB', '0.6', '--', $pwshExe, '-NoProfile', '-c', $aloca)
    Add-Result 'alocacao acima do teto e barrada' ($r.Output -match 'BARRADO-APOS-' -and $r.Output -notmatch 'ALOCOU-TUDO') ''
    Add-Result 'resumo diz que bateu no teto de memoria' ($r.Output -match 'teto de memoria ATINGIDO') ''
}
finally {
    $base = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $alvo = [IO.Path]::GetFullPath($work)
    if ($alvo.StartsWith($base, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $alvo) -like 'gc-trabalho-pesado-*' -and
        -not ((Get-Item -LiteralPath $alvo).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        [IO.Directory]::Delete($alvo, $true)
    }
}

$falhas = @($results | Where-Object { -not $_.Ok })
Write-Host ''
Write-Host ("{0} caso(s), {1} falha(s)." -f $results.Count, $falhas.Count)
if ($falhas.Count -gt 0) { exit 1 }
exit 0
