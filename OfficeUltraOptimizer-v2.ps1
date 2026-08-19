#requires -version 5.1
<#
OfficeUltraOptimizer.ps1
Target: old office PCs running Windows 10/11 where the main workload is:
- Google Chrome / browser CRM and web services
- MicroSIP / VoIP
- optional VPN

DEFAULT MODE = Ultra.

Ultra intentionally performs very aggressive optimization:
- attempts to disable Microsoft Defender as completely as Windows permits
- disables Windows Update services/tasks/policies
- disables Windows Store automatic updates
- disables Edge background startup and Edge updater
- disables telemetry, consumer apps, Phone Link, Maps, Xbox, Cortana, People, etc.
- disables Windows Search indexing
- disables SysMain on HDD / low-RAM systems
- disables UI animations, transparency, fades, shadows and full-window dragging
- keeps audio, networking, DNS, DHCP, firewall and common VPN services intact
- keeps the page file enabled and system-managed on low-RAM PCs

IMPORTANT:
Modern Windows Tamper Protection can block Defender changes even for a local Administrator.
The script therefore performs a post-check and reports whether Defender actually stopped.

Run from an elevated Windows PowerShell 5.1 console.

Examples:
  .\OfficeUltraOptimizer.ps1
  .\OfficeUltraOptimizer.ps1 -DryRun
  .\OfficeUltraOptimizer.ps1 -KeepDefender
  .\OfficeUltraOptimizer.ps1 -KeepUpdates
  .\OfficeUltraOptimizer.ps1 -RemoveOneDrive
  .\OfficeUltraOptimizer.ps1 -DisablePrinting
#>

[CmdletBinding()]
param(
    [ValidateSet('Safe','Aggressive','Ultra')]
    [string]$Mode = 'Ultra',

    [switch]$KeepDefender,
    [switch]$KeepUpdates,
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
    Write-Host 'ERROR: Run Windows PowerShell as Administrator.' -ForegroundColor Red
    exit 1
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupRoot = Join-Path $env:ProgramData "OfficeUltraOptimizer\$stamp"
New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
$logPath = Join-Path $backupRoot 'optimizer.log'
try { Start-Transcript -Path $logPath -Force | Out-Null } catch {}

function Write-Step([string]$Text) {
    Write-Host "`n==> $Text" -ForegroundColor Cyan
}

function Invoke-Change {
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][scriptblock]$Action
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

    Invoke-Change "Registry DWORD: $Path\$Name = $Value" {
        if (-not (Test-Path $Path)) {
            New-Item -Path $Path -Force | Out-Null
        }
        New-ItemProperty -Path $Path -Name $Name -PropertyType DWord -Value $Value -Force -ErrorAction Stop | Out-Null
    }
}

function Set-RegString {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value
    )

    Invoke-Change "Registry STRING: $Path\$Name = $Value" {
        if (-not (Test-Path $Path)) {
            New-Item -Path $Path -Force | Out-Null
        }
        New-ItemProperty -Path $Path -Name $Name -PropertyType String -Value $Value -Force -ErrorAction Stop | Out-Null
    }
}

function Set-ServiceState {
    param(
        [Parameter(Mandatory)][string]$Name,
        [ValidateSet('Automatic','Manual','Disabled')][string]$StartupType = 'Disabled',
        [switch]$Stop
    )

    $services = @(Get-Service -Name $Name -ErrorAction SilentlyContinue)
    if ($services.Count -eq 0) {
        Write-Host "[SKIP] Service not present: $Name" -ForegroundColor DarkGray
        return
    }

    foreach ($svc in $services) {
        Invoke-Change "Service $($svc.Name) -> $StartupType$(if($Stop){' + stop'})" {
            if ($Stop) {
                Stop-Service -Name $svc.Name -Force -ErrorAction SilentlyContinue
            }
            Set-Service -Name $svc.Name -StartupType $StartupType -ErrorAction Stop
        }
    }
}

