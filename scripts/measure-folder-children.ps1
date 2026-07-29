[CmdletBinding()]
param(
    [string[]]$Paths = @(
        'C:\Users',
        'C:\Repos',
        'C:\Program Files',
        'C:\$Recycle.Bin',
        'C:\Windows',
        'C:\Program Files (x86)',
        'C:\ProgramData',
        'C:\dev-cache',
        'C:\inetpub'
    ),
    [int]$TimeoutSeconds = 420,
    [int]$ThrottleLimit = 6,
    [string]$Stamp = (Get-Date -Format 'yyyy-MM-dd_HHmm'),
    [string]$OutDir = (Join-Path $PSScriptRoot '..\reports')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir | Out-Null
}

$validPaths = @(
    $Paths |
        Where-Object { Test-Path -LiteralPath $_ -PathType Container } |
        ForEach-Object { [System.IO.Path]::GetFullPath($_).TrimEnd('\') }
)

$watch = [System.Diagnostics.Stopwatch]::StartNew()
$scans = @(
    $validPaths | ForEach-Object -Parallel {
        $sourceRoot = $_
        $itemWatch = [System.Diagnostics.Stopwatch]::StartNew()
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = "$env:SystemRoot\System32\diskusage.exe"
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $null = $psi.ArgumentList.Add('/c')
        $null = $psi.ArgumentList.Add('/d:1')
        $null = $psi.ArgumentList.Add('/x')
        $null = $psi.ArgumentList.Add('/g:0x07')
        $null = $psi.ArgumentList.Add($sourceRoot)

        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $psi
        $complete = $false
        $output = ''
        $errorText = ''

        try {
            $null = $process.Start()
            $stdoutTask = $process.StandardOutput.ReadToEndAsync()
            $stderrTask = $process.StandardError.ReadToEndAsync()
            $complete = $process.WaitForExit($using:TimeoutSeconds * 1000)
            if (-not $complete) {
                $process.Kill($true)
                $process.WaitForExit()
                $errorText = "Timeout de $using:TimeoutSeconds segundos."
            }
            $output = $stdoutTask.GetAwaiter().GetResult()
            $stderr = $stderrTask.GetAwaiter().GetResult()
            if ($stderr) {
                $errorText = (($errorText, $stderr.Trim()) | Where-Object { $_ }) -join ' '
            }
        } catch {
            $errorText = $_.Exception.Message
            if (-not $process.HasExited) {
                $process.Kill($true)
            }
        } finally {
            $process.Dispose()
            $itemWatch.Stop()
        }

        $rows = @(
            foreach ($line in ($output -split '\r?\n')) {
                if ($line -match '^(\d+),(\d+),(\d+),(.+)$') {
                    [pscustomobject]@{
                        Path = $Matches[4]
                        SizeOnDiskBytes = [int64]$Matches[1]
                        FileSizeBytes = [int64]$Matches[2]
                        SizePerDirBytes = [int64]$Matches[3]
                        SizeOnDiskGB = [math]::Round([int64]$Matches[1] / 1GB, 3)
                    }
                }
            }
        )

        [pscustomobject]@{
            SourceRoot = $sourceRoot
            DurationSeconds = [math]::Round($itemWatch.Elapsed.TotalSeconds, 1)
            Complete = $complete
            Error = $errorText
            Rows = $rows
        }
    } -ThrottleLimit $ThrottleLimit
)
$watch.Stop()

$allRows = @(
    foreach ($scan in $scans) {
        foreach ($row in $scan.Rows) {
            [pscustomobject]@{
                SourceRoot = $scan.SourceRoot
                Path = $row.Path
                SizeOnDiskBytes = $row.SizeOnDiskBytes
                FileSizeBytes = $row.FileSizeBytes
                SizePerDirBytes = $row.SizePerDirBytes
                SizeOnDiskGB = $row.SizeOnDiskGB
            }
        }
    }
)

$result = [ordered]@{
    scannedAt = (Get-Date).ToString('o')
    durationSeconds = [math]::Round($watch.Elapsed.TotalSeconds, 1)
    timeoutSecondsPerRoot = $TimeoutSeconds
    scans = $scans
    topRows = @($allRows | Sort-Object SizeOnDiskBytes -Descending | Select-Object -First 150)
}

$outputPath = Join-Path $OutDir "folder-children_$Stamp.json"
$result | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $outputPath -Encoding utf8
Write-Host "Medicao salva em $outputPath"
$scans | Select-Object SourceRoot, DurationSeconds, Complete, Error | Format-Table -AutoSize
$result.topRows | Select-Object -First 40 Path, SizeOnDiskGB | Format-Table -AutoSize
Write-Output $outputPath
