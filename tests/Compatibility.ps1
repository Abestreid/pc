param([string]$ScriptPath, [string]$OutputRoot, [switch]$Upload)
$ErrorActionPreference='Stop'
function Get-WmiObject {
    param($Class,$Namespace,$ErrorAction)
    if($Class -eq 'Win32_Processor'){ New-Object PSObject -Property @{Name='Intel(R) Core(TM) i5-8500';Manufacturer='Intel';NumberOfCores=6;NumberOfLogicalProcessors=6;MaxClockSpeed=3000} }
    if($Class -eq 'Win32_PhysicalMemory'){ New-Object PSObject -Property @{Capacity=8GB;SMBIOSMemoryType=0;MemoryType=24;DeviceLocator='DIMM0';Manufacturer='Test';Speed=1600;ConfiguredClockSpeed=1600;PartNumber='TEST'} }
    if($Class -eq 'Win32_SystemEnclosure'){ New-Object PSObject -Property @{ChassisTypes=@(15)} }
    if($Class -eq 'Win32_DiskDrive'){ New-Object PSObject -Property @{Model='TEST SSD';Size=120GB;Index=0;SerialNumber='TEST'} }
    if($Class -eq 'SoftwareLicensingProduct'){ New-Object PSObject -Property @{Name='Windows 7';PartialProductKey='TEST';LicenseStatus=1} }
}
function Get-WinEvent {}
function Get-Command {
    param($Name,$ErrorAction)
    if($Name -like 'smartctl*' -or $Name -eq 'Get-CimInstance' -or $Name -eq 'Get-PhysicalDisk' -or $Name -eq 'Get-Disk'){return $null}
    Microsoft.PowerShell.Core\Get-Command $Name -ErrorAction SilentlyContinue
}
$env:COMPUTERNAME='TEST-WIN7-PS2'
if($Upload){ & $ScriptPath -OutputDirectory $OutputRoot }
else { & $ScriptPath -OutputDirectory $OutputRoot -SkipUpload }
if($Upload){
    $urlFile=Get-ChildItem -Path $OutputRoot -Filter report-url.txt -Recurse | Select-Object -First 1
    if(-not $urlFile){throw 'Upload did not return a report URL'}
    $url=([IO.File]::ReadAllText($urlFile.FullName)).Trim()
    $request=New-Object -ComObject WinHttp.WinHttpRequest.5.1
    try { $request.Option(9)=2048 } catch {}
    $request.Open('GET',$url+'&action=download',$false)
    $request.Send()
    if($request.Status -ne 200){throw 'Download failed'}
    $download=Join-Path $OutputRoot 'download-check.zip'
    [IO.File]::WriteAllBytes($download,$request.ResponseBody)
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($request)
    $zip=Get-ChildItem -Path $OutputRoot -Filter 'TEST-WIN7-PS2-*.zip' | Select-Object -First 1
    if([PcInventoryPortable]::Sha256($zip.FullName) -ne [PcInventoryPortable]::Sha256($download)){throw 'Downloaded ZIP mismatch'}
}
'PASS: PowerShell '+$PSVersionTable.PSVersion.ToString()+'; CLR '+$PSVersionTable.CLRVersion.ToString()+'; WMI fixtures; upload='+$Upload
