#requires -version 5.1
<#
OfficeLiteOptimizer.ps1
Universal low-resource profile for Windows 10/11 office PCs.

Default profile: Aggressive, but intentionally DOES NOT disable:
- Microsoft Defender real-time protection
- Windows Update service
- Windows Security service
- Firewall
- RPC, WMI, networking, cryptography, Task Scheduler and other core services

Instead:
- Windows Update is changed to "notify before download"
- Defender scheduled scanning is CPU-throttled and prefers idle time
- optional telemetry, maps, Xbox, Phone Link, consumer apps and background features are reduced
- Edge startup/background mode is disabled
- OneDrive background sync is disabled; optional uninstall is available
- Search/SysMain are reduced automatically on HDD systems
#>

[CmdletBinding()]
param(
    [ValidateSet('Safe','Aggressive')]
    [string]$Mode = 'Aggressive',

    [switch]$RemoveOneDrive,

    [switch]$DisablePrinting,

    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    Write-Host ''
    Write-Host 'ERROR: Run PowerShell as Administrator.' -ForegroundColor Red
    Write-Host 'Right-click PowerShell -> Run as administrator, then run this script again.'
    exit 1
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupRoot = Join-Path $env:ProgramData "OfficeLiteOptimizer\$stamp"
New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
$logPath = Join-Path $backupRoot 'optimizer.log'

try { Start-Transcript -Path $logPath -Force | Out-Null } catch {}

function Write-Step([string]$Text) {
    Write-Host "`n==> $Text" -ForegroundColor Cyan
}

function Invoke-Change {
    param(
        [string]$Description,
        [scriptblock]$Action
    )

    if ($DryRun) {
        Write-Host "[DRY-RUN] $Description" -ForegroundColor Yellow
        return
    }

    try {
        & $Action
        Write-Host "[OK] $Description" -ForegroundColor Green
    }
    catch {
        Write-Warning "$Description :: $($_.Exception.Message)"
    }
}

function Set-RegDword {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$Value
    )

    Invoke-Change "Registry: $Path\$Name = $Value" {
        if (-not (Test-Path $Path)) {
            New-Item -Path $Path -Force | Out-Null
        }
        New-ItemProperty -Path $Path -Name $Name -PropertyType DWord -Value $Value -Force | Out-Null
    }
}

function Set-ServiceState {
    param(
        [Parameter(Mandatory)][string]$Name,
        [ValidateSet('Automatic','Manual','Disabled')][string]$StartupType = 'Disabled',
        [switch]$Stop
    )

    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Host "[SKIP] Service not present: $Name" -ForegroundColor DarkGray
        return
    }

    Invoke-Change "Service $Name -> $StartupType$(if($Stop){' + stop'})" {
        if ($Stop -and $svc.Status -ne 'Stopped') {
            Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue
        }
        Set-Service -Name $Name -StartupType $StartupType -ErrorAction Stop
    }
}

function Disable-ScheduledTaskIfPresent {
    param(
        [Parameter(Mandatory)][string]$TaskPath,
        [Parameter(Mandatory)][string]$TaskName
    )

    $task = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $task) {
        return
    }

    Invoke-Change "Disable task: $TaskPath$TaskName" {
        Disable-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop | Out-Null
    }
}

function Remove-AppxByName {
    param([Parameter(Mandatory)][string]$NamePattern)

    Write-Host "App package: $NamePattern"

    if ($DryRun) {
        return
    }

    # Existing user profiles.
    try {
        Get-AppxPackage -AllUsers -Name $NamePattern -ErrorAction SilentlyContinue |
            ForEach-Object {
                try {
                    Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction Stop
                    Write-Host "  [REMOVED] $($_.Name)" -ForegroundColor Green
                }
                catch {
                    Write-Host "  [SKIP] $($_.Name): $($_.Exception.Message)" -ForegroundColor DarkGray
                }
            }
    }
    catch {}

    # Prevent the package being provisioned for newly-created users.
    try {
        Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like $NamePattern } |
            ForEach-Object {
                try {
                    Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -AllUsers -ErrorAction Stop | Out-Null
                    Write-Host "  [UNPROVISIONED] $($_.DisplayName)" -ForegroundColor Green
                }
                catch {
                    Write-Host "  [SKIP provisioned] $($_.DisplayName)" -ForegroundColor DarkGray
                }
            }
    }
    catch {}
}

Write-Step 'Detect Windows and hardware'

$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$build = [int]$os.BuildNumber
$windowsFamily = if ($build -ge 22000) { 'Windows 11' } else { 'Windows 10' }
$ramGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
$isLaptop = [bool](Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)

