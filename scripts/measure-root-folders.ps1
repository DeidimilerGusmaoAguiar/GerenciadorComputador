[CmdletBinding()]
param(
    [string]$Drive = 'C:',
    [int]$TimeoutSeconds = 360,
    [int]$ThrottleLimit = 6,
    [string]$Stamp = (Get-Date -Format 'yyyy-MM-dd_HHmm'),
    [string]$OutDir = (Join-Path $PSScriptRoot '..\reports')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir | Out-Null
}

$rootPath = "$($Drive.TrimEnd('\'))\"
$paths = @(
    Get-ChildItem -LiteralPath $rootPath -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { -not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) } |
        Select-Object -ExpandProperty FullName
)

$watch = [System.Diagnostics.Stopwatch]::StartNew()
$rows = @(
    $paths | ForEach-Object -Parallel {
        $path = $_
        $itemWatch = [System.Diagnostics.Stopwatch]::StartNew()
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = "$env:SystemRoot\System32\diskusage.exe"
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $null = $psi.ArgumentList.Add('/c')
        $null = $psi.ArgumentList.Add('/d:0')
        $null = $psi.ArgumentList.Add('/x')
        $null = $psi.ArgumentList.Add('/g:0x07')
        $null = $psi.ArgumentList.Add($path)

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

        $dataLine = @(
            $output -split '\r?\n' |
                Where-Object { $_ -match '^\d+,\d+,\d+,' }
        ) | Select-Object -First 1

        if ($dataLine -match '^(\d+),(\d+),(\d+),(.+)$') {
            [pscustomobject]@{
                Path = $path
                SizeOnDiskBytes = [int64]$Matches[1]
                FileSizeBytes = [int64]$Matches[2]
                SizePerDirBytes = [int64]$Matches[3]
                SizeOnDiskGB = [math]::Round([int64]$Matches[1] / 1GB, 3)
                DurationSeconds = [math]::Round($itemWatch.Elapsed.TotalSeconds, 1)
                Complete = $complete
                Error = if ($complete) { $errorText } else { $errorText }
            }
        } else {
            [pscustomobject]@{
                Path = $path
                SizeOnDiskBytes = $null
                FileSizeBytes = $null
                SizePerDirBytes = $null
                SizeOnDiskGB = $null
                DurationSeconds = [math]::Round($itemWatch.Elapsed.TotalSeconds, 1)
                Complete = $false
                Error = if ($errorText) { $errorText } else { 'Saida do DiskUsage nao reconhecida.' }
            }
        }
    } -ThrottleLimit $ThrottleLimit
)
$watch.Stop()

$result = [ordered]@{
    scannedAt = (Get-Date).ToString('o')
    drive = $Drive
    durationSeconds = [math]::Round($watch.Elapsed.TotalSeconds, 1)
    timeoutSecondsPerFolder = $TimeoutSeconds
    throttleLimit = $ThrottleLimit
    folders = @($rows | Sort-Object SizeOnDiskBytes -Descending)
}

$outputPath = Join-Path $OutDir "root-folders_$Stamp.json"
$result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $outputPath -Encoding utf8
Write-Host "Medicao salva em $outputPath"
$result.folders | Select-Object Path, SizeOnDiskGB, DurationSeconds, Complete, Error | Format-Table -AutoSize
Write-Output $outputPath
