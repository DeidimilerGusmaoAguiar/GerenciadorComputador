# disk-map.ps1 - mapeamento de espaco (playbook do disk-investigator). READ-ONLY.
# Saida: reports/disk-investigation_<stamp>.{txt,json}
param(
  [string]$Drive = 'C:',
  [int]$BigFileMB = 500,
  [string]$OutDir = "$PSScriptRoot\..\reports"
)
$ErrorActionPreference = 'SilentlyContinue'
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$stamp = Get-Date -Format 'yyyy-MM-dd_HHmm'
$txt = Join-Path $OutDir "disk-investigation_$stamp.txt"
$json = Join-Path $OutDir "disk-investigation_$stamp.json"

function FolderGB($p) {
  $s = (Get-ChildItem -LiteralPath $p -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
  if (-not $s) { 0 } else { [math]::Round($s/1GB, 2) }
}

$dl = $Drive.TrimEnd(':')

"=== DISK MAP $Drive $stamp ===" | Out-File $txt
"" | Out-File $txt -Append

# 1. Volume
$vol = Get-Volume -DriveLetter $dl
"VOLUME Total $([math]::Round($vol.Size/1GB,1)) GB | Livre $([math]::Round($vol.SizeRemaining/1GB,1)) GB | Usado $([math]::Round(($vol.Size-$vol.SizeRemaining)/1GB,1)) GB" | Out-File $txt -Append
"" | Out-File $txt -Append

# 2. Top-level dirs
"--- TOP-LEVEL por GB ---" | Out-File $txt -Append
$root = "$Drive\"
$topDirs = Get-ChildItem $root -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
  Write-Host "Medindo $($_.FullName)..."
  [pscustomobject]@{ Path = $_.FullName; GB = FolderGB $_.FullName }
} | Sort-Object GB -Descending
$topDirs | Format-Table Path, GB -AutoSize | Out-File $txt -Append

# 3. Descer 1 nivel nas 4 maiores
"" | Out-File $txt -Append
"--- SUBPASTAS das 4 maiores ---" | Out-File $txt -Append
foreach ($d in ($topDirs | Select-Object -First 4)) {
  "  [$($d.Path)]" | Out-File $txt -Append
  Get-ChildItem $d.Path -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
    [pscustomobject]@{ Path = $_.FullName; GB = FolderGB $_.FullName }
  } | Sort-Object GB -Descending | Select-Object -First 8 | Format-Table Path, GB -AutoSize | Out-File $txt -Append
}

# 4. Arquivos individuais grandes
"" | Out-File $txt -Append
"--- ARQUIVOS maiores que $BigFileMB MB ---" | Out-File $txt -Append
$bigFiles = Get-ChildItem $root -Recurse -File -Force -ErrorAction SilentlyContinue |
  Where-Object Length -gt ($BigFileMB*1MB) |
  Sort-Object Length -Descending | Select-Object -First 30 |
  ForEach-Object { [pscustomobject]@{ Path = $_.FullName; GB = [math]::Round($_.Length/1GB,2); Modified = $_.LastWriteTime } }
$bigFiles | Format-Table GB, Modified, Path -AutoSize | Out-File $txt -Append

# 5. Caches conhecidos
"" | Out-File $txt -Append
"--- CACHES CONHECIDOS ---" | Out-File $txt -Append
$caches = [ordered]@{
  'WindowsUpdate_SoftwareDistribution' = "$env:SystemRoot\SoftwareDistribution\Download"
  'WinSxS_NAO_apagar_manual'           = "$env:SystemRoot\WinSxS"
  'Windows_Temp'                        = "$env:SystemRoot\Temp"
  'User_Temp'                           = $env:TEMP
  'RecycleBin'                          = "$Drive\`$Recycle.Bin"
  'Edge_cache'                          = "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache"
  'Docker_WSL_dir'                      = "$env:LOCALAPPDATA\Docker\wsl"
  'NuGet_packages'                      = "$env:USERPROFILE\.nuget\packages"
  'npm_cache'                           = "$env:LOCALAPPDATA\npm-cache"
  'claude_data_NAO_limpar_auto'         = "$env:USERPROFILE\.claude"
  'codex_data_NAO_limpar_auto'          = "$env:USERPROFILE\.codex"
  'gemini_data_NAO_limpar_auto'         = "$env:USERPROFILE\.gemini"
  'grok_data_NAO_limpar_auto'           = "$env:USERPROFILE\.grok"
  'VS_local'                            = "$env:LOCALAPPDATA\Microsoft\VisualStudio"
}
$cacheRows = foreach ($k in $caches.Keys) {
  if (Test-Path $caches[$k]) { [pscustomobject]@{ Cache = $k; GB = FolderGB $caches[$k]; Path = $caches[$k] } }
}
$cacheRows = $cacheRows | Sort-Object GB -Descending
$cacheRows | Format-Table Cache, GB, Path -AutoSize | Out-File $txt -Append

@{ scannedAt=$stamp; volume=@{ totalGB=[math]::Round($vol.Size/1GB,1); freeGB=[math]::Round($vol.SizeRemaining/1GB,1) };
   topFolders=$topDirs; bigFiles=$bigFiles; caches=$cacheRows } | ConvertTo-Json -Depth 4 | Out-File $json

"" | Out-File $txt -Append
"=== FIM. Relatorio: $txt ===" | Out-File $txt -Append
Write-Host "CONCLUIDO: $txt"