$systemDriveLetter = $env:SystemDrive.TrimEnd(':')
$systemDiskType = 'Unknown'
$systemDiskModel = 'Unknown'

try {
    $partition = Get-Partition -DriveLetter $systemDriveLetter -ErrorAction Stop
    $disk = Get-Disk -Number $partition.DiskNumber -ErrorAction Stop
    $systemDiskModel = $disk.FriendlyName

    $physical = Get-PhysicalDisk -ErrorAction SilentlyContinue |
        Where-Object { [string]$_.DeviceId -eq [string]$disk.Number } |
        Select-Object -First 1

    if ($physical -and $physical.MediaType) {
        $systemDiskType = [string]$physical.MediaType
    }
}
catch {}

Write-Host "OS       : $($os.Caption)"
Write-Host "Version  : $($cv.DisplayVersion) / build $build"
Write-Host "Detected : $windowsFamily"
Write-Host "Edition  : $($cv.EditionID)"
Write-Host "CPU      : $($cpu.Name)"
Write-Host "RAM      : $ramGB GB"
Write-Host "Disk C:  : $systemDiskModel [$systemDiskType]"
Write-Host "Laptop   : $isLaptop"
Write-Host "Mode     : $Mode"
Write-Host "Backup   : $backupRoot"

# Basic machine snapshot.
Invoke-Change 'Save service snapshot' {
    Get-CimInstance Win32_Service |
        Select-Object Name, DisplayName, State, StartMode |
        Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $backupRoot 'services-before.csv')
}

Invoke-Change 'Save installed AppX snapshot' {
    Get-AppxPackage -AllUsers |
        Select-Object Name, PackageFullName |
        Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $backupRoot 'appx-before.csv')
}

# Best-effort restore point. It can fail if System Protection is disabled.
Invoke-Change 'Create System Restore point (best effort)' {
    Checkpoint-Computer -Description "OfficeLiteOptimizer $stamp" -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
}

Write-Step 'Reduce telemetry, recommendations and consumer background features'

# Keep Required diagnostic data rather than trying unsupported "zero telemetry" values on ordinary editions.
Set-RegDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 1
Set-RegDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'DoNotShowFeedbackNotifications' 1
Set-RegDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'LimitDiagnosticLogCollection' 1

Set-RegDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo' 'DisabledByGroupPolicy' 1
Set-RegDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1
Set-RegDword 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableTailoredExperiencesWithDiagnosticData' 1

Set-RegDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableActivityFeed' 0
Set-RegDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'PublishUserActivities' 0
Set-RegDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'UploadUserActivities' 0

Set-RegDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'AllowCortana' 0
Set-RegDword 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1

# Disable background execution for Store apps for the current user where supported.
Set-RegDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 1

# Widgets / feeds.
Set-RegDword 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0
Set-RegDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds' 'EnableFeeds' 0

# Game DVR / Xbox capture.
Set-RegDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0
Set-RegDword 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0

Write-Step 'Disable optional services'

$servicesToDisable = @(
    'DiagTrack',          # Connected User Experiences and Telemetry
    'dmwappushservice',   # WAP push / diagnostics
    'MapsBroker',         # Downloaded Maps Manager
    'RetailDemo',         # Retail Demo
    'WMPNetworkSvc',      # Windows Media Player Network Sharing
    'XblAuthManager',     # Xbox Live Auth Manager
    'XblGameSave',        # Xbox Live Game Save
    'XboxNetApiSvc',      # Xbox Live Networking
    'Fax',                # Fax
    'PhoneSvc',           # Phone Service / Phone Link support
    'RemoteRegistry',     # Remote Registry
    'wisvc',              # Windows Insider Service
    'WalletService'       # Wallet
)

foreach ($svcName in $servicesToDisable) {
    Set-ServiceState -Name $svcName -StartupType Disabled -Stop
}

# Windows Error Reporting: do not fully disable in Safe mode.
if ($Mode -eq 'Aggressive') {
    Set-ServiceState -Name 'WerSvc' -StartupType Manual -Stop
}

# Geolocation is optional on fixed office desktops.
if ($Mode -eq 'Aggressive' -and -not $isLaptop) {
    Set-ServiceState -Name 'lfsvc' -StartupType Disabled -Stop
}

Write-Step 'Tune printing automatically'

$realPrinters = @()
try {
    $realPrinters = Get-Printer -ErrorAction Stop |
        Where-Object {
            $_.Name -notmatch 'Microsoft Print to PDF|Microsoft XPS|OneNote|Fax'
        }
}
catch {}