function Disable-ServiceHard {
    param([Parameter(Mandatory)][string]$Name)

    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Host "[SKIP] Service not present: $Name" -ForegroundColor DarkGray
        return
    }

    Invoke-Change "Hard-disable service: $Name" {
        try { Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue } catch {}

        $scOut = & sc.exe config $Name start= disabled 2>&1
        $scCode = $LASTEXITCODE

        if ($scCode -ne 0) {
            # Fallback to the service Start registry value.
            $svcPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
            if (-not (Test-Path $svcPath)) {
                throw "Service registry key not found. sc.exe: $scOut"
            }
            Set-ItemProperty -Path $svcPath -Name Start -Value 4 -ErrorAction Stop
        }

        try { Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue } catch {}
    }
}

function Disable-ServiceTemplate {
    param([Parameter(Mandatory)][string]$Name)

    $svcPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
    if (Test-Path $svcPath) {
        Set-RegDword $svcPath 'Start' 4
    }

    @(Get-Service -Name "$Name*" -ErrorAction SilentlyContinue) | ForEach-Object {
        try { Stop-Service -Name $_.Name -Force -ErrorAction SilentlyContinue } catch {}
    }
}

function Disable-ScheduledTaskIfPresent {
    param(
        [Parameter(Mandatory)][string]$TaskPath,
        [Parameter(Mandatory)][string]$TaskName
    )

    $task = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $task) { return }

    Invoke-Change "Disable task: $TaskPath$TaskName" {
        Disable-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop | Out-Null
    }
}

function Disable-TasksByPath {
    param([Parameter(Mandatory)][string[]]$Paths)

    foreach ($path in $Paths) {
        $tasks = @(Get-ScheduledTask -TaskPath $path -ErrorAction SilentlyContinue)
        foreach ($task in $tasks) {
            Invoke-Change "Disable task: $($task.TaskPath)$($task.TaskName)" {
                Disable-ScheduledTask -InputObject $task -ErrorAction Stop | Out-Null
            }
        }
    }
}

function Remove-AppxByName {
    param([Parameter(Mandatory)][string]$NamePattern)

    if ($DryRun) {
        Write-Host "[DRY-RUN] Remove AppX: $NamePattern" -ForegroundColor Yellow
        return
    }

    try {
        Get-AppxPackage -AllUsers -Name $NamePattern -ErrorAction SilentlyContinue |
            ForEach-Object {
                try {
                    Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction Stop
                    Write-Host "[REMOVED] AppX: $($_.Name)" -ForegroundColor Green
                }
                catch {
                    Write-Host "[SKIP] AppX $($_.Name): $($_.Exception.Message)" -ForegroundColor DarkGray
                }
            }
    }
    catch {}

    try {
        Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like $NamePattern } |
            ForEach-Object {
                try {
                    Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -AllUsers -ErrorAction Stop | Out-Null
                    Write-Host "[UNPROVISIONED] $($_.DisplayName)" -ForegroundColor Green
                }
                catch {
                    Write-Host "[SKIP] Provisioned $($_.DisplayName): $($_.Exception.Message)" -ForegroundColor DarkGray
                }
            }
    }
    catch {}
}

function Export-RegistryKey {
    param(
        [Parameter(Mandatory)][string]$NativePath,
        [Parameter(Mandatory)][string]$FileName
    )

    if ($DryRun) { return }
    try {
        & reg.exe export $NativePath (Join-Path $backupRoot $FileName) /y | Out-Null
    }
    catch {}
}

Write-Step 'Detect Windows and hardware'

$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$gpu = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
    Select-Object Name, AdapterRAM, DriverVersion)

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

$gpuText = if ($gpu.Count) { ($gpu.Name -join ' | ') } else { 'Unknown' }

Write-Host "OS       : $($os.Caption)"
Write-Host "Version  : $($cv.DisplayVersion) / build $build"
Write-Host "Detected : $windowsFamily"
Write-Host "Edition  : $($cv.EditionID)"
Write-Host "CPU      : $($cpu.Name)"
Write-Host "RAM      : $ramGB GB"
Write-Host "Disk C:  : $systemDiskModel [$systemDiskType]"
Write-Host "GPU      : $gpuText"
Write-Host "Laptop   : $isLaptop"
Write-Host "Mode     : $Mode"
Write-Host "Backup   : $backupRoot"

