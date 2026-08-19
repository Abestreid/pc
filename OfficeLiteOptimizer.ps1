#requires -version 5.1
[CmdletBinding()]
param(
  [switch]$KeepDefender,
  [switch]$KeepUpdates,
  [switch]$RemoveOneDrive,
  [switch]$DisablePrinting,
  [switch]$DryRun
)

$Version='3.2.1'
$SelfUrl='https://raw.githubusercontent.com/Abestreid/pc/main/OfficeLiteOptimizer.ps1'
$ErrorActionPreference='Continue'
$ProgressPreference='SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol=3072

function Test-Admin {
  $id=[Security.Principal.WindowsIdentity]::GetCurrent()
  $p=New-Object Security.Principal.WindowsPrincipal($id)
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if(-not (Test-Admin)){
  $sid=([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
  $origProfile=$env:USERPROFILE
  $s=''
  if($KeepDefender){$s+=' -KeepDefender'}
  if($KeepUpdates){$s+=' -KeepUpdates'}
  if($RemoveOneDrive){$s+=' -RemoveOneDrive'}
  if($DisablePrinting){$s+=' -DisablePrinting'}
  if($DryRun){$s+=' -DryRun'}
  $sid=$sid.Replace("'","''")
  $origProfile=$origProfile.Replace("'","''")
  $cmd=@"
[Net.ServicePointManager]::SecurityProtocol=3072
`$env:OFFICELITE_ORIGINAL_SID='$sid'
`$env:OFFICELITE_ORIGINAL_PROFILE='$origProfile'
`$code=(New-Object Net.WebClient).DownloadString('$SelfUrl')
`$sb=[ScriptBlock]::Create(`$code)
& `$sb $s
"@
  $enc=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
  $ps=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  try{
    Start-Process $ps -Verb RunAs -ArgumentList "-NoExit -NoProfile -ExecutionPolicy Bypass -EncodedCommand $enc" -ErrorAction Stop|Out-Null
    Write-Host 'Confirm UAC. Continue in the Administrator PowerShell window.' -ForegroundColor Yellow
  }catch{Write-Host ('UAC failed: '+$_.Exception.Message) -ForegroundColor Red}
  return
}

$OriginalSid=$env:OFFICELITE_ORIGINAL_SID
$OriginalProfile=$env:OFFICELITE_ORIGINAL_PROFILE
if([string]::IsNullOrWhiteSpace($OriginalSid)){$OriginalSid=([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value}
if([string]::IsNullOrWhiteSpace($OriginalProfile)){$OriginalProfile=$env:USERPROFILE}
$UserRoot="Registry::HKEY_USERS\$OriginalSid"
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$Root=Join-Path $env:ProgramData "OfficeLiteOptimizer\$stamp"
New-Item -ItemType Directory -Force -Path $Root|Out-Null
try{Start-Transcript -Path (Join-Path $Root 'optimizer.log') -Force|Out-Null}catch{}
$Changes=New-Object System.Collections.ArrayList

function Log([string]$status,[string]$text){
  $c=if($status -eq 'OK'){'Green'}elseif($status -eq 'PROTECTED'){'Yellow'}elseif($status -eq 'CRITICAL'){'Red'}else{'DarkGray'}
  Write-Host "[$status] $text" -ForegroundColor $c
  [void]$Changes.Add([pscustomobject]@{Time=(Get-Date).ToString('HH:mm:ss');Status=$status;Text=$text})
}
function Step([string]$text){Write-Host "`n==> $text" -ForegroundColor Cyan}
function Apply([string]$text,[scriptblock]$code){
  if($DryRun){Log 'SKIP' "DRY-RUN $text";return $false}
  try{&$code;Log 'OK' $text;return $true}catch{
    $m=$_.Exception.Message
    if($m -match 'Access is denied|Отказано в доступе|несанкционирован'){Log 'PROTECTED' $text}else{Log 'FAILED' "$text :: $m"}
    return $false
  }
}
function Reg([string]$path,[string]$name,$value,[string]$type='DWord'){
  Apply "REG $path\$name=$value" {
    if(-not(Test-Path $path)){New-Item -Path $path -Force -ErrorAction Stop|Out-Null}
    if($type -eq 'String'){New-ItemProperty -Path $path -Name $name -PropertyType String -Value ([string]$value) -Force -ErrorAction Stop|Out-Null}
    else{New-ItemProperty -Path $path -Name $name -PropertyType DWord -Value ([int]$value) -Force -ErrorAction Stop|Out-Null}
  }|Out-Null
}
function UReg([string]$sub,[string]$name,$value,[string]$type='DWord'){Reg "$UserRoot\$sub" $name $value $type}
function Svc([string]$name,[ValidateSet('Automatic','Manual','Disabled')][string]$mode,[switch]$Stop,[switch]$Start){
  if(-not(Get-Service $name -ErrorAction SilentlyContinue)){Log 'SKIP' "Service absent: $name";return}
  Apply "Service $name -> $mode" {
    if($Stop){Stop-Service $name -Force -ErrorAction SilentlyContinue}
    Set-Service $name -StartupType $mode -ErrorAction Stop
    if($Start){Start-Service $name -ErrorAction Stop}
  }|Out-Null
}
function HardSvc([string]$name){
  if(-not(Get-Service $name -ErrorAction SilentlyContinue)){Log 'SKIP' "Service absent: $name";return}
  Apply "Hard-disable $name" {
    Stop-Service $name -Force -ErrorAction SilentlyContinue
    $x=& sc.exe config $name start= disabled 2>&1
    if($LASTEXITCODE -ne 0){Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$name" -Name Start -Value 4 -ErrorAction Stop}
  }|Out-Null
}
function TaskOff([string]$path,[string]$name){
  if(-not(Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)){return}
  $t=Get-ScheduledTask -TaskPath $path -TaskName $name -ErrorAction SilentlyContinue
  if($t){Apply "Disable task $path$name" {Disable-ScheduledTask -InputObject $t -ErrorAction Stop|Out-Null}|Out-Null}
}
function TaskPathOff([string[]]$paths){
  if(-not(Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)){return}
  foreach($p in $paths){foreach($t in @(Get-ScheduledTask -TaskPath $p -ErrorAction SilentlyContinue)){TaskOff $t.TaskPath $t.TaskName}}
}
function RunRemove([string]$pattern){
  $p="$UserRoot\Software\Microsoft\Windows\CurrentVersion\Run"
  if(-not(Test-Path $p)){return}
  try{$props=(Get-ItemProperty $p -ErrorAction Stop).PSObject.Properties|Where-Object{$_.Name -notmatch '^PS' -and $_.Name -match $pattern}}catch{$props=@()}
  foreach($x in $props){Apply "Remove startup $($x.Name)" {Remove-ItemProperty $p $x.Name -ErrorAction Stop}|Out-Null}
}
function AppxOff([string]$name){
  if($DryRun){return}
  try{
    foreach($p in @(Get-AppxPackage -AllUsers -Name $name -ErrorAction SilentlyContinue)){
      try{Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction Stop;Log 'OK' "Removed AppX $($p.Name)"}catch{if($_.Exception.Message -match '0x80070002'){Log 'STALE' "Stale AppX $($p.Name)"}else{Log 'FAILED' "AppX $($p.Name)"}}
    }
    foreach($p in @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue|Where-Object{$_.DisplayName -like $name})){
      try{Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -AllUsers -ErrorAction Stop|Out-Null;Log 'OK' "Unprovisioned $($p.DisplayName)"}catch{Log 'FAILED' "Provisioned AppX $($p.DisplayName)"}
    }
  }catch{}
}
function Snapshot([string]$tag){
  try{Get-CimInstance Win32_Service|Select Name,DisplayName,State,StartMode|Sort Name|Export-Csv (Join-Path $Root "services-$tag.csv") -NoTypeInformation -Encoding UTF8}catch{}
  try{Get-CimInstance Win32_StartupCommand|Select Name,Command,Location,User|Export-Csv (Join-Path $Root "startup-$tag.csv") -NoTypeInformation -Encoding UTF8}catch{}
  try{Get-Process|Select ProcessName,Id,@{N='WorkingSetMB';E={[math]::Round($_.WorkingSet64/1MB,1)}}|Export-Csv (Join-Path $Root "processes-$tag.csv") -NoTypeInformation -Encoding UTF8}catch{}
  try{Get-AppxPackage -AllUsers|Select Name,PackageFullName|Export-Csv (Join-Path $Root "appx-$tag.csv") -NoTypeInformation -Encoding UTF8}catch{}
  try{if(Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue){Get-ScheduledTask|Select TaskPath,TaskName,State|Export-Csv (Join-Path $Root "tasks-$tag.csv") -NoTypeInformation -Encoding UTF8}}catch{}
  try{if(Get-Command Get-PnpDevice -ErrorAction SilentlyContinue){Get-PnpDevice|Where-Object{$_.Status -ne 'OK'}|Select Class,FriendlyName,InstanceId,Status|Export-Csv (Join-Path $Root "devices-problem-$tag.csv") -NoTypeInformation -Encoding UTF8}}catch{}
}
function DiskInfo{
  $r=[ordered]@{Model='Unknown';Type='Unknown';Bus='Unknown';Confidence='Low'}
  try{
    $pt=Get-Partition -DriveLetter $env:SystemDrive.TrimEnd(':') -ErrorAction Stop
    $d=Get-Disk -Number $pt.DiskNumber -ErrorAction Stop
    $r.Model=[string]$d.FriendlyName;$r.Bus=[string]$d.BusType
    if($r.Bus -match 'NVMe'){$r.Type='NVMe';$r.Confidence='High';return [pscustomobject]$r}
    $pd=Get-PhysicalDisk -ErrorAction SilentlyContinue|Where-Object{$_.FriendlyName -eq $d.FriendlyName}|Select-Object -First 1
    if($pd.MediaType -match 'SSD'){$r.Type='SSD';$r.Confidence='High';return [pscustomobject]$r}
    if($pd.MediaType -match 'HDD'){$r.Type='HDD';$r.Confidence='High';return [pscustomobject]$r}
  }catch{}
  if($r.Model -match '(?i)NVMe'){$r.Type='NVMe';$r.Confidence='Medium'}
  elseif($r.Model -match '(?i)SSD|Solid State'){$r.Type='SSD';$r.Confidence='Medium'}
  elseif($r.Model -match '(?i)^ST\d|Seagate|WDC|Western Digital|HGST|Hitachi|TOSHIBA|Samsung HD'){$r.Type='HDD';$r.Confidence='Medium'}
  [pscustomobject]$r
}
function ChromePresent{
  foreach($p in @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe","${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe","$OriginalProfile\AppData\Local\Google\Chrome\Application\chrome.exe")){if($p -and(Test-Path $p)){return $true}}
  return $false
}

Step 'Detect system'
$os=Get-CimInstance Win32_OperatingSystem
$cs=Get-CimInstance Win32_ComputerSystem
$cpu=Get-CimInstance Win32_Processor|Select-Object -First 1
$cv=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$build=[int]$os.BuildNumber
$family=if($build -ge 22000){'Windows 11'}else{'Windows 10'}
$display=if($cv.DisplayVersion){$cv.DisplayVersion}elseif($cv.ReleaseId){$cv.ReleaseId}else{$os.Version}
$ram=[math]::Round($cs.TotalPhysicalMemory/1GB,1)
$laptop=[bool](Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
$disk=DiskInfo
$chrome=ChromePresent
$gpus=@(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)
$gpuName=if($gpus){$gpus.Name -join ' | '}else{'Unknown'}
$basicGpu=[bool]($gpus|Where-Object{$_.Name -match '(?i)Microsoft Basic Display|Базовый видеоадаптер'}|Select-Object -First 1)
$memProfile=if($ram -le 4){'LOW_MEMORY'}elseif($ram -lt 8){'BALANCED'}else{'WARM_BROWSER'}
Write-Host "OfficeLiteOptimizer v$Version"
Write-Host "$family $display build $build | $($cv.EditionID)"
Write-Host "CPU: $($cpu.Name)"
Write-Host "RAM: $ram GB [$memProfile]"
Write-Host "Disk: $($disk.Model) [$($disk.Type)/$($disk.Bus), $($disk.Confidence)]"
Write-Host "GPU: $gpuName"
Write-Host "Chrome: $chrome | Laptop: $laptop"
if($basicGpu){Log 'CRITICAL' 'Microsoft Basic Display Adapter detected - install the proper GPU driver'}
Snapshot 'before'
try{&reg.exe export 'HKLM\SOFTWARE\Policies\Microsoft' (Join-Path $Root 'HKLM-Policies-Microsoft.reg') /y|Out-Null}catch{}
try{Checkpoint-Computer -Description "OfficeLiteOptimizer $stamp" -RestorePointType MODIFY_SETTINGS -ErrorAction Stop;Log 'OK' 'Restore point created'}catch{Log 'SKIP' 'System Restore unavailable'}

Step 'Privacy and background services'
Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0
Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'DoNotShowFeedbackNotifications' 1
Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1
Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableActivityFeed' 0
Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'PublishUserActivities' 0
Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'UploadUserActivities' 0
Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'AllowCortana' 0
Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0
UReg 'Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 1
UReg 'System\GameConfigStore' 'GameDVR_Enabled' 0
foreach($n in @('DiagTrack','dmwappushservice','MapsBroker','RetailDemo','WMPNetworkSvc','XblAuthManager','XblGameSave','XboxNetApiSvc','Fax','PhoneSvc','RemoteRegistry','wisvc','WalletService','SSDPSRV','upnphost','WerSvc','DPS','WdiServiceHost','WdiSystemHost','CDPSvc','NcdAutoSetup','icssvc','PushToInstall','InstallService','WpnService','DusmSvc','TrkWks')){Svc $n Disabled -Stop}
foreach($n in @('CDPUserSvc','WpnUserService','OneSyncSvc')){$k="HKLM:\SYSTEM\CurrentControlSet\Services\$n";if(Test-Path $k){Reg $k 'Start' 4}}
if(-not $laptop){Svc 'lfsvc' Disabled -Stop}
Svc 'BITS' Manual

Step 'Hardware-adaptive services'
$hwOk=$false
try{$dev=@(Get-PnpDevice -PresentOnly -ErrorAction Stop);$hwOk=$true}catch{$dev=@()}
if($hwOk){
  $bt=[bool]($dev|Where-Object{$_.Class -match 'Bluetooth' -or $_.FriendlyName -match '(?i)Bluetooth'}|Select-Object -First 1)
  $cam=[bool]($dev|Where-Object{$_.Class -match 'Camera|Image' -or $_.FriendlyName -match '(?i)camera|webcam|камера'}|Select-Object -First 1)
  $bio=[bool]($dev|Where-Object{$_.Class -match 'Biometric' -or $_.FriendlyName -match '(?i)fingerprint|biometric|отпечат'}|Select-Object -First 1)
  $touch=[bool]($dev|Where-Object{$_.FriendlyName -match '(?i)touch screen|touchscreen|pen|сенсорн|перо'}|Select-Object -First 1)
  if(-not $bt){foreach($n in @('bthserv','BTAGService','BthAvctpSvc')){Svc $n Disabled -Stop}}
  if(-not $cam){foreach($n in @('FrameServer','FrameServerMonitor')){Svc $n Disabled -Stop}}
  if(-not $bio){Svc 'WbioSrvc' Disabled -Stop}
  if(-not $touch -and -not $laptop){Svc 'TabletInputService' Disabled -Stop}
}

Step 'Chrome and primary workload'
Reg 'HKLM:\SOFTWARE\Policies\Google\Chrome' 'HighEfficiencyModeEnabled' 1
if($chrome -and $ram -ge 8){Reg 'HKLM:\SOFTWARE\Policies\Google\Chrome' 'BackgroundModeEnabled' 1;$chromeWarm=$true}
else{Reg 'HKLM:\SOFTWARE\Policies\Google\Chrome' 'BackgroundModeEnabled' 0;RunRemove '^GoogleChromeAutoLaunch';$chromeWarm=$false}

Step 'Printing'
$printerKnown=$false;$printers=@()
try{if(Get-Command Get-Printer -ErrorAction SilentlyContinue){$printers=@(Get-Printer -ErrorAction Stop|Where-Object{$_.Name -notmatch 'Microsoft Print to PDF|Microsoft XPS|OneNote|Fax'});$printerKnown=$true}else{$printers=@(Get-CimInstance Win32_Printer -ErrorAction Stop|Where-Object{$_.Name -notmatch 'Microsoft Print to PDF|Microsoft XPS|OneNote|Fax'});$printerKnown=$true}}catch{}
if($DisablePrinting){Svc 'Spooler' Disabled -Stop}elseif($printerKnown -and $printers.Count -eq 0){Svc 'Spooler' Manual -Stop}else{Log 'SKIP' 'Spooler preserved'}

Step 'Search and SysMain'
Svc 'WSearch' Disabled -Stop
if($ram -le 4){Svc 'SysMain' Disabled -Stop;$sys='DISABLED_LOW_MEMORY'}
elseif($ram -ge 8){Svc 'SysMain' Automatic -Start;$sys='AUTOMATIC_8GB_PLUS'}
elseif($disk.Type -match 'SSD|NVMe'){Svc 'SysMain' Automatic -Start;$sys='AUTOMATIC_BALANCED_SSD'}
else{Svc 'SysMain' Manual -Stop;$sys='MANUAL_BALANCED_HDD_OR_UNKNOWN'}
if($disk.Type -eq 'HDD'){TaskOff '\Microsoft\Windows\Defrag\' 'ScheduledDefrag'}
if($ram -le 4){Apply 'Enable system-managed page file' {$x=Get-CimInstance Win32_ComputerSystem;Set-CimInstance -InputObject $x -Property @{AutomaticManagedPagefile=$true} -ErrorAction Stop|Out-Null}|Out-Null}

Step 'OneDrive and Edge'
Stop-Process OneDrive -Force -ErrorAction SilentlyContinue
Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableFileSyncNGSC' 1
RunRemove '^OneDrive$'
if($RemoveOneDrive){$u=@("$env:SystemRoot\SysWOW64\OneDriveSetup.exe","$env:SystemRoot\System32\OneDriveSetup.exe")|Where-Object{Test-Path $_}|Select-Object -First 1;if($u){Apply 'Uninstall OneDrive' {Start-Process $u '/uninstall' -Wait -NoNewWindow -ErrorAction Stop}|Out-Null}}
Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'StartupBoostEnabled' 0
Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'BackgroundModeEnabled' 0
Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'LaunchEdgeOnWindowsStartupEnabled' 0
Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'SmartScreenEnabled' 0
RunRemove '^MicrosoftEdgeAutoLaunch'
foreach($n in @('edgeupdate','edgeupdatem','MicrosoftEdgeElevationService')){Svc $n Disabled -Stop}
try{Get-ScheduledTask -ErrorAction SilentlyContinue|Where-Object{$_.TaskName -like 'MicrosoftEdgeUpdateTaskMachine*'}|ForEach-Object{TaskOff $_.TaskPath $_.TaskName}}catch{}
Reg 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' 'AutoDownload' 2

Step 'Windows Update'
if(-not $KeepUpdates){
  $wu='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
  Reg "$wu\AU" 'NoAutoUpdate' 1
  Reg "$wu\AU" 'AUOptions' 2
  Reg "$wu\AU" 'NoAutoRebootWithLoggedOnUsers' 1
  Reg $wu 'DisableWindowsUpdateAccess' 1
  Reg $wu 'SetDisableUXWUAccess' 1
  Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 0
  foreach($n in @('wuauserv','UsoSvc','DoSvc','WaaSMedicSvc','uhssvc')){HardSvc $n}
  TaskPathOff @('\Microsoft\Windows\WindowsUpdate\','\Microsoft\Windows\UpdateOrchestrator\','\Microsoft\Windows\WaaSMedic\')
  Svc 'TrustedInstaller' Manual
}else{Log 'SKIP' 'Windows Update preserved'}

Step 'Microsoft Defender'
$tamper=$null
try{$m=Get-MpComputerStatus -ErrorAction Stop;$tamper=$m.IsTamperProtected}catch{}
if(-not $KeepDefender){
  if(Get-Command Set-MpPreference -ErrorAction SilentlyContinue){
    foreach($c in @(
      {Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction Stop},
      {Set-MpPreference -DisableBehaviorMonitoring $true -ErrorAction Stop},
      {Set-MpPreference -DisableScriptScanning $true -ErrorAction Stop},
      {Set-MpPreference -DisableIOAVProtection $true -ErrorAction Stop},
      {Set-MpPreference -DisableArchiveScanning $true -ErrorAction Stop},
      {Set-MpPreference -DisableRemovableDriveScanning $true -ErrorAction Stop}
    )){Apply 'Apply Defender reduction setting' $c|Out-Null}
  }
  Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' 'DisableAntiSpyware' 1
  Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' 'DisableAntiVirus' 1
  Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection' 'DisableRealtimeMonitoring' 1
  Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection' 'DisableBehaviorMonitoring' 1
  Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableSmartScreen' 0
  TaskPathOff @('\Microsoft\Windows\Windows Defender\')
  foreach($n in @('WinDefend','WdNisSvc','MDCoreSvc','Sense','SecurityHealthService')){HardSvc $n}
}else{Log 'SKIP' 'Defender preserved'}

Step 'Telemetry tasks and AppX'
foreach($t in @(
  @('\Microsoft\Windows\Application Experience\','Microsoft Compatibility Appraiser'),
  @('\Microsoft\Windows\Application Experience\','ProgramDataUpdater'),
  @('\Microsoft\Windows\Customer Experience Improvement Program\','Consolidator'),
  @('\Microsoft\Windows\Customer Experience Improvement Program\','UsbCeip'),
  @('\Microsoft\Windows\Feedback\Siuf\','DmClient'),
  @('\Microsoft\Windows\Maps\','MapsUpdateTask')
)){TaskOff $t[0] $t[1]}
foreach($a in @('Clipchamp.Clipchamp','Microsoft.549981C3F5F10','Microsoft.BingNews','Microsoft.BingWeather','Microsoft.BingSearch','Microsoft.GetHelp','Microsoft.Getstarted','Microsoft.MicrosoftOfficeHub','Microsoft.MicrosoftSolitaireCollection','Microsoft.MixedReality.Portal','Microsoft.People','Microsoft.SkypeApp','Microsoft.Windows.DevHome','Microsoft.WindowsFeedbackHub','Microsoft.WindowsMaps','Microsoft.WindowsAlarms','Microsoft.Xbox.TCUI','Microsoft.XboxApp','Microsoft.XboxGameOverlay','Microsoft.XboxGamingOverlay','Microsoft.XboxIdentityProvider','Microsoft.XboxSpeechToTextOverlay','Microsoft.YourPhone','Microsoft.ZuneMusic','Microsoft.ZuneVideo','MicrosoftTeams','MSTeams','Microsoft.OutlookForWindows','MicrosoftWindows.CrossDevice')){AppxOff $a}

Step 'Visual effects'
UReg 'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 0
UReg 'Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 2
UReg 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAnimations' 0
UReg 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ListviewAlphaSelect' 0
UReg 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ListviewShadow' 0
UReg 'Software\Microsoft\Windows\DWM' 'EnableAeroPeek' 0
UReg 'Control Panel\Desktop\WindowMetrics' 'MinAnimate' '0' 'String'
UReg 'Control Panel\Desktop' 'DragFullWindows' '0' 'String'
UReg 'Control Panel\Desktop' 'MenuShowDelay' '20' 'String'
UReg 'Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize' 'StartupDelayInMSec' 0

Step 'Cleanup and verify'
$temp=Join-Path $OriginalProfile 'AppData\Local\Temp'
if(Test-Path $temp){Apply 'Clean user TEMP' {Get-ChildItem $temp -Force -ErrorAction SilentlyContinue|Remove-Item -Recurse -Force -ErrorAction SilentlyContinue}|Out-Null}
Snapshot 'after'
$Changes|Export-Csv (Join-Path $Root 'changes.csv') -NoTypeInformation -Encoding UTF8

$uState=@()
foreach($n in @('wuauserv','UsoSvc','DoSvc','WaaSMedicSvc')){$x=Get-CimInstance Win32_Service -Filter "Name='$n'" -ErrorAction SilentlyContinue;if($x){$uState+=$x}}
$uOff=($uState.Count -gt 0 -and @($uState|Where-Object{$_.State -ne 'Stopped' -or $_.StartMode -ne 'Disabled'}).Count -eq 0)
$uAssess=if($KeepUpdates){'PRESERVED'}elseif($uOff){'OFF_NOW_RECHECK_AFTER_REBOOT'}else{'PARTIAL'}
$d=[ordered]@{Available=$false;TamperProtected=$tamper;AntivirusEnabled=$null;RealTimeProtectionEnabled=$null;AMServiceEnabled=$null;Assessment='UNKNOWN'}
try{$m=Get-MpComputerStatus -ErrorAction Stop;$d.Available=$true;$d.TamperProtected=$m.IsTamperProtected;$d.AntivirusEnabled=$m.AntivirusEnabled;$d.RealTimeProtectionEnabled=$m.RealTimeProtectionEnabled;$d.AMServiceEnabled=$m.AMServiceEnabled}catch{}
if($KeepDefender){$d.Assessment='PRESERVED'}elseif($d.RealTimeProtectionEnabled -eq $false -and $d.AMServiceEnabled -eq $false){$d.Assessment='OFF'}elseif($d.RealTimeProtectionEnabled -eq $false){$d.Assessment='REALTIME_OFF_ENGINE_RESIDENT'}elseif($d.RealTimeProtectionEnabled -eq $true){$d.Assessment='REALTIME_ON'}
$result=[ordered]@{Timestamp=(Get-Date).ToString('s');ScriptVersion=$Version;Windows=$family;Caption=$os.Caption;DisplayVersion=$display;Build=$build;Edition=$cv.EditionID;CPU=$cpu.Name;RAM_GB=$ram;MemoryProfile=$memProfile;SystemDiskModel=$disk.Model;SystemDiskType=$disk.Type;SystemDiskBus=$disk.Bus;GPU=$gpuName;BasicDisplayAdapter=$basicGpu;Laptop=$laptop;ChromeInstalled=$chrome;ChromeWarmMode=$chromeWarm;SysMainProfile=$sys;OriginalUserSID=$OriginalSid;WindowsUpdateAssessment=$uAssess;Defender=$d;BackupFolder=$Root}
$result|ConvertTo-Json -Depth 5|Set-Content (Join-Path $Root 'result.json') -Encoding UTF8
Write-Host "`nWindows Update: $uAssess"
Write-Host "Defender: $($d.Assessment)"
Write-Host "SysMain: $sys"
Write-Host "Chrome warm: $chromeWarm"
if($basicGpu){Log 'CRITICAL' 'Proper GPU driver is required'}
Write-Host "`nCompleted. Restart Windows once. Logs: $Root" -ForegroundColor Green
try{Stop-Transcript|Out-Null}catch{}