if ($DisablePrinting) {
    Set-ServiceState -Name 'Spooler' -StartupType Disabled -Stop
}
elseif ($realPrinters.Count -eq 0) {
    # Manual keeps Print-to-PDF recoverable on many systems while avoiding permanent background startup.
    Set-ServiceState -Name 'Spooler' -StartupType Manual -Stop
    Write-Host 'No physical printer detected. Spooler changed to Manual.'
}
else {
    Write-Host "Physical printer detected. Spooler left unchanged: $($realPrinters.Name -join ', ')"
}

Write-Step 'Tune Search and SysMain based on system disk'

$isHdd = ($systemDiskType -match 'HDD|Unspecified') -and ($systemDiskType -notmatch 'SSD')

if ($isHdd) {
    Set-ServiceState -Name 'SysMain' -StartupType Disabled -Stop
    Set-ServiceState -Name 'WSearch' -StartupType Disabled -Stop
    Write-Host 'HDD-like system disk detected: SysMain and Search indexing disabled.'
}
elseif ($Mode -eq 'Aggressive' -and $ramGB -le 4) {
    Set-ServiceState -Name 'SysMain' -StartupType Manual -Stop
    Set-ServiceState -Name 'WSearch' -StartupType Manual -Stop
    Write-Host 'Very low RAM detected: SysMain and Search indexing changed to Manual.'
}
else {
    Write-Host 'SSD/unknown disk with more RAM: SysMain and Search indexing left unchanged.'
}

Write-Step 'Disable OneDrive background sync'

Invoke-Change 'Stop OneDrive process' {
    Stop-Process -Name OneDrive -Force -ErrorAction SilentlyContinue
}

Set-RegDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableFileSyncNGSC' 1

Invoke-Change 'Remove OneDrive from current-user startup' {
    Remove-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'OneDrive' -ErrorAction SilentlyContinue
}