if ($ramGB -le 2) {
    Write-Warning 'RAM <= 2 GB detected. Chrome itself can exhaust memory; page file will be kept enabled.'
}

Write-Step 'Create backups / snapshots'

Invoke-Change 'Save service snapshot' {
    Get-CimInstance Win32_Service |
        Select-Object Name, DisplayName, State, StartMode |
        Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $backupRoot 'services-before.csv')
}

Invoke-Change 'Save AppX snapshot' {
    Get-AppxPackage -AllUsers |
        Select-Object Name, PackageFullName |
        Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $backupRoot 'appx-before.csv')
}

Export-RegistryKey 'HKLM\SOFTWARE\Policies\Microsoft' 'HKLM-Policies-Microsoft.reg'
Export-RegistryKey 'HKCU\Software\Microsoft' 'HKCU-Software-Microsoft.reg'
Export-RegistryKey 'HKCU\Control Panel\Desktop' 'HKCU-Desktop.reg'

Invoke-Change 'Create System Restore point (best effort)' {
    Checkpoint-Computer -Description "OfficeUltraOptimizer $stamp" -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
}

Write-Step 'Disable telemetry, recommendations, consumer content and background noise'

$telemetryLevel = if ($Mode -eq 'Ultra') { 0 } else { 1 }
Set-RegDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' $telemetryLevel
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
Set-RegDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 1
Set-RegDword 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0
Set-RegDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds' 'EnableFeeds' 0
Set-RegDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0
Set-RegDword 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0
Set-RegDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'SearchboxTaskbarMode' 0
Set-RegDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SilentInstalledAppsEnabled' 0
Set-RegDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SoftLandingEnabled' 0
Set-RegDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SystemPaneSuggestionsEnabled' 0
Set-RegDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338388Enabled' 0
Set-RegDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338389Enabled' 0
Set-RegDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-353694Enabled' 0
Set-RegDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-353696Enabled' 0

$commonDisable = @(
    'DiagTrack',
    'dmwappushservice',
    'MapsBroker',
    'RetailDemo',
    'WMPNetworkSvc',
    'XblAuthManager',
    'XblGameSave',
    'XboxNetApiSvc',
    'Fax',
    'PhoneSvc',
    'RemoteRegistry',
    'wisvc',
    'WalletService',
    'SSDPSRV',
    'upnphost'
)

foreach ($svcName in $commonDisable) {
    Set-ServiceState -Name $svcName -StartupType Disabled -Stop
}

if ($Mode -eq 'Ultra') {
    $ultraDisable = @(
        'WerSvc',
        'DPS',
        'WdiServiceHost',
        'WdiSystemHost',
        'CDPSvc',
        'NcdAutoSetup',
        'icssvc',
        'PushToInstall',
        'InstallService',
        'WpnService'
    )

    foreach ($svcName in $ultraDisable) {
        Set-ServiceState -Name $svcName -StartupType Disabled -Stop
    }

    Disable-ServiceTemplate 'CDPUserSvc'
    Disable-ServiceTemplate 'WpnUserService'
    Disable-ServiceTemplate 'OneSyncSvc'
}

if ($Mode -ne 'Safe' -and -not $isLaptop) {
    Set-ServiceState -Name 'lfsvc' -StartupType Disabled -Stop
}

Write-Step 'Preserve Chrome, MicroSIP and VPN dependencies'

# These services are intentionally NOT disabled:
# Audiosrv, AudioEndpointBuilder, MMCSS
# Dhcp, Dnscache, NlaSvc, NSI, netprofm
# BFE, MpsSvc (Windows Firewall)
# RasMan, SstpSvc, IKEEXT, PolicyAgent, EapHost
# Winmgmt, RpcSs, DcomLaunch, CryptSvc, EventLog, Schedule
# BITS is kept because installers/updaters/VPN software may use it.

