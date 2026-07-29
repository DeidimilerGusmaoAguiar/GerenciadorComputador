[CmdletBinding()]
param(
    [string]$Stamp = (Get-Date -Format 'yyyy-MM-dd_HHmm'),
    [string]$OutDir = (Join-Path $PSScriptRoot '..\reports')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir | Out-Null
}

function Get-AppxClassification {
    param([Parameter(Mandatory)][string]$Name)

    $corePatterns = @(
        '^Microsoft\.Windows',
        '^Microsoft\.UI\.Xaml',
        '^Microsoft\.VCLibs',
        '^Microsoft\.NET\.Native',
        '^Microsoft\.SecHealthUI$',
        '^Microsoft\.DesktopAppInstaller$',
        '^Microsoft\.StorePurchaseApp$',
        '^Microsoft\.MicrosoftEdge',
        '^Microsoft\.Edge',
        '^Microsoft\.AAD\.',
        '^Microsoft\.AccountsControl$',
        '^Microsoft\.LockApp$',
        '^Microsoft\.ShellExperienceHost$',
        '^Microsoft\.StartMenuExperienceHost$'
    )
    if ($corePatterns | Where-Object { $Name -match $_ }) {
        return 'CoreWindows'
    }

    $safeWindowsApps = @(
        'Microsoft.WindowsCalculator',
        'Microsoft.WindowsCamera',
        'Microsoft.WindowsNotepad',
        'Microsoft.Paint',
        'Microsoft.ScreenSketch',
        'Microsoft.WindowsSoundRecorder',
        'Microsoft.WindowsTerminal'
    )
    if ($Name -in $safeWindowsApps) {
        return 'WindowsAppKeep'
    }

    $optionalApps = @(
        'Microsoft.BingNews',
        'Microsoft.BingWeather',
        'Microsoft.GetHelp',
        'Microsoft.Getstarted',
        'Microsoft.MicrosoftOfficeHub',
        'Microsoft.Office.OneNote',
        'Microsoft.MicrosoftSolitaireCollection',
        'Microsoft.MixedReality.Portal',
        'Microsoft.People',
        'Microsoft.Wallet',
        'Microsoft.SkypeApp',
        'Microsoft.WindowsFeedbackHub',
        'Microsoft.YourPhone',
        'Microsoft.WindowsPhone',
        'Microsoft.ZuneMusic',
        'Microsoft.ZuneVideo',
        'MicrosoftCorporationII.QuickAssist',
        'Clipchamp.Clipchamp',
        'Microsoft.GamingApp',
        'Microsoft.XboxGamingOverlay',
        'Microsoft.Xbox.TCUI',
        'Microsoft.XboxIdentityProvider'
    )
    if ($Name -in $optionalApps) {
        return 'OptionalReview'
    }

    if ($Name -match '(?i)Dell|SupportAssist|HPJump|myHP|Lenovo|MyASUS|McAfee|Norton|CandyCrush|FarmVille|BubbleWitch') {
        return 'OEMOrTrialReview'
    }
    if ($Name -match '(?i)Disney|Spotify|LinkedIn|TikTok|Facebook|Instagram|Netflix') {
        return 'PromotedAppReview'
    }
    return 'OtherReview'
}

function Get-Win32Classification {
    param(
        [string]$Name,
        [string]$Publisher
    )
    $text = "$Name $Publisher"
    if ($text -match '(?i)McAfee|Norton|Candy Crush|FarmVille|Bubble Witch') {
        return 'TrialOrSponsoredReview'
    }
    if ($text -match '(?i)Dell Customer Connect|Dell SupportAssist|HP JumpStart|Lenovo Companion') {
        return 'OEMReview'
    }
    if ($text -match '(?i)Driver|Realtek|Intel|NVIDIA|AMD|Windows|Microsoft Visual C\+\+|\.NET|WebView2') {
        return 'SystemOrRuntime'
    }
    return 'InstalledProgram'
}