if ($RemoveOneDrive) {
    Write-Warning 'RemoveOneDrive requested. Local OneDrive files are NOT deleted, but synchronization client will be uninstalled.'
    $oneDriveSetup = @(
        "$env:SystemRoot\SysWOW64\OneDriveSetup.exe",
        "$env:SystemRoot\System32\OneDriveSetup.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1

    if ($oneDriveSetup) {
        Invoke-Change 'Uninstall OneDrive client' {
            Start-Process -FilePath $oneDriveSetup -ArgumentList '/uninstall' -Wait -NoNewWindow
        }
    }
}

Write-Step 'Reduce Microsoft Edge background resource use'

$edgePolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
Set-RegDword $edgePolicy 'StartupBoostEnabled' 0
Set-RegDword $edgePolicy 'BackgroundModeEnabled' 0
Set-RegDword $edgePolicy 'LaunchEdgeOnWindowsStartupEnabled' 0

# Do NOT disable Edge updater: browser security updates are intentionally preserved.

Write-Step 'Configure Windows Update for no automatic background download'

$wu = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$wuAU = Join-Path $wu 'AU'

# Keep Windows Update functional, but require the user to initiate download.
Set-RegDword $wuAU 'NoAutoUpdate' 0
Set-RegDword $wuAU 'AUOptions' 2
Set-RegDword $wuAU 'NoAutoRebootWithLoggedOnUsers' 1

# Delivery Optimization: HTTP only, no peer-to-peer sharing.
Set-RegDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 0

Write-Step 'Throttle Microsoft Defender instead of disabling protection'

if (Get-Command Set-MpPreference -ErrorAction SilentlyContinue) {
    Invoke-Change 'Defender scheduled scan average CPU target -> 10%' {
        Set-MpPreference -ScanAvgCPULoadFactor 10 -ErrorAction Stop
    }

    Invoke-Change 'Defender scheduled scans -> low CPU priority' {
        Set-MpPreference -EnableLowCpuPriority $true -ErrorAction Stop
    }

    Invoke-Change 'Defender scheduled scans -> obey CPU throttling even while idle' {
        Set-MpPreference -DisableCpuThrottleOnIdleScans $false -ErrorAction Stop
    }

    Invoke-Change 'Defender scheduled scans -> run only when idle' {
        Set-MpPreference -ScanOnlyIfIdleEnabled $true -ErrorAction Stop
    }

    Invoke-Change 'Defender -> do not run missed full-scan catch-up during user work' {
        Set-MpPreference -DisableCatchupFullScan $true -ErrorAction Stop
    }

    Invoke-Change 'Defender -> do not run missed quick-scan catch-up during user work' {
        Set-MpPreference -DisableCatchupQuickScan $true -ErrorAction Stop
    }
}
else {
    Write-Host '[SKIP] Defender PowerShell module not available.' -ForegroundColor DarkGray
}

Write-Step 'Disable selected telemetry / feedback scheduled tasks'

$scheduledTasks = @(
    @('\Microsoft\Windows\Application Experience\', 'Microsoft Compatibility Appraiser'),
    @('\Microsoft\Windows\Application Experience\', 'ProgramDataUpdater'),
    @('\Microsoft\Windows\Customer Experience Improvement Program\', 'Consolidator'),
    @('\Microsoft\Windows\Customer Experience Improvement Program\', 'UsbCeip'),
    @('\Microsoft\Windows\Feedback\Siuf\', 'DmClient'),
    @('\Microsoft\Windows\Feedback\Siuf\', 'DmClientOnScenarioDownload'),
    @('\Microsoft\Windows\Maps\', 'MapsToastTask'),
    @('\Microsoft\Windows\Maps\', 'MapsUpdateTask')
)

foreach ($entry in $scheduledTasks) {
    Disable-ScheduledTaskIfPresent -TaskPath $entry[0] -TaskName $entry[1]
}

if ($Mode -eq 'Aggressive') {
    Write-Step 'Remove selected consumer AppX packages'

    $bloat = @(
        'Clipchamp.Clipchamp',
        'Microsoft.549981C3F5F10',
        'Microsoft.BingNews',
        'Microsoft.BingWeather',
        'Microsoft.GetHelp',
        'Microsoft.Getstarted',
        'Microsoft.MicrosoftOfficeHub',
        'Microsoft.MicrosoftSolitaireCollection',
        'Microsoft.MixedReality.Portal',
        'Microsoft.People',
        'Microsoft.SkypeApp',
        'Microsoft.WindowsFeedbackHub',
        'Microsoft.WindowsMaps',
        'Microsoft.Xbox.TCUI',
        'Microsoft.XboxApp',
        'Microsoft.XboxGameOverlay',
        'Microsoft.XboxGamingOverlay',
        'Microsoft.XboxIdentityProvider',
        'Microsoft.XboxSpeechToTextOverlay',
        'Microsoft.YourPhone',
        'Microsoft.ZuneMusic',
        'Microsoft.ZuneVideo',
        'MicrosoftTeams',
        'MSTeams'
    )

    foreach ($app in $bloat) {
        Remove-AppxByName -NamePattern $app
    }
}

Write-Step 'Reduce visual effects'

Set-RegDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 0
Set-RegDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 2

Write-Step 'Clean temporary files'

Invoke-Change 'Clean current-user TEMP' {
    Get-ChildItem -LiteralPath $env:TEMP -Force -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

# Avoid deleting Windows Update caches manually because that can damage update state.
# Avoid disabling pagefile: on low-RAM machines it is especially important.

Write-Step 'Final status'

$result = [ordered]@{
    Timestamp       = (Get-Date).ToString('s')
    Windows         = $windowsFamily
    Caption         = $os.Caption
    DisplayVersion  = $cv.DisplayVersion
    Build           = $build
    Edition         = $cv.EditionID
    CPU             = $cpu.Name
    RAM_GB          = $ramGB
    SystemDiskModel = $systemDiskModel
    SystemDiskType  = $systemDiskType
    Laptop          = $isLaptop
    Mode            = $Mode
    RemoveOneDrive  = [bool]$RemoveOneDrive
    DisablePrinting = [bool]$DisablePrinting
    DryRun          = [bool]$DryRun
    BackupFolder    = $backupRoot
}

$result | ConvertTo-Json -Depth 3 | Set-Content -Encoding UTF8 -Path (Join-Path $backupRoot 'result.json')
$result.GetEnumerator() | ForEach-Object {
    Write-Host ("{0,-18}: {1}" -f $_.Key, $_.Value)
}

Write-Host ''
Write-Host 'Completed.' -ForegroundColor Green
Write-Host 'Recommended: restart Windows once.'
Write-Host "Log and pre-change snapshots: $backupRoot"
Write-Host ''
Write-Host 'Examples:'
Write-Host '  .\OfficeLiteOptimizer.ps1'
Write-Host '  .\OfficeLiteOptimizer.ps1 -Mode Safe'
Write-Host '  .\OfficeLiteOptimizer.ps1 -RemoveOneDrive'
Write-Host '  .\OfficeLiteOptimizer.ps1 -DisablePrinting'
Write-Host '  .\OfficeLiteOptimizer.ps1 -DryRun'

try { Stop-Transcript | Out-Null } catch {}