Set-ServiceState -Name 'BITS' -StartupType Manual

# Chrome: stop it from remaining resident after browser close.
Set-RegDword 'HKLM:\SOFTWARE\Policies\Google\Chrome' 'BackgroundModeEnabled' 0

Write-Step 'Tune printing'

$realPrinters = @()
try {
    $realPrinters = @(Get-Printer -ErrorAction Stop |
        Where-Object {
            $_.Name -notmatch 'Microsoft Print to PDF|Microsoft XPS|OneNote|Fax'
        })
}
catch {}

if ($DisablePrinting) {
    Set-ServiceState -Name 'Spooler' -StartupType Disabled -Stop
}
elseif ($realPrinters.Count -eq 0) {
    Set-ServiceState -Name 'Spooler' -StartupType Manual -Stop
    Write-Host 'No physical printer detected: Print Spooler -> Manual.'
}
else {
    Write-Host "Physical printer detected: Spooler preserved. $($realPrinters.Name -join ', ')"
}

Write-Step 'Tune HDD / SSD, Search and SysMain'

$isExplicitHdd = $systemDiskType -match 'HDD'
$isUnknownDisk = $systemDiskType -match 'Unknown|Unspecified'

if ($Mode -eq 'Ultra') {
    Set-ServiceState -Name 'WSearch' -StartupType Disabled -Stop

    if ($isExplicitHdd -or $isUnknownDisk -or $ramGB -le 4) {
        Set-ServiceState -Name 'SysMain' -StartupType Disabled -Stop
        Write-Host 'Ultra + HDD/unknown/low RAM: SysMain disabled.'
    }
    else {
        Set-ServiceState -Name 'SysMain' -StartupType Manual -Stop
        Write-Host 'Ultra + SSD with >4 GB RAM: SysMain -> Manual.'
    }

    if ($isExplicitHdd -or $isUnknownDisk) {
        Disable-ScheduledTaskIfPresent -TaskPath '\Microsoft\Windows\Defrag\' -TaskName 'ScheduledDefrag'
        Write-Host 'HDD/unknown disk: background ScheduledDefrag disabled. Run defrag manually during maintenance if needed.'
    }
}
elseif ($isExplicitHdd) {
    Set-ServiceState -Name 'WSearch' -StartupType Disabled -Stop
    Set-ServiceState -Name 'SysMain' -StartupType Disabled -Stop
}
elseif ($ramGB -le 4) {
    Set-ServiceState -Name 'WSearch' -StartupType Manual -Stop
    Set-ServiceState -Name 'SysMain' -StartupType Manual -Stop
}

# On low-RAM PCs the page file is critical. Keep it system managed.
if ($ramGB -le 4) {
    Invoke-Change 'Enable system-managed page file' {
        $computerSystem = Get-CimInstance Win32_ComputerSystem
        Set-CimInstance -InputObject $computerSystem -Property @{ AutomaticManagedPagefile = $true } -ErrorAction Stop | Out-Null
    }
}

Write-Step 'Disable OneDrive background activity'

Invoke-Change 'Stop OneDrive process' {
    Stop-Process -Name OneDrive -Force -ErrorAction SilentlyContinue
}
Set-RegDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableFileSyncNGSC' 1
Invoke-Change 'Remove OneDrive from current-user startup' {
    Remove-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'OneDrive' -ErrorAction SilentlyContinue
}

if ($RemoveOneDrive) {
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

Write-Step 'Disable Edge background startup'

$edgePolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
Set-RegDword $edgePolicy 'StartupBoostEnabled' 0
Set-RegDword $edgePolicy 'BackgroundModeEnabled' 0
Set-RegDword $edgePolicy 'LaunchEdgeOnWindowsStartupEnabled' 0
Set-RegDword $edgePolicy 'SmartScreenEnabled' 0

if ($Mode -eq 'Ultra') {
    Set-ServiceState -Name 'edgeupdate' -StartupType Disabled -Stop
    Set-ServiceState -Name 'edgeupdatem' -StartupType Disabled -Stop

    $edgeTasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue |
        Where-Object { $_.TaskName -like 'MicrosoftEdgeUpdateTaskMachine*' })

    foreach ($edgeTask in $edgeTasks) {
        Invoke-Change "Disable Edge updater task: $($edgeTask.TaskName)" {
            Disable-ScheduledTask -InputObject $edgeTask -ErrorAction Stop | Out-Null
        }
    }
}