function Get-SafePropertyValue {
    param(
        [Parameter(Mandatory)]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )
    $property = $InputObject.PSObject.Properties[$Name]
    if ($property) {
        return $property.Value
    }
    return $null
}

function Parse-WingetTable {
    param([string[]]$Lines)
    $separatorIndex = -1
    $columnStarts = @()
    for ($index = 0; $index -lt $Lines.Count; $index++) {
        if ($Lines[$index] -match '^-{20,}\s*$' -and $index -gt 0) {
            $headerMatches = [regex]::Matches($Lines[$index - 1], '\S+')
            if ($headerMatches.Count -lt 3) {
                continue
            }
            $separatorIndex = $index
            $columnStarts = @($headerMatches | ForEach-Object Index)
            break
        }
    }
    if ($separatorIndex -lt 0) {
        return @()
    }

    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($line in $Lines[($separatorIndex + 1)..($Lines.Count - 1)]) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        $values = [System.Collections.Generic.List[string]]::new()
        for ($column = 0; $column -lt $columnStarts.Count; $column++) {
            $start = $columnStarts[$column]
            $end = if ($column -lt ($columnStarts.Count - 1)) {
                $columnStarts[$column + 1]
            } else {
                $line.Length
            }
            if ($start -ge $line.Length) {
                $values.Add('')
                continue
            }
            $length = [math]::Max(0, [math]::Min($line.Length, $end) - $start)
            $values.Add($line.Substring($start, $length).Trim())
        }
        $rows.Add([pscustomobject]@{
            Name = if ($values.Count -gt 0) { $values[0] } else { $null }
            Id = if ($values.Count -gt 1) { $values[1] } else { $null }
            InstalledVersion = if ($values.Count -gt 2) { $values[2] } else { $null }
            AvailableVersion = if ($values.Count -gt 3) { $values[3] } else { $null }
            Source = if ($values.Count -gt 4) { $values[4] } else { $null }
        })
    }
    return $rows
}

$uninstallDefinitions = @(
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'; Scope = 'Machine64' }
    @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'; Scope = 'Machine32' }
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'; Scope = 'CurrentUser' }
)
$registryPrograms = @(
    foreach ($definition in $uninstallDefinitions) {
        foreach ($entry in Get-ItemProperty -Path $definition.Path -ErrorAction SilentlyContinue) {
            $displayName = Get-SafePropertyValue -InputObject $entry -Name 'DisplayName'
            if ([string]::IsNullOrWhiteSpace($displayName)) {
                continue
            }
            $displayVersion = Get-SafePropertyValue -InputObject $entry -Name 'DisplayVersion'
            $publisher = Get-SafePropertyValue -InputObject $entry -Name 'Publisher'
            $installDate = Get-SafePropertyValue -InputObject $entry -Name 'InstallDate'
            $installLocation = Get-SafePropertyValue -InputObject $entry -Name 'InstallLocation'
            $estimatedSize = Get-SafePropertyValue -InputObject $entry -Name 'EstimatedSize'
            $systemComponent = Get-SafePropertyValue -InputObject $entry -Name 'SystemComponent'
            $windowsInstaller = Get-SafePropertyValue -InputObject $entry -Name 'WindowsInstaller'
            $releaseType = Get-SafePropertyValue -InputObject $entry -Name 'ReleaseType'
            $parentDisplayName = Get-SafePropertyValue -InputObject $entry -Name 'ParentDisplayName'
            [pscustomobject]@{
                Scope = $definition.Scope
                RegistryKey = $entry.PSChildName
                Name = [string]$displayName
                Version = [string]$displayVersion
                Publisher = [string]$publisher
                InstallDate = [string]$installDate
                InstallLocation = [string]$installLocation
                EstimatedSizeKB = if ($null -ne $estimatedSize) {
                    [int64]$estimatedSize
                } else {
                    $null
                }
                EstimatedSizeGB = if ($null -ne $estimatedSize) {
                    [math]::Round([double]$estimatedSize / 1MB, 3)
                } else {
                    $null
                }
                SystemComponent = [bool]($systemComponent -eq 1)
                WindowsInstaller = [bool]($windowsInstaller -eq 1)
                ReleaseType = [string]$releaseType
                ParentDisplayName = [string]$parentDisplayName
                Classification = Get-Win32Classification -Name $displayName -Publisher $publisher
            }
        }
    }
)

