#requires -Version 5.1
<#
.SYNOPSIS
  Inventory of Windows 10/11 computers before resale.
.DESCRIPTION
  Read-only hardware inventory. Exports TXT, JSON, CSV, manual checklist,
  and raw SMART logs when smartctl is already installed.
  No settings, activation, drivers, or disks are modified.
#>
[CmdletBinding()]
param([string]$OutputDirectory)

$ErrorActionPreference = 'Stop'
function Cim([string]$Name, [string]$Namespace = 'root/cimv2') {
    try { @(Get-CimInstance -ClassName $Name -Namespace $Namespace -ErrorAction Stop) }
    catch { @() }
}
function GB($Bytes) {
    if ($null -eq $Bytes -or [double]$Bytes -le 0) { return $null }
    [math]::Round(([double]$Bytes / 1GB), 1)
}
function DDR($Smbios, $Legacy) {
    $code = [int]$Smbios
    if ($code -eq 0 -or $code -eq 2) { $code = [int]$Legacy }
    switch ($code) {
        20 {'DDR'} 21 {'DDR2'} 24 {'DDR3'} 26 {'DDR4'}
        27 {'LPDDR'} 28 {'LPDDR2'} 29 {'LPDDR3'} 30 {'LPDDR4'}
        34 {'DDR5'} 35 {'LPDDR5'} 37 {'LPDDR5X'}
        default {'Не определено'}
    }
}
function Chassis($Types) {
    foreach ($n in @($Types)) {
        switch ([int]$n) {
            3 {return 'Desktop'} 4 {return 'Low Profile Desktop'}
            6 {return 'Mini Tower'} 7 {return 'Tower'}
            9 {return 'Laptop'} 10 {return 'Notebook'}
            13 {return 'All-in-One'} 15 {return 'Space Saving / SFF (предположительно)'}
            16 {return 'Компактный корпус'} 23 {return 'Rack Mount'}
            35 {return 'Mini PC'} 36 {return 'Stick PC'}
        }
    }
    'Не определено'
}
function Reliability($Physical) {
    if (-not $Physical -or -not (Get-Command Get-StorageReliabilityCounter -ErrorAction SilentlyContinue)) {
        return $null
    }
    try {
        $v = $Physical | Get-StorageReliabilityCounter -ErrorAction Stop
        if (-not $v) { return $null }
        [pscustomobject]@{
            TemperatureC = $v.Temperature
            WearPercentConsumed = $v.Wear
            PowerOnHours = $v.PowerOnHours
            ReadErrorsTotal = $v.ReadErrorsTotal
            ReadErrorsUncorrected = $v.ReadErrorsUncorrected
            WriteErrorsTotal = $v.WriteErrorsTotal
            WriteErrorsUncorrected = $v.WriteErrorsUncorrected
        }
    } catch { return $null }
}
function PhysicalFor($Disk, $Candidates) {
    $serial = ([string]$Disk.SerialNumber).Trim() -replace '\s',''
    if ($serial) {
        $found = @($Candidates | Where-Object {
            (([string]$_.SerialNumber).Trim() -replace '\s','') -eq $serial
        })
        if ($found.Count -eq 1) { return $found[0] }
    }
    $found = @($Candidates | Where-Object {
        ([string]$_.FriendlyName).Trim() -eq ([string]$Disk.Model).Trim()
    })
    if ($found.Count -eq 1) { return $found[0] }
    $null
}