Write-Step 'Disable Store automatic updates'

# Microsoft Store policy: turn off automatic download/install of app updates.
Set-RegDword 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' 'AutoDownload' 2

Write-Step 'Windows Update'

if ($Mode -eq 'Ultra' -and -not $KeepUpdates) {
    Write-Warning 'ULTRA: Windows Update will be disabled.'

    $wu = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    $wuAU = Join-Path $wu 'AU'

    Set-RegDword $wuAU 'NoAutoUpdate' 1
    Set-RegDword $wuAU 'AUOptions' 2
    Set-RegDword $wuAU 'NoAutoRebootWithLoggedOnUsers' 1
    Set-RegDword $wu 'DisableWindowsUpdateAccess' 1
    Set-RegDword $wu 'SetDisableUXWUAccess' 1
    Set-RegDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 0

    $updateServices = @(
        'wuauserv',
        'UsoSvc',
        'DoSvc',
        'WaaSMedicSvc',
        'uhssvc'
    )

    foreach ($svcName in $updateServices) {
        Disable-ServiceHard $svcName
    }

    Disable-TasksByPath @(
        '\Microsoft\Windows\WindowsUpdate\',
        '\Microsoft\Windows\UpdateOrchestrator\',
        '\Microsoft\Windows\WaaSMedic\'
    )

    Invoke-Change 'Stop Windows Update orchestration processes' {
        'MoUsoCoreWorker','MusNotification','MusNotificationUx','UsoClient' |
            ForEach-Object {
                Stop-Process -Name $_ -Force -ErrorAction SilentlyContinue
            }
    }

    # TrustedInstaller is intentionally preserved as Manual because Windows servicing,
    # optional features, SFC/DISM and component repair can require it.
    Set-ServiceState -Name 'TrustedInstaller' -StartupType Manual
}
else {
    $wu = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    $wuAU = Join-Path $wu 'AU'
    Set-RegDword $wuAU 'NoAutoUpdate' 0
    Set-RegDword $wuAU 'AUOptions' 2
    Set-RegDword $wuAU 'NoAutoRebootWithLoggedOnUsers' 1
    Set-RegDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 0
}

Write-Step 'Microsoft Defender'

$tamperProtectedBefore = $null
try {
    $mpStatusBefore = Get-MpComputerStatus -ErrorAction Stop
    if ($mpStatusBefore.PSObject.Properties.Name -contains 'IsTamperProtected') {
        $tamperProtectedBefore = [bool]$mpStatusBefore.IsTamperProtected
    }
}
catch {}