$storePrograms = @(
    Get-CimInstance Win32_InstalledStoreProgram -ErrorAction SilentlyContinue |
        ForEach-Object {
            [pscustomobject]@{
                Name = $_.Name
                Version = $_.Version
                Vendor = $_.Vendor
                Architecture = $_.Architecture
                Language = $_.Language
                ProgramId = $_.ProgramId
                Classification = Get-AppxClassification -Name $_.Name
            }
        } |
        Sort-Object Name, Version
)

$dismLines = @(& dism.exe /Online /Get-ProvisionedAppxPackages /English 2>&1)
$dismExitCode = $LASTEXITCODE
$provisionedPackages = [System.Collections.Generic.List[object]]::new()
$current = @{}
foreach ($line in $dismLines) {
    if ($line -match '^\s*([^:]+)\s*:\s*(.*)$') {
        $key = $Matches[1].Trim()
        $value = $Matches[2].Trim()
        if ($key -eq 'DisplayName' -and $current.Count -gt 0) {
            if ($current.ContainsKey('DisplayName')) {
                $provisionedPackages.Add([pscustomobject]@{
                    DisplayName = $current.DisplayName
                    Version = $current.Version
                    Architecture = $current.Architecture
                    PackageName = $current.PackageName
                    Classification = Get-AppxClassification -Name $current.DisplayName
                })
            }
            $current = @{}
        }
        $current[$key] = $value
    }
}
if ($current.ContainsKey('DisplayName')) {
    $provisionedPackages.Add([pscustomobject]@{
        DisplayName = $current.DisplayName
        Version = $current.Version
        Architecture = $current.Architecture
        PackageName = $current.PackageName
        Classification = Get-AppxClassification -Name $current.DisplayName
    })
}

$wingetLines = @(& winget.exe list --accept-source-agreements --disable-interactivity --nowarn 2>&1)
$wingetExitCode = $LASTEXITCODE
$wingetRows = @(Parse-WingetTable -Lines $wingetLines)

$result = [ordered]@{
    collectedAt = (Get-Date).ToString('o')
    stamp = $Stamp
    counts = [ordered]@{
        RegistryPrograms = $registryPrograms.Count
        StorePrograms = $storePrograms.Count
        ProvisionedPackages = $provisionedPackages.Count
        WingetRows = $wingetRows.Count
    }
    registryPrograms = @($registryPrograms | Sort-Object Name, Version)
    storePrograms = $storePrograms
    provisionedPackages = @($provisionedPackages | Sort-Object DisplayName)
    wingetRows = $wingetRows
    dismExitCode = $dismExitCode
    wingetExitCode = $wingetExitCode
}

$outputPath = Join-Path $OutDir "apps-inventory_$Stamp.json"
$result | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $outputPath -Encoding utf8
Write-Host "Inventario salvo em $outputPath"
$result.counts | Format-List
$storePrograms |
    Where-Object Classification -in 'OptionalReview', 'OEMOrTrialReview', 'PromotedAppReview' |
    Select-Object Name, Version, Classification |
    Format-Table -AutoSize
$registryPrograms |
    Where-Object Classification -in 'OEMReview', 'TrialOrSponsoredReview' |
    Select-Object Name, Version, Publisher, EstimatedSizeGB, Classification |
    Format-Table -AutoSize
Write-Output $outputPath