if ($PSVersionTable.PSEdition -eq 'Core') {
    if (-not [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
        [Runtime.InteropServices.OSPlatform]::Windows)) {
        throw 'Скрипт работает только на Windows.'
    }
}
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $base = [Environment]::GetFolderPath('Desktop')
    if (-not $base -or -not (Test-Path -LiteralPath $base)) {
        $base = [Environment]::GetFolderPath('MyDocuments')
    }
    $OutputDirectory = Join-Path $base 'PC-Sale-Inventory'
}
$hostName = $env:COMPUTERNAME -replace '[^A-Za-z0-9_.-]','_'
$folder = Join-Path $OutputDirectory ("{0}-{1}" -f $hostName,(Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $folder | Out-Null
$warnings = New-Object 'System.Collections.Generic.List[string]'
$admin = $false
try {
    $principal = [Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent())
    $admin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch {}

Write-Host 'Проверяю конфигурацию компьютера (только чтение)...' -ForegroundColor Cyan
$rawCPU = @(Cim 'Win32_Processor')
$rawRAM = @(Cim 'Win32_PhysicalMemory')
$rawDisks = @(Cim 'Win32_DiskDrive')
$rawGPU = @(Cim 'Win32_VideoController')
$rawBoard = @(Cim 'Win32_BaseBoard')
$rawCase = @(Cim 'Win32_SystemEnclosure')
$rawComputer = @(Cim 'Win32_ComputerSystem')
$rawOS = @(Cim 'Win32_OperatingSystem')
$rawNet = @(Cim 'Win32_NetworkAdapter')
$rawPnP = @(Cim 'Win32_PnPEntity')

$cpu = @($rawCPU | ForEach-Object {
    $model = ([string]$_.Name -replace '\s+',' ').Trim()
    $generation = 'Не определено'
    if ($model -match 'Intel\(R\).*?Core\(TM\).*?i[3579]-(\d{4,5})') {
        $digits = $Matches[1]
        if ($digits.Length -eq 4) { $generation = $digits.Substring(0,1) + '-е Intel Core (по названию)' }
        elseif ($digits.Length -eq 5) { $generation = $digits.Substring(0,2) + '-е Intel Core (по названию)' }
    }
    [pscustomobject]@{
        Manufacturer = $_.Manufacturer; Model = $model; Generation = $generation
        Cores = $_.NumberOfCores; Threads = $_.NumberOfLogicalProcessors
        MaxClockMHz = $_.MaxClockSpeed
    }
})
$modules = @($rawRAM | Where-Object { $_.Capacity -gt 0 } | ForEach-Object {
    [pscustomobject]@{
        Slot = $_.DeviceLocator; Manufacturer = $_.Manufacturer
        CapacityGB = (GB $_.Capacity); Type = (DDR $_.SMBIOSMemoryType $_.MemoryType)
        RatedSpeedMHz = $_.Speed; ConfiguredSpeedMHz = $_.ConfiguredClockSpeed
        PartNumber = ([string]$_.PartNumber).Trim()
    }
})
$ramGB = 0.0
foreach ($m in $modules) { $ramGB += $m.CapacityGB }
$ramGB = [math]::Round($ramGB,1)
if ($modules.Count -eq 0 -and $rawComputer.Count) {
    $ramGB = GB $rawComputer[0].TotalPhysicalMemory
    $warnings.Add('Данные о планках RAM недоступны; общий объём получен из Windows.')
}
$ramTypes = @($modules | Select-Object -ExpandProperty Type -Unique)
$ramType = if ($ramTypes.Count -eq 1) { $ramTypes[0] } else { 'Не определено / смешано' }

$physical = @()
try {
    if (Get-Command Get-PhysicalDisk -ErrorAction SilentlyContinue) {
        $physical = @(Get-PhysicalDisk -ErrorAction Stop)
    }
} catch { $warnings.Add('Get-PhysicalDisk недоступен.') }
$winDisks = @()
try {
    if (Get-Command Get-Disk -ErrorAction SilentlyContinue) {
        $winDisks = @(Get-Disk -ErrorAction Stop)
    }
} catch {}
$smartctl = Get-Command smartctl.exe -ErrorAction SilentlyContinue
if (-not $smartctl) { $smartctl = Get-Command smartctl -ErrorAction SilentlyContinue }
$drives = @($rawDisks | ForEach-Object {
    $d = $_
    $phys = PhysicalFor $d $physical
    $wd = @($winDisks | Where-Object { $_.Number -eq $d.Index } | Select-Object -First 1)
    $bus = 'Не определено'
    if ($wd.Count -and [string]$wd[0].BusType -ne 'Unknown') {
        $bus = [string]$wd[0].BusType
    } elseif ($phys) { $bus = [string]$phys.BusType }
    $type = 'Не определено'
    if ($phys -and [string]$phys.MediaType -in @('SSD','HDD')) {
        $type = [string]$phys.MediaType
    } elseif ($d.Model -match 'SSD|Solid State|NVMe') {
        $type = 'SSD (по модели, проверить)'
    }
    $smartFile = $null
    if ($smartctl) {
        $smartFile = "smartctl-disk-$($d.Index).txt"
        try {
            $smartText = & $smartctl.Source -a "/dev/pd$($d.Index)" 2>&1 | Out-String
            $smartText | Out-File -LiteralPath (Join-Path $folder $smartFile) -Encoding UTF8
        } catch {
            "Ошибка чтения SMART: $($_.Exception.Message)" |
                Out-File -LiteralPath (Join-Path $folder $smartFile) -Encoding UTF8
        }
    }
    [pscustomobject]@{
        Number = $d.Index; Model = ([string]$d.Model).Trim()
        CapacityGB = (GB $d.Size); MediaType = $type; BusType = $bus
        WindowsHealth = $(if ($phys) { [string]$phys.HealthStatus } else { 'Не определено' })
        StorageReliabilityCounters = (Reliability $phys)
        SmartctlRawFile = $smartFile
        SmartNote = 'Windows Healthy не означает SMART OK. Сверить атрибуты и ошибки вручную.'
    }
})
if (-not $smartctl) {
    $warnings.Add('smartctl не найден: полноценный SMART и ресурс SSD могут быть недоступны.')
}
if (-not $admin) {
    $warnings.Add('Нет прав администратора: часть SMART-диагностики может быть недоступна.')
}
if (-not $cpu.Count) { $warnings.Add('Не удалось прочитать процессор.') }
if (-not $drives.Count) { $warnings.Add('Не удалось прочитать накопители.') }

$gpu = @($rawGPU | ForEach-Object {
    $kind = 'Не определено'
    if ($_.Name -match 'Intel.*(HD|UHD|Iris|Graphics)|AMD Radeon\(TM\) Graphics') {
        $kind = 'Предположительно встроенная'
    } elseif ($_.Name -match 'NVIDIA|GeForce|Quadro|RTX|GTX|Radeon RX|Radeon Pro') {
        $kind = 'Предположительно дискретная'
    }
    [pscustomobject]@{
        Model = $_.Name; Type = $kind
        AdapterRAM_GB_Unreliable = (GB $_.AdapterRAM)
        Note = 'WMI VRAM может быть ошибочным (особенно 4+ ГБ).'
    }
})
$board = if ($rawBoard.Count) {
    [pscustomobject]@{ Manufacturer=$rawBoard[0].Manufacturer; Model=$rawBoard[0].Product }
} else { [pscustomobject]@{ Manufacturer='Не определено'; Model='Не определено' } }
$chipsetClues = @($rawPnP | Where-Object {
    $_.Name -match 'Chipset Family|LPC Controller|SMBus Controller|Host Bridge'
} | Select-Object -First 12 -ExpandProperty Name)
$case = if ($rawCase.Count) { Chassis $rawCase[0].ChassisTypes } else { 'Не определено' }
$oem = if ($rawComputer.Count) {
    [pscustomobject]@{ Manufacturer=$rawComputer[0].Manufacturer; Model=$rawComputer[0].Model }
} else { [pscustomobject]@{ Manufacturer='Не определено'; Model='Не определено' } }
$os = if ($rawOS.Count) {
    [pscustomobject]@{
        Name=$rawOS[0].Caption; Version=$rawOS[0].Version
        Build=$rawOS[0].BuildNumber; Architecture=$rawOS[0].OSArchitecture
    }
} else { [pscustomobject]@{ Name='Не определено'; Version=''; Build=''; Architecture='' } }
$activation = 'Не удалось проверить'
try {
    $licensed = @(Get-CimInstance Win32_SoftwareLicensingProduct -ErrorAction Stop |
        Where-Object { $_.Name -like 'Windows*' -and $_.PartialProductKey })
    if (@($licensed | Where-Object { $_.LicenseStatus -eq 1 }).Count) {
        $activation = 'Активирована на момент проверки'
    } elseif ($licensed.Count) {
        $activation = 'Активация не подтверждена'
    }
} catch { $warnings.Add('Статус лицензирования Windows недоступен.') }

$network = @($rawNet | Where-Object { $_.PhysicalAdapter -and $_.Name } | ForEach-Object {
    [pscustomobject]@{
        Name=$_.Name; Connection=$_.NetConnectionID
        ConnectedNow=($_.NetConnectionStatus -eq 2)
    }
})
$wifi = @($network | Where-Object { $_.Name -match 'Wi-Fi|Wireless|WLAN|802\.11' })
$bluetooth = @($rawPnP | Where-Object {
    $_.Name -match 'Bluetooth' -and $_.Name -notmatch '^Microsoft Bluetooth Enumerator$'
} | Select-Object -First 10 -ExpandProperty Name)
$usbControllers = @((Cim 'Win32_USBController') | Select-Object -ExpandProperty Name -Unique)
$diskEvents = @()
try {
    $diskEvents = @(Get-WinEvent -FilterHashtable @{
        LogName='System'; StartTime=(Get-Date).AddDays(-30); Id=@(7,51,55,129,153,157)
    } -MaxEvents 120 -ErrorAction Stop | Where-Object {
        $_.ProviderName -match 'disk|stor|ntfs|nvme'
    } | Select-Object -First 25 | ForEach-Object {
        [pscustomobject]@{
            Time=$_.TimeCreated.ToString('yyyy-MM-dd HH:mm')
            Source=$_.ProviderName; EventID=$_.Id
            Message=([string]$_.Message -replace '\s+',' ').Trim()
        }
    })
} catch {}

$manual = @(
    'БП: осмотреть наклейку, записать бренд, модель, мощность в ваттах',
    'Корпус: проверить бренд, модель, Mini Tower/SFF/Mini PC',
    'Порты: физически пересчитать и проверить HDMI, DP, VGA, USB-A/C, Ethernet',
    'Работа: проверить запуск, изображение, LAN/Wi-Fi, звук, USB, вентиляторы',
    'Шум и перегрев: выполнить отдельный тест под нагрузкой с контролем температур',
    'Дефекты: осмотреть корпус, кнопки, разъёмы и внутренности',
    'Комплект: отметить системный блок, питание, монитор, клавиатуру, мышь',
    'Фотографии: общий вид, передняя/задняя панель, внутри, дефекты',
    'SMART: проверить Reallocated/Pending/Uncorrectable; SSD wear/spare/used',
    'Перед продажей: сохранить данные, очистить диск и проверить лицензию Windows'
)
$report = [ordered]@{
    Version='1.0'; CollectedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz')
    ComputerName=$env:COMPUTERNAME; Administrator=$admin
    CPU=$cpu
    RAM=[pscustomobject]@{TotalGB=$ramGB; Type=$ramType; SlotsUsed=$modules.Count; Modules=$modules}
    Drives=$drives; GPU=$gpu
    Motherboard=$board; ChipsetCluesUnverified=$chipsetClues
    OEM=$oem; ChassisFromSMBIOS=$case
    PowerSupply='Не определяется программно: ручной осмотр'
    Connections=[pscustomobject]@{
        NetworkAdapters=$network; WiFiDetected=($wifi.Count -gt 0)
        BluetoothDevicesUnverified=$bluetooth; USBControllers=$usbControllers
        PhysicalPortCounts='Требуют ручного осмотра'
    }
    Windows=$os; Activation=$activation; PossibleDiskEventsLast30DaysLimited=$diskEvents
    ManualChecklist=$manual; Warnings=@($warnings)
}
$cpuTitle = if ($cpu.Count) { $cpu[0].Model } else { 'CPU не определён' }
$ssd = @($drives | Where-Object { $_.MediaType -like 'SSD*' } | Select-Object -First 1)
$ssdTitle = if ($ssd.Count) { "SSD $($ssd[0].CapacityGB) ГБ" } else { 'накопитель уточнить' }
$title = "ПК $cpuTitle, RAM $ramGB ГБ, $ssdTitle"
$txt = New-Object 'System.Collections.Generic.List[string]'
$txt.Add('ИНВЕНТАРИЗАЦИЯ ПК ДЛЯ ПРОДАЖИ')
$txt.Add("Компьютер: $env:COMPUTERNAME | $($report.CollectedAt)")
$txt.Add("ЧЕРНОВИК ЗАГОЛОВКА: $title")
$txt.Add('')
$txt.Add('ПРОЦЕССОР:')
foreach ($x in $cpu) { $txt.Add(" - $($x.Model), $($x.Cores) ядер / $($x.Threads) потоков; $($x.Generation)") }
$txt.Add("RAM: $ramGB ГБ $ramType; планок $($modules.Count)")
foreach ($x in $modules) {
    $txt.Add(" - $($x.Slot): $($x.CapacityGB) ГБ $($x.Type), $($x.RatedSpeedMHz) МГц, настроено $($x.ConfiguredSpeedMHz) МГц")
}
$txt.Add('НАКОПИТЕЛИ:')
foreach ($x in $drives) {
    $txt.Add(" - Диск $($x.Number): $($x.Model), $($x.CapacityGB) ГБ, $($x.MediaType), $($x.BusType)")
    $txt.Add("   Windows Health: $($x.WindowsHealth), НЕ полноценный SMART")
    if ($x.StorageReliabilityCounters) {
        $c = $x.StorageReliabilityCounters
        $txt.Add("   Счётчики: температура $($c.TemperatureC) C; износ $($c.WearPercentConsumed)%; часы $($c.PowerOnHours)")
        $txt.Add("   Ошибки: чтение $($c.ReadErrorsTotal), запись $($c.WriteErrorsTotal); данные могут не поддерживаться драйвером")
    }
    if ($x.SmartctlRawFile) { $txt.Add("   RAW SMART: $($x.SmartctlRawFile) (проверить успешность чтения)") }
}
$txt.Add('GPU:')
foreach ($x in $gpu) {
    $txt.Add(" - $($x.Model), $($x.Type), WMI VRAM $($x.AdapterRAM_GB_Unreliable) ГБ (не проверено)")
}
$txt.Add("МАТЕРИНСКАЯ ПЛАТА: $($board.Manufacturer) $($board.Model)")
if ($chipsetClues.Count) { $txt.Add('Подсказки по чипсету (не подтверждены): ' + ($chipsetClues -join '; ')) }
$txt.Add("ПК/КОРПУС: $($oem.Manufacturer) $($oem.Model); SMBIOS: $case")
$txt.Add('БП: мощность/модель не определяются программно')
$txt.Add('СЕТЕВЫЕ УСТРОЙСТВА:')
foreach ($x in $network) { $txt.Add(" - $($x.Name), подключён сейчас: $($x.ConnectedNow)") }
$txt.Add("Wi-Fi адаптер обнаружен: $($wifi.Count -gt 0); Bluetooth-устройства обнаружены: $($bluetooth.Count -gt 0)")
$txt.Add('Физические HDMI / DP / VGA / USB / Ethernet: нужны осмотр и тестирование')
$txt.Add("WINDOWS: $($os.Name), $($os.Architecture), build $($os.Build)")
$txt.Add("АКТИВАЦИЯ: $activation")
$txt.Add("Возможные события ошибок дисковой подсистемы, 30 дней (ограниченная выборка): $($diskEvents.Count)")
foreach ($x in $diskEvents) { $txt.Add(" - $($x.Time) $($x.Source) ID $($x.EventID): $($x.Message)") }
$txt.Add('')
$txt.Add('ВАЖНО: Healthy не подтверждает исправность SSD/HDD и оставшийся ресурс.')
$txt.Add('ПРЕДУПРЕЖДЕНИЯ:')
foreach ($w in $warnings) { $txt.Add(' - ' + $w) }

($report | ConvertTo-Json -Depth 10) | Out-File -LiteralPath (Join-Path $folder 'inventory.json') -Encoding UTF8
$txt | Out-File -LiteralPath (Join-Path $folder 'inventory.txt') -Encoding UTF8
@('РУЧНАЯ ПРОВЕРКА ПЕРЕД ОБЪЯВЛЕНИЕМ','') + @($manual | ForEach-Object { '[ ] ' + $_ }) |
    Out-File -LiteralPath (Join-Path $folder 'manual-checklist.txt') -Encoding UTF8
[pscustomobject]@{
    ComputerName=$env:COMPUTERNAME; Date=$report.CollectedAt
    CPU=$cpuTitle; Cores=(@($cpu | Measure-Object Cores -Sum).Sum)
    Threads=(@($cpu | Measure-Object Threads -Sum).Sum)
    RAM_GB=$ramGB; DDR=$ramType; RAM_Modules=$modules.Count
    Drives=(@($drives | ForEach-Object { "$($_.MediaType) $($_.CapacityGB) GB $($_.Model)" }) -join '; ')
    GPU=(@($gpu | ForEach-Object Model) -join '; ')
    Motherboard="$($board.Manufacturer) $($board.Model)"
    Case=$case; OS=$os.Name; WindowsActivated=$activation
    ManualCheckPending='Да'
} | Export-Csv -LiteralPath (Join-Path $folder 'inventory.csv') -Delimiter ';' -Encoding UTF8 -NoTypeInformation
Write-Host ''
Write-Host 'ГОТОВО. Отчёты сохранены:' -ForegroundColor Green
Write-Host $folder
Write-Host 'inventory.txt / inventory.json / inventory.csv / manual-checklist.txt'
if ($smartctl) { Write-Host 'Дополнительно: smartctl-disk-*.txt (если накопитель отвечает)' }
Write-Host 'Отчёты никуда не отправлялись.' -ForegroundColor Yellow