if ($Mode -eq 'Ultra' -and -not $KeepDefender) {
    Write-Warning 'ULTRA: attempting to disable Microsoft Defender Antivirus and SmartScreen.'

    if ($tamperProtectedBefore -eq $true) {
        Write-Warning 'Tamper Protection is ON. Windows may block/revert Defender changes. Final verification will show the real state.'
    }

    if (Get-Command Set-MpPreference -ErrorAction SilentlyContinue) {
        $defenderActions = @(
            @{ Text='Disable Defender real-time monitoring';      Action={ Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction Stop } },
            @{ Text='Disable Defender behavior monitoring';       Action={ Set-MpPreference -DisableBehaviorMonitoring $true -ErrorAction Stop } },
            @{ Text='Disable Defender script scanning';           Action={ Set-MpPreference -DisableScriptScanning $true -ErrorAction Stop } },
            @{ Text='Disable Defender downloaded-file scanning';  Action={ Set-MpPreference -DisableIOAVProtection $true -ErrorAction Stop } },
            @{ Text='Disable Defender archive scanning';          Action={ Set-MpPreference -DisableArchiveScanning $true -ErrorAction Stop } },
            @{ Text='Disable Defender email scanning';            Action={ Set-MpPreference -DisableEmailScanning $true -ErrorAction Stop } },
            @{ Text='Disable Defender removable-drive scanning';  Action={ Set-MpPreference -DisableRemovableDriveScanning $true -ErrorAction Stop } },
            @{ Text='Disable Defender block-at-first-seen';       Action={ Set-MpPreference -DisableBlockAtFirstSeen $true -ErrorAction Stop } },
            @{ Text='Disable Defender catch-up full scans';       Action={ Set-MpPreference -DisableCatchupFullScan $true -ErrorAction Stop } },
            @{ Text='Disable Defender catch-up quick scans';      Action={ Set-MpPreference -DisableCatchupQuickScan $true -ErrorAction Stop } },
            @{ Text='Disable Defender scheduled signature check'; Action={ Set-MpPreference -CheckForSignaturesBeforeRunningScan $false -ErrorAction Stop } },
            @{ Text='Disable Defender cloud reporting';           Action={ Set-MpPreference -MAPSReporting Disabled -ErrorAction Stop } },
            @{ Text='Disable Defender automatic sample upload';   Action={ Set-MpPreference -SubmitSamplesConsent NeverSend -ErrorAction Stop } }
        )

        foreach ($item in $defenderActions) {
            Invoke-Change $item.Text $item.Action
        }
    }

    # Policy + legacy/fallback registry values. Newer Windows may ignore protected values
    # when Tamper Protection is active.
    Set-RegDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' 'DisableAntiSpyware' 1
    Set-RegDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' 'DisableAntiVirus' 1
    Set-RegDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection' 'DisableRealtimeMonitoring' 1
    Set-RegDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection' 'DisableBehaviorMonitoring' 1
    Set-RegDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection' 'DisableOnAccessProtection' 1
    Set-RegDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection' 'DisableScanOnRealtimeEnable' 1
    Set-RegDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet' 'SpynetReporting' 0
    Set-RegDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet' 'SubmitSamplesConsent' 2

    # Windows SmartScreen / application reputation checks.
    Set-RegDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableSmartScreen' 0
    Set-RegDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AppHost' 'EnableWebContentEvaluation' 0

    # Hide Windows Security tray icon.
    Set-RegDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender Security Center\Systray' 'HideSystray' 1
    Invoke-Change 'Stop Windows Security tray process' {
        Stop-Process -Name SecurityHealthSystray -Force -ErrorAction SilentlyContinue
    }

    Disable-TasksByPath @('\Microsoft\Windows\Windows Defender\')

    # Protected services may reject these operations when tamper protection is active.
    foreach ($svcName in @('WinDefend','WdNisSvc','Sense')) {
        Disable-ServiceHard $svcName
    }

    # Security Health service is not the antivirus engine; disabling it removes extra UI/health monitoring overhead.
    Disable-ServiceHard 'SecurityHealthService'
}
else {
    Write-Host 'Defender preserved.'
}

Write-Step 'Disable telemetry / feedback scheduled tasks'

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

Write-Step 'Remove consumer AppX packages'

if ($Mode -in @('Aggressive','Ultra')) {
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
        'MSTeams',
        'Microsoft.Copilot',
        'MicrosoftWindows.Client.WebExperience',
        'Microsoft.OutlookForWindows'
    )

    foreach ($app in $bloat) {
        Remove-AppxByName -NamePattern $app
    }
}

Write-Step 'Disable transparency, animations and GPU-heavy shell effects'

