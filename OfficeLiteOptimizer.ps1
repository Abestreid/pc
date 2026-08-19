#requires -version 5.1
<#
OfficeLiteOptimizer.ps1 v3.3.0
Universal optimizer for Windows 10/11 office PCs where the main workload is:
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

The script requests UAC automatically and keeps the original user's registry/profile target.
The file is intentionally plain ASCII PowerShell. Do not wrap it in Base64/GZip.

Examples:
  .\OfficeLiteOptimizer.ps1
  .\OfficeLiteOptimizer.ps1 -Mode Safe
  .\OfficeLiteOptimizer.ps1 -Mode Aggressive
  .\OfficeLiteOptimizer.ps1 -Mode Ultra -KeepDefender -KeepUpdates
  .\OfficeLiteOptimizer.ps1 -DryRun
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

$Version = '3.3.0'
$SelfUrl = 'https://raw.githubusercontent.com/Abestreid/pc/main/OfficeLiteOptimizer.ps1'
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = 3072

function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    $originalSid = ([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value.Replace("'", "''")
    $originalProfile = $env:USERPROFILE.Replace("'", "''")
    $argumentText = " -Mode '$Mode'"
    if ($KeepDefender) { $argumentText += ' -KeepDefender' }
    if ($KeepUpdates) { $argumentText += ' -KeepUpdates' }
    if ($RemoveOneDrive) { $argumentText += ' -RemoveOneDrive' }
    if ($DisablePrinting) { $argumentText += ' -DisablePrinting' }
    if ($DryRun) { $argumentText += ' -DryRun' }

    $elevatedCommand = @"
[Net.ServicePointManager]::SecurityProtocol = 3072
`$env:OFFICELITE_ORIGINAL_SID = '$originalSid'
`$env:OFFICELITE_ORIGINAL_PROFILE = '$originalProfile'
`$client = New-Object Net.WebClient
`$client.Encoding = [Text.Encoding]::UTF8
`$source = `$client.DownloadString('$SelfUrl')
`$script = [ScriptBlock]::Create(`$source)
& `$script $argumentText
"@
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($elevatedCommand))
    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    try {
        Start-Process $windowsPowerShell -Verb RunAs -ArgumentList "-NoExit -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedCommand" -ErrorAction Stop | Out-Null
        Write-Host 'Confirm UAC. Continue in the Administrator PowerShell window.' -ForegroundColor Yellow
    }
    catch {
        Write-Host "UAC failed: $($_.Exception.Message)" -ForegroundColor Red
    }
    return
}

$OriginalSid = $env:OFFICELITE_ORIGINAL_SID
$OriginalProfile = $env:OFFICELITE_ORIGINAL_PROFILE
if ([string]::IsNullOrWhiteSpace($OriginalSid)) {
    $OriginalSid = ([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
}
if ([string]::IsNullOrWhiteSpace($OriginalProfile)) {
    $OriginalProfile = $env:USERPROFILE
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupRoot = Join-Path $env:ProgramData "OfficeLiteOptimizer\$stamp"
New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
$logPath = Join-Path $backupRoot 'optimizer.log'
try { Start-Transcript -Path $logPath -Force | Out-Null } catch {}
$Changes = New-Object System.Collections.ArrayList

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
        [void]$Changes.Add([pscustomobject]@{Time=(Get-Date).ToString('HH:mm:ss');Status='DRY-RUN';Text=$Description})
        return
    }

    try {
        & $Action
        Write-Host "[OK] $Description" -ForegroundColor Green
        [void]$Changes.Add([pscustomobject]@{Time=(Get-Date).ToString('HH:mm:ss');Status='OK';Text=$Description})
    }
    catch {
        Write-Warning "$Description :: $($_.Exception.Message)"
        [void]$Changes.Add([pscustomobject]@{Time=(Get-Date).ToString('HH:mm:ss');Status='FAILED';Text="$Description :: $($_.Exception.Message)"})
    }
}

function Resolve-RegistryPath {
    param([Parameter(Mandatory)][string]$Path)

    if ($Path -match '^HKCU:\\?(.*)$') {
        return "Registry::HKEY_USERS\$OriginalSid\$($Matches[1])"
    }
    return $Path
}

function Set-RegDword {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$Value
    )

    $resolvedPath = Resolve-RegistryPath $Path
    Invoke-Change "Registry DWORD: $resolvedPath\$Name = $Value" {
        if (-not (Test-Path $resolvedPath)) {
            New-Item -Path $resolvedPath -Force | Out-Null
        }
        New-ItemProperty -Path $resolvedPath -Name $Name -PropertyType DWord -Value $Value -Force -ErrorAction Stop | Out-Null
    }
}

function Set-RegString {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value
    )

    $resolvedPath = Resolve-RegistryPath $Path
    Invoke-Change "Registry STRING: $resolvedPath\$Name = $Value" {
        if (-not (Test-Path $resolvedPath)) {
            New-Item -Path $resolvedPath -Force | Out-Null
        }
        New-ItemProperty -Path $resolvedPath -Name $Name -PropertyType String -Value $Value -Force -ErrorAction Stop | Out-Null
    }
}

function Remove-RegValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )

    $resolvedPath = Resolve-RegistryPath $Path
    if (-not (Test-Path $resolvedPath)) { return }
    Invoke-Change "Remove registry value: $resolvedPath\$Name" {
        Remove-ItemProperty -Path $resolvedPath -Name $Name -ErrorAction SilentlyContinue
    }
}

function Set-ServiceState {
    param(
        [Parameter(Mandatory)][string]$Name,
        [ValidateSet('Automatic','Manual','Disabled')][string]$StartupType = 'Disabled',
        [switch]$Stop,
        [switch]$Start
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
            if ($Start) {
                Start-Service -Name $svc.Name -ErrorAction Stop
            }
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

    Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services' -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -like "$Name*" } |
        ForEach-Object {
            Set-RegDword $_.PSPath 'Start' 4
        }

    @(Get-Service -Name "$Name*" -ErrorAction SilentlyContinue) | ForEach-Object {
        $instanceName = $_.Name
        Invoke-Change "Stop service instance: $instanceName" {
            Stop-Service -Name $instanceName -Force -ErrorAction SilentlyContinue
        }
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

function Enable-TasksByPath {
    param([Parameter(Mandatory)][string[]]$Paths)

    foreach ($path in $Paths) {
        $tasks = @(Get-ScheduledTask -TaskPath $path -ErrorAction SilentlyContinue)
        foreach ($task in $tasks) {
            Invoke-Change "Enable task: $($task.TaskPath)$($task.TaskName)" {
                Enable-ScheduledTask -InputObject $task -ErrorAction Stop | Out-Null
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
    if ($NativePath -match '^HKCU\\?(.*)$') {
        $NativePath = "HKEY_USERS\$OriginalSid\$($Matches[1])"
    }
    try {
        & reg.exe export $NativePath (Join-Path $backupRoot $FileName) /y | Out-Null
    }
    catch {}
}

function Save-Snapshot {
    param([Parameter(Mandatory)][string]$Tag)

    if ($DryRun) { return }
    try {
        Get-CimInstance Win32_Service |
            Select-Object Name, DisplayName, State, StartMode |
            Sort-Object Name |
            Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $backupRoot "services-$Tag.csv")
    }
    catch {}
    try {
        Get-CimInstance Win32_StartupCommand |
            Select-Object Name, Command, Location, User |
            Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $backupRoot "startup-$Tag.csv")
    }
    catch {}
    try {
        Get-Process |
            Select-Object ProcessName, Id, @{N='WorkingSetMB';E={[math]::Round($_.WorkingSet64 / 1MB, 1)}} |
            Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $backupRoot "processes-$Tag.csv")
    }
    catch {}
    try {
        Get-AppxPackage -AllUsers |
            Select-Object Name, PackageFullName |
            Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $backupRoot "appx-$Tag.csv")
    }
    catch {}
    try {
        if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
            Get-ScheduledTask |
                Select-Object TaskPath, TaskName, State |
                Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $backupRoot "tasks-$Tag.csv")
        }
    }
    catch {}
    try {
        if (Get-Command Get-PnpDevice -ErrorAction SilentlyContinue) {
            Get-PnpDevice |
                Where-Object { $_.Status -ne 'OK' } |
                Select-Object Class, FriendlyName, InstanceId, Status |
                Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $backupRoot "devices-problem-$Tag.csv")
        }
    }
    catch {}
}

function Get-SystemDiskInfo {
    $result = [ordered]@{
        Model = 'Unknown'
        Type = 'Unknown'
        Bus = 'Unknown'
        Confidence = 'Low'
    }

    try {
        $partition = Get-Partition -DriveLetter $env:SystemDrive.TrimEnd(':') -ErrorAction Stop
        $disk = Get-Disk -Number $partition.DiskNumber -ErrorAction Stop
        $result.Model = [string]$disk.FriendlyName
        $result.Bus = [string]$disk.BusType

        if ($result.Bus -match 'NVMe') {
            $result.Type = 'NVMe'
            $result.Confidence = 'High'
            return [pscustomobject]$result
        }

        $physical = Get-PhysicalDisk -ErrorAction SilentlyContinue |
            Where-Object {
                ([string]$_.DeviceId -eq [string]$disk.Number) -or
                ($_.FriendlyName -eq $disk.FriendlyName)
            } |
            Select-Object -First 1

        if ($physical) {
            if ([string]$physical.MediaType -match 'SSD') {
                $result.Type = 'SSD'
                $result.Confidence = 'High'
                return [pscustomobject]$result
            }
            if ([string]$physical.MediaType -match 'HDD') {
                $result.Type = 'HDD'
                $result.Confidence = 'High'
                return [pscustomobject]$result
            }
            if ($physical.PSObject.Properties.Name -contains 'SpindleSpeed') {
                $spindleSpeed = [int64]$physical.SpindleSpeed
                if ($spindleSpeed -gt 0) {
                    $result.Type = 'HDD'
                    $result.Confidence = 'High'
                    return [pscustomobject]$result
                }
            }
        }

        $wmiDisk = Get-CimInstance Win32_DiskDrive -Filter "Index=$($disk.Number)" -ErrorAction SilentlyContinue
        if ($wmiDisk) {
            if ($wmiDisk.Model) { $result.Model = [string]$wmiDisk.Model }
        }
    }
    catch {}

    if ($result.Model -match '(?i)NVMe') {
        $result.Type = 'NVMe'
        $result.Confidence = 'Medium'
    }
    elseif ($result.Model -match '(?i)SSD|Solid State') {
        $result.Type = 'SSD'
        $result.Confidence = 'Medium'
    }
    elseif ($result.Model -match '(?i)^ST\d|Seagate|WDC|Western Digital|HGST|Hitachi|TOSHIBA|Samsung HD') {
        $result.Type = 'HDD'
        $result.Confidence = 'Medium'
    }

    return [pscustomobject]$result
}

function Test-ChromePresent {
    $paths = @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$OriginalProfile\AppData\Local\Google\Chrome\Application\chrome.exe"
    )
    foreach ($path in $paths) {
        if ($path -and (Test-Path $path)) { return $true }
    }
    return $false
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
$displayVersion = if ($cv.DisplayVersion) { $cv.DisplayVersion } elseif ($cv.ReleaseId) { $cv.ReleaseId } else { $os.Version }
$ramGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
$isLaptop = [bool](Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
$diskInfo = Get-SystemDiskInfo
$systemDiskType = $diskInfo.Type
$systemDiskModel = $diskInfo.Model
$memoryProfile = if ($ramGB -le 4) { 'LOW_MEMORY' } elseif ($ramGB -lt 8) { 'BALANCED' } else { 'WARM_BROWSER' }
$chromePresent = Test-ChromePresent
$gpuText = if ($gpu.Count) { ($gpu.Name -join ' | ') } else { 'Unknown' }
$basicDisplayAdapter = [bool]($gpu | Where-Object {
    $_.Name -match '(?i)Microsoft Basic Display'
} | Select-Object -First 1)

Write-Host "OfficeLiteOptimizer v$Version"
Write-Host "OS       : $($os.Caption)"
Write-Host "Version  : $displayVersion / build $build"
Write-Host "Detected : $windowsFamily"
Write-Host "Edition  : $($cv.EditionID)"
Write-Host "CPU      : $($cpu.Name)"
Write-Host "RAM      : $ramGB GB [$memoryProfile]"
Write-Host "Disk C:  : $systemDiskModel [$systemDiskType/$($diskInfo.Bus), $($diskInfo.Confidence)]"
Write-Host "GPU      : $gpuText"
Write-Host "Chrome   : $chromePresent"
Write-Host "Laptop   : $isLaptop"
Write-Host "Mode     : $Mode"
Write-Host "Backup   : $backupRoot"

if ($ramGB -le 2) {
    Write-Warning 'RAM <= 2 GB detected. Chrome itself can exhaust memory; page file will be kept enabled.'
}
if ($basicDisplayAdapter) {
    Write-Warning 'Microsoft Basic Display Adapter detected. Install the proper GPU driver.'
}

Write-Step 'Create backups / snapshots'

Save-Snapshot 'before'

Export-RegistryKey 'HKLM\SOFTWARE\Policies\Microsoft' 'HKLM-Policies-Microsoft.reg'
Export-RegistryKey 'HKCU\Software\Microsoft' 'HKCU-Software-Microsoft.reg'
Export-RegistryKey 'HKCU\Control Panel\Desktop' 'HKCU-Desktop.reg'

Invoke-Change 'Create System Restore point (best effort)' {
    Checkpoint-Computer -Description "OfficeLiteOptimizer $stamp" -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
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
        'WpnService',
        'DusmSvc',
        'TrkWks'
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

Write-Step 'Adapt optional services to installed hardware'

$hardwareInventoryAvailable = $false
try {
    if (Get-Command Get-PnpDevice -ErrorAction SilentlyContinue) {
        $presentDevices = @(Get-PnpDevice -PresentOnly -ErrorAction Stop)
        $hardwareInventoryAvailable = $true
    }
}
catch {
    $presentDevices = @()
}

if ($hardwareInventoryAvailable -and $Mode -ne 'Safe') {
    $hasBluetooth = [bool]($presentDevices | Where-Object {
        $_.Class -match 'Bluetooth' -or $_.FriendlyName -match '(?i)Bluetooth'
    } | Select-Object -First 1)
    $hasCamera = [bool]($presentDevices | Where-Object {
        $_.Class -match 'Camera|Image' -or $_.FriendlyName -match '(?i)camera|webcam'
    } | Select-Object -First 1)
    $hasBiometric = [bool]($presentDevices | Where-Object {
        $_.Class -match 'Biometric' -or $_.FriendlyName -match '(?i)fingerprint|biometric'
    } | Select-Object -First 1)
    $hasTouch = [bool]($presentDevices | Where-Object {
        $_.FriendlyName -match '(?i)touch screen|touchscreen|pen'
    } | Select-Object -First 1)
    $hasNfc = [bool]($presentDevices | Where-Object {
        $_.FriendlyName -match '(?i)NFC|near field'
    } | Select-Object -First 1)

    if (-not $hasBluetooth) {
        foreach ($svcName in @('bthserv','BTAGService','BthAvctpSvc')) {
            Set-ServiceState -Name $svcName -StartupType Disabled -Stop
        }
    }
    if (-not $hasCamera) {
        foreach ($svcName in @('FrameServer','FrameServerMonitor')) {
            Set-ServiceState -Name $svcName -StartupType Disabled -Stop
        }
    }
    if (-not $hasBiometric) {
        Set-ServiceState -Name 'WbioSrvc' -StartupType Disabled -Stop
    }
    if (-not $hasTouch -and -not $isLaptop) {
        Set-ServiceState -Name 'TabletInputService' -StartupType Disabled -Stop
    }
    if (-not $hasNfc) {
        Set-ServiceState -Name 'SEMgrSvc' -StartupType Disabled -Stop
    }
}
else {
    Write-Host 'Hardware-specific services preserved because inventory is unavailable or Safe mode is active.'
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

# Chrome is warmed only when installed and RAM is at least 8 GB.
Set-RegDword 'HKLM:\SOFTWARE\Policies\Google\Chrome' 'HighEfficiencyModeEnabled' 1
if ($chromePresent -and $ramGB -ge 8 -and $Mode -ne 'Safe') {
    Set-RegDword 'HKLM:\SOFTWARE\Policies\Google\Chrome' 'BackgroundModeEnabled' 1
    $chromeWarmMode = 'ENABLED_8GB_PLUS'
}
else {
    Set-RegDword 'HKLM:\SOFTWARE\Policies\Google\Chrome' 'BackgroundModeEnabled' 0
    $chromeRunPath = "Registry::HKEY_USERS\$OriginalSid\Software\Microsoft\Windows\CurrentVersion\Run"
    if (Test-Path $chromeRunPath) {
        Invoke-Change 'Remove Chrome AutoLaunch for the original user' {
            $runProperties = (Get-ItemProperty $chromeRunPath -ErrorAction Stop).PSObject.Properties
            $runProperties |
                Where-Object { $_.Name -notmatch '^PS' -and $_.Name -match '^GoogleChromeAutoLaunch' } |
                ForEach-Object { Remove-ItemProperty -Path $chromeRunPath -Name $_.Name -ErrorAction Stop }
        }
    }
    $chromeWarmMode = 'DISABLED_LOW_MEMORY_OR_SAFE'
}

Write-Step 'Tune printing'

$realPrinters = @()
$printerInventoryKnown = $false
try {
    if (Get-Command Get-Printer -ErrorAction SilentlyContinue) {
        $realPrinters = @(Get-Printer -ErrorAction Stop | Where-Object {
            $_.Name -notmatch 'Microsoft Print to PDF|Microsoft XPS|OneNote|Fax'
        })
    }
    else {
        $realPrinters = @(Get-CimInstance Win32_Printer -ErrorAction Stop | Where-Object {
            $_.Name -notmatch 'Microsoft Print to PDF|Microsoft XPS|OneNote|Fax'
        })
    }
    $printerInventoryKnown = $true
}
catch {}

if ($DisablePrinting) {
    Set-ServiceState -Name 'Spooler' -StartupType Disabled -Stop
}
elseif ($printerInventoryKnown -and $realPrinters.Count -eq 0) {
    Set-ServiceState -Name 'Spooler' -StartupType Manual -Stop
    Write-Host 'No physical printer detected: Print Spooler -> Manual.'
}
else {
    Write-Host "Printing preserved. $($realPrinters.Name -join ', ')"
}

Write-Step 'Tune HDD / SSD, Search and SysMain'

$isExplicitHdd = $systemDiskType -match 'HDD'
$isUnknownDisk = $systemDiskType -match 'Unknown|Unspecified'
$isSolidState = $systemDiskType -match 'SSD|NVMe'
$sysMainProfile = 'PRESERVED'

if ($Mode -eq 'Ultra') {
    Set-ServiceState -Name 'WSearch' -StartupType Disabled -Stop

    if ($ramGB -le 4) {
        Set-ServiceState -Name 'SysMain' -StartupType Disabled -Stop
        $sysMainProfile = 'DISABLED_LOW_MEMORY'
    }
    elseif ($ramGB -ge 8) {
        Set-ServiceState -Name 'SysMain' -StartupType Automatic -Start
        $sysMainProfile = 'AUTOMATIC_8GB_PLUS'
    }
    elseif ($isSolidState) {
        Set-ServiceState -Name 'SysMain' -StartupType Automatic -Start
        $sysMainProfile = 'AUTOMATIC_BALANCED_SSD'
    }
    else {
        Set-ServiceState -Name 'SysMain' -StartupType Manual -Stop
        $sysMainProfile = 'MANUAL_BALANCED_HDD_OR_UNKNOWN'
    }

    if ($isExplicitHdd) {
        Disable-ScheduledTaskIfPresent -TaskPath '\Microsoft\Windows\Defrag\' -TaskName 'ScheduledDefrag'
        Write-Host 'HDD: background ScheduledDefrag disabled. Run defrag manually during maintenance if needed.'
    }
}
elseif ($isExplicitHdd) {
    Set-ServiceState -Name 'WSearch' -StartupType Disabled -Stop
    Set-ServiceState -Name 'SysMain' -StartupType Disabled -Stop
    $sysMainProfile = 'DISABLED_AGGRESSIVE_HDD'
}
elseif ($ramGB -le 4) {
    Set-ServiceState -Name 'WSearch' -StartupType Manual -Stop
    Set-ServiceState -Name 'SysMain' -StartupType Manual -Stop
    $sysMainProfile = 'MANUAL_AGGRESSIVE_LOW_MEMORY'
}

Write-Host "SysMain profile: $sysMainProfile"

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
    $oneDriveRunPath = Resolve-RegistryPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    Remove-ItemProperty $oneDriveRunPath -Name 'OneDrive' -ErrorAction SilentlyContinue
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
$edgeRunPath = Resolve-RegistryPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
if (Test-Path $edgeRunPath) {
    Invoke-Change 'Remove Edge AutoLaunch for the original user' {
        $edgeRunProperties = (Get-ItemProperty $edgeRunPath -ErrorAction Stop).PSObject.Properties
        $edgeRunProperties |
            Where-Object { $_.Name -notmatch '^PS' -and $_.Name -match '^MicrosoftEdgeAutoLaunch' } |
            ForEach-Object { Remove-ItemProperty -Path $edgeRunPath -Name $_.Name -ErrorAction Stop }
    }
}

if ($Mode -eq 'Ultra') {
    Set-ServiceState -Name 'edgeupdate' -StartupType Disabled -Stop
    Set-ServiceState -Name 'edgeupdatem' -StartupType Disabled -Stop
    Set-ServiceState -Name 'MicrosoftEdgeElevationService' -StartupType Disabled -Stop

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
    Set-RegDword $wu 'DisableWindowsUpdateAccess' 0
    Set-RegDword $wu 'SetDisableUXWUAccess' 0
    Set-RegDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 0

    if ($KeepUpdates) {
        Set-ServiceState -Name 'wuauserv' -StartupType Manual
        Set-ServiceState -Name 'UsoSvc' -StartupType Automatic
        Set-ServiceState -Name 'DoSvc' -StartupType Automatic
        Set-ServiceState -Name 'WaaSMedicSvc' -StartupType Manual
        Set-ServiceState -Name 'uhssvc' -StartupType Manual
        Enable-TasksByPath @(
            '\Microsoft\Windows\WindowsUpdate\',
            '\Microsoft\Windows\UpdateOrchestrator\',
            '\Microsoft\Windows\WaaSMedic\'
        )
    }
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
    foreach ($svcName in @('WinDefend','WdNisSvc','MDCoreSvc','Sense')) {
        Disable-ServiceHard $svcName
    }

    # Security Health service is not the antivirus engine; disabling it removes extra UI/health monitoring overhead.
    Disable-ServiceHard 'SecurityHealthService'
}
else {
    Write-Host 'Defender preserved.'
    if ($KeepDefender) {
        if (Get-Command Set-MpPreference -ErrorAction SilentlyContinue) {
            $defenderRestoreActions = @(
                { Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction Stop },
                { Set-MpPreference -DisableBehaviorMonitoring $false -ErrorAction Stop },
                { Set-MpPreference -DisableScriptScanning $false -ErrorAction Stop },
                { Set-MpPreference -DisableIOAVProtection $false -ErrorAction Stop },
                { Set-MpPreference -DisableArchiveScanning $false -ErrorAction Stop },
                { Set-MpPreference -DisableEmailScanning $false -ErrorAction Stop },
                { Set-MpPreference -DisableRemovableDriveScanning $false -ErrorAction Stop },
                { Set-MpPreference -DisableBlockAtFirstSeen $false -ErrorAction Stop }
            )
            foreach ($action in $defenderRestoreActions) {
                Invoke-Change 'Restore a Microsoft Defender protection setting' $action
            }
        }

        Remove-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' 'DisableAntiSpyware'
        Remove-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' 'DisableAntiVirus'
        Remove-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection' 'DisableRealtimeMonitoring'
        Remove-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection' 'DisableBehaviorMonitoring'
        Remove-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection' 'DisableOnAccessProtection'
        Remove-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection' 'DisableScanOnRealtimeEnable'
        Remove-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet' 'SpynetReporting'
        Remove-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet' 'SubmitSamplesConsent'
        Remove-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender Security Center\Systray' 'HideSystray'
        Set-RegDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableSmartScreen' 1
        Set-RegDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AppHost' 'EnableWebContentEvaluation' 1
        Set-ServiceState -Name 'WinDefend' -StartupType Automatic -Start
        Set-ServiceState -Name 'WdNisSvc' -StartupType Manual
        Set-ServiceState -Name 'MDCoreSvc' -StartupType Manual
        Set-ServiceState -Name 'SecurityHealthService' -StartupType Automatic -Start
        Enable-TasksByPath @('\Microsoft\Windows\Windows Defender\')
    }
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
        'Microsoft.BingSearch',
        'Microsoft.BingWeather',
        'Microsoft.GetHelp',
        'Microsoft.Getstarted',
        'Microsoft.MicrosoftOfficeHub',
        'Microsoft.MicrosoftSolitaireCollection',
        'Microsoft.MixedReality.Portal',
        'Microsoft.People',
        'Microsoft.SkypeApp',
        'Microsoft.WindowsFeedbackHub',
        'Microsoft.Windows.DevHome',
        'Microsoft.WindowsMaps',
        'Microsoft.WindowsAlarms',
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
        'Microsoft.OutlookForWindows',
        'MicrosoftWindows.CrossDevice'
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
    $originalTemp = Join-Path $OriginalProfile 'AppData\Local\Temp'
    if (Test-Path $originalTemp) {
        Get-ChildItem -LiteralPath $originalTemp -Force -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
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
    Assessment = 'UNKNOWN'
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

if ($KeepDefender) {
    $defenderState.Assessment = 'PRESERVED'
}
elseif ($defenderState.RealTimeProtectionEnabled -eq $false -and $defenderState.AMServiceEnabled -eq $false) {
    $defenderState.Assessment = 'OFF'
}
elseif ($defenderState.RealTimeProtectionEnabled -eq $false) {
    $defenderState.Assessment = 'REALTIME_OFF_ENGINE_RESIDENT'
}
elseif ($defenderState.RealTimeProtectionEnabled -eq $true) {
    $defenderState.Assessment = 'REALTIME_ON'
}

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

$updateServiceState = @($serviceCheck | Where-Object {
    $_.Name -in @('wuauserv','UsoSvc','DoSvc','WaaSMedicSvc')
})
$allUpdateServicesDisabled = (
    $updateServiceState.Count -gt 0 -and
    @($updateServiceState | Where-Object {
        $_.State -ne 'Stopped' -or $_.StartMode -ne 'Disabled'
    }).Count -eq 0
)
$windowsUpdateAssessment = if ($DryRun) {
    'DRY_RUN'
}
elseif ($KeepUpdates) {
    'PRESERVED_OR_RESTORED'
}
elseif ($Mode -eq 'Ultra' -and $allUpdateServicesDisabled) {
    'OFF_NOW_RECHECK_AFTER_REBOOT'
}
elseif ($Mode -eq 'Ultra') {
    'PARTIAL'
}
else {
    'AVAILABLE_NOTIFY_MODE'
}

Save-Snapshot 'after'
if (-not $DryRun) {
    $Changes | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $backupRoot 'changes.csv')
}

$result = [ordered]@{
    Timestamp       = (Get-Date).ToString('s')
    ScriptVersion   = $Version
    Windows         = $windowsFamily
    Caption         = $os.Caption
    DisplayVersion  = $displayVersion
    Build           = $build
    Edition         = $cv.EditionID
    CPU             = $cpu.Name
    RAM_GB          = $ramGB
    MemoryProfile   = $memoryProfile
    SystemDiskModel = $systemDiskModel
    SystemDiskType  = $systemDiskType
    SystemDiskBus   = $diskInfo.Bus
    DiskConfidence  = $diskInfo.Confidence
    GPU             = $gpuText
    BasicDisplayAdapter = $basicDisplayAdapter
    Laptop          = $isLaptop
    ChromeInstalled = $chromePresent
    ChromeWarmMode  = $chromeWarmMode
    SysMainProfile  = $sysMainProfile
    OriginalUserSID = $OriginalSid
    Mode            = $Mode
    KeepDefender    = [bool]$KeepDefender
    KeepUpdates     = [bool]$KeepUpdates
    RemoveOneDrive  = [bool]$RemoveOneDrive
    DisablePrinting = [bool]$DisablePrinting
    DryRun          = [bool]$DryRun
    WindowsUpdateAssessment = $windowsUpdateAssessment
    Defender        = $defenderState
    BackupFolder    = $backupRoot
}

if (-not $DryRun) {
    $result | ConvertTo-Json -Depth 5 |
        Set-Content -Encoding UTF8 -Path (Join-Path $backupRoot 'result.json')

    $serviceCheck |
        Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $backupRoot 'core-services-after.csv')
}

Write-Host ''
Write-Host '--- Core service state after optimization ---' -ForegroundColor Cyan
$serviceCheck | Format-Table -AutoSize

Write-Host ''
Write-Host '--- Defender verification ---' -ForegroundColor Cyan
$defenderState.GetEnumerator() | ForEach-Object {
    Write-Host ("{0,-28}: {1}" -f $_.Key, $_.Value)
}

Write-Host "Windows Update assessment: $windowsUpdateAssessment"
Write-Host "SysMain profile: $sysMainProfile"
Write-Host "Chrome warm mode: $chromeWarmMode"

if ($Mode -eq 'Ultra' -and -not $KeepDefender -and -not $DryRun) {
    if ($defenderState.RealTimeProtectionEnabled -eq $true -or $defenderState.AntivirusEnabled -eq $true) {
        Write-Warning 'Defender is still active. The most likely reason is Tamper Protection / protected Defender services.'
    }
    elseif ($defenderState.Available) {
        Write-Host 'Defender reports real-time protection disabled.' -ForegroundColor Green
    }
}

Write-Host ''
if ($DryRun) {
    Write-Host 'Dry run completed. No optimization changes were applied.' -ForegroundColor Green
}
else {
    Write-Host 'Completed. Restart Windows once.' -ForegroundColor Green
}
Write-Host "Log / snapshots: $backupRoot"
Write-Host ''
Write-Host 'DEFAULT Ultra keeps: Chrome networking, MicroSIP audio/network, VPN services, Firewall, BITS and page file.'
Write-Host ''
Write-Host 'Examples:'
Write-Host '  .\OfficeLiteOptimizer.ps1'
Write-Host '  .\OfficeLiteOptimizer.ps1 -Mode Safe'
Write-Host '  .\OfficeLiteOptimizer.ps1 -Mode Aggressive'
Write-Host '  .\OfficeLiteOptimizer.ps1 -Mode Ultra -KeepDefender -KeepUpdates'
Write-Host '  .\OfficeLiteOptimizer.ps1 -DryRun'

try { Stop-Transcript | Out-Null } catch {}