Set-RegDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 0
Set-RegDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 2
Set-RegDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAnimations' 0
Set-RegDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ListviewAlphaSelect' 0
Set-RegDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ListviewShadow' 0
Set-RegDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'DisablePreviewDesktop' 1
Set-RegDword 'HKCU:\Software\Microsoft\Windows\DWM' 'EnableAeroPeek' 0
Set-RegString 'HKCU:\Control Panel\Desktop\WindowMetrics' 'MinAnimate' '0'
Set-RegString 'HKCU:\Control Panel\Desktop' 'DragFullWindows' '0'
Set-RegString 'HKCU:\Control Panel\Desktop' 'MenuShowDelay' '20'
Set-RegDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize' 'StartupDelayInMSec' 0

# Use the Windows API as well as registry values so the active session receives
# the change instead of only changing the "VisualFXSetting" selector.
Invoke-Change 'Apply Windows UI performance flags via SystemParametersInfo' {
    if (-not ('OfficeUltra.NativeUI' -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

namespace OfficeUltra
{
    public static class NativeUI
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct ANIMATIONINFO
        {
            public uint cbSize;
            public int iMinAnimate;
        }

        [DllImport("user32.dll", EntryPoint="SystemParametersInfoW", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SystemParametersInfoBool(
            uint uiAction,
            uint uiParam,
            [MarshalAs(UnmanagedType.Bool)] ref bool pvParam,
            uint fWinIni);

        [DllImport("user32.dll", EntryPoint="SystemParametersInfoW", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SystemParametersInfoPtr(
            uint uiAction,
            uint uiParam,
            IntPtr pvParam,
            uint fWinIni);

        [DllImport("user32.dll", EntryPoint="SystemParametersInfoW", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SystemParametersInfoAnimation(
            uint uiAction,
            uint uiParam,
            ref ANIMATIONINFO pvParam,
            uint fWinIni);

        private const uint SPIF_UPDATEINIFILE = 0x01;
        private const uint SPIF_SENDCHANGE = 0x02;
        private const uint FLAGS = SPIF_UPDATEINIFILE | SPIF_SENDCHANGE;

        public static void DisableEffects()
        {
            bool off = false;

            SystemParametersInfoBool(0x1043, 0, ref off, FLAGS); // SPI_SETCLIENTAREAANIMATION
            SystemParametersInfoBool(0x103F, 0, ref off, FLAGS); // SPI_SETUIEFFECTS
            SystemParametersInfoBool(0x1003, 0, ref off, FLAGS); // SPI_SETMENUANIMATION
            SystemParametersInfoBool(0x1017, 0, ref off, FLAGS); // SPI_SETTOOLTIPANIMATION
            SystemParametersInfoBool(0x1015, 0, ref off, FLAGS); // SPI_SETSELECTIONFADE
            SystemParametersInfoBool(0x101B, 0, ref off, FLAGS); // SPI_SETCURSORSHADOW

            // SPI_SETDRAGFULLWINDOWS: uiParam = FALSE, pvParam ignored.
            SystemParametersInfoPtr(0x0025, 0, IntPtr.Zero, FLAGS);

            ANIMATIONINFO ai = new ANIMATIONINFO();
            ai.cbSize = (uint)Marshal.SizeOf(typeof(ANIMATIONINFO));
            ai.iMinAnimate = 0;
            SystemParametersInfoAnimation(0x0049, ai.cbSize, ref ai, FLAGS); // SPI_SETANIMATION
        }
    }
}
"@
    }

    [OfficeUltra.NativeUI]::DisableEffects()
}

Write-Step 'Clean temporary files'

Invoke-Change 'Clean current-user TEMP' {
    Get-ChildItem -LiteralPath $env:TEMP -Force -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

# Do NOT disable the page file.
# Do NOT disable DWM: on Windows 10/11 it is a core desktop compositor.
# Do NOT disable firewall/network/audio/VPN services.

Write-Step 'Post-check'

$defenderState = [ordered]@{
    Available = $false
    TamperProtected = $tamperProtectedBefore
    AntivirusEnabled = $null
    RealTimeProtectionEnabled = $null
    AMServiceEnabled = $null
}

try {
    $mpStatusAfter = Get-MpComputerStatus -ErrorAction Stop
    $defenderState.Available = $true

    if ($mpStatusAfter.PSObject.Properties.Name -contains 'IsTamperProtected') {
        $defenderState.TamperProtected = [bool]$mpStatusAfter.IsTamperProtected
    }
    if ($mpStatusAfter.PSObject.Properties.Name -contains 'AntivirusEnabled') {
        $defenderState.AntivirusEnabled = [bool]$mpStatusAfter.AntivirusEnabled
    }
    if ($mpStatusAfter.PSObject.Properties.Name -contains 'RealTimeProtectionEnabled') {
        $defenderState.RealTimeProtectionEnabled = [bool]$mpStatusAfter.RealTimeProtectionEnabled
    }
    if ($mpStatusAfter.PSObject.Properties.Name -contains 'AMServiceEnabled') {
        $defenderState.AMServiceEnabled = [bool]$mpStatusAfter.AMServiceEnabled
    }
}
catch {}

$serviceCheckNames = @(
    'wuauserv','UsoSvc','DoSvc','WaaSMedicSvc',
    'WinDefend','WdNisSvc','SecurityHealthService',
    'WSearch','SysMain','DiagTrack','Spooler'
)

$serviceCheck = foreach ($name in $serviceCheckNames) {
    $svc = Get-CimInstance Win32_Service -Filter "Name='$name'" -ErrorAction SilentlyContinue
    if ($svc) {
        [pscustomobject]@{
            Name      = $svc.Name
            State     = $svc.State
            StartMode = $svc.StartMode
        }
    }
}

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
    GPU             = $gpuText
    Laptop          = $isLaptop
    Mode            = $Mode
    KeepDefender    = [bool]$KeepDefender
    KeepUpdates     = [bool]$KeepUpdates
    RemoveOneDrive  = [bool]$RemoveOneDrive
    DisablePrinting = [bool]$DisablePrinting
    DryRun          = [bool]$DryRun
    Defender        = $defenderState
    BackupFolder    = $backupRoot
}

if (-not $DryRun) {
    $result | ConvertTo-Json -Depth 5 |
        Set-Content -Encoding UTF8 -Path (Join-Path $backupRoot 'result.json')

    $serviceCheck |
        Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $backupRoot 'services-after.csv')
}

Write-Host ''
Write-Host '--- Core service state after optimization ---' -ForegroundColor Cyan
$serviceCheck | Format-Table -AutoSize

Write-Host ''
Write-Host '--- Defender verification ---' -ForegroundColor Cyan
$defenderState.GetEnumerator() | ForEach-Object {
    Write-Host ("{0,-28}: {1}" -f $_.Key, $_.Value)
}

if ($Mode -eq 'Ultra' -and -not $KeepDefender) {
    if ($defenderState.RealTimeProtectionEnabled -eq $true -or $defenderState.AntivirusEnabled -eq $true) {
        Write-Warning 'Defender is still active. The most likely reason is Tamper Protection / protected Defender services.'
    }
    elseif ($defenderState.Available) {
        Write-Host 'Defender reports real-time protection disabled.' -ForegroundColor Green
    }
}

Write-Host ''
Write-Host 'Completed. Restart Windows once.' -ForegroundColor Green
Write-Host "Log / snapshots: $backupRoot"
Write-Host ''
Write-Host 'DEFAULT Ultra keeps: Chrome networking, MicroSIP audio/network, VPN services, Firewall, BITS and page file.'
Write-Host ''
Write-Host 'Examples:'
Write-Host '  .\OfficeUltraOptimizer.ps1'
Write-Host '  .\OfficeUltraOptimizer.ps1 -DryRun'
Write-Host '  .\OfficeUltraOptimizer.ps1 -KeepDefender'
Write-Host '  .\OfficeUltraOptimizer.ps1 -KeepUpdates'
Write-Host '  .\OfficeUltraOptimizer.ps1 -RemoveOneDrive'
Write-Host '  .\OfficeUltraOptimizer.ps1 -DisablePrinting'

try { Stop-Transcript | Out-Null } catch {}
