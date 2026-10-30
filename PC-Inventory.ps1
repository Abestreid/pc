# PC-Inventory.ps1 - inventarizatsiya ofisnyh PK (Windows PowerShell 5.1+)
# Zapusk: powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\PC-Inventory.ps1 -Id PC-001
[CmdletBinding()]
param([string]$Id = $env:COMPUTERNAME)

$ErrorActionPreference = 'SilentlyContinue'

function Wmi($Class, $Namespace = 'root/cimv2') {
    try { @(Get-CimInstance -ClassName $Class -Namespace $Namespace -ErrorAction Stop) }
    catch { @() }
}
function GB($Bytes) {
    if ($null -eq $Bytes -or [double]$Bytes -le 0) { return '?' }
    return ('{0:N1}' -f ([double]$Bytes / 1GB))
}
function RamType($Stick) {
    $code = [int]$Stick.SMBIOSMemoryType
    if ($code -eq 0) { $code = [int]$Stick.MemoryType }
    switch ($code) {
        20 {'DDR'} 21 {'DDR2'} 24 {'DDR3'} 26 {'DDR4'}
        27 {'LPDDR'} 28 {'LPDDR2'} 29 {'LPDDR3'} 30 {'LPDDR4'}
        34 {'DDR5'} 35 {'LPDDR5'} 36 {'LPDDR5X'}
        default {'не определён'}
    }
}
function Line([string]$Value = '') { [void]$script:lines.Add($Value) }

$lines = New-Object 'System.Collections.Generic.List[string]'
$computer = @(Wmi 'Win32_ComputerSystem') | Select-Object -First 1
$system = @(Wmi 'Win32_ComputerSystemProduct') | Select-Object -First 1
$cpu = @(Wmi 'Win32_Processor') | Select-Object -First 1
$os = @(Wmi 'Win32_OperatingSystem') | Select-Object -First 1
$board = @(Wmi 'Win32_BaseBoard') | Select-Object -First 1
$bios = @(Wmi 'Win32_BIOS') | Select-Object -First 1
$enclosure = @(Wmi 'Win32_SystemEnclosure') | Select-Object -First 1
$memory = @(Wmi 'Win32_PhysicalMemory')
$video = @(Wmi 'Win32_VideoController')
$drives = @(Wmi 'Win32_DiskDrive')
$physical = @(Get-PhysicalDisk -ErrorAction SilentlyContinue)

Line 'ИНВЕНТАРИЗАЦИЯ ОФИСНОГО ПК'
Line ('ID: {0}' -f $Id)
Line ('Дата: {0:yyyy-MM-dd HH:mm}' -f (Get-Date))
Line ('Компьютер: {0} / {1}' -f $computer.Manufacturer, $computer.Model)
Line ('Модель системы: {0}' -f $system.Name)
Line ''
Line '[ПРОЦЕССОР]'
if ($cpu) {
    Line ('Модель: {0}' -f ([string]$cpu.Name).Trim())
    Line ('Ядра / потоки: {0} / {1}' -f $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors)
    $gen = ''
    if ($cpu.Name -match 'Core(?:\(TM\))?.*?i[3579]-(\d{4,5})') {
        $num = $Matches[1]
        $generation = if ($num.Length -eq 5) { [int]$num.Substring(0,2) } else { [int]$num.Substring(0,1) }
        if ($generation -ge 2 -and $generation -le 14) { $gen = "$generation-е поколение Intel Core" }
    }
    if ($gen) { Line ('Поколение: {0}' -f $gen) }
} else { Line 'Не удалось прочитать CPU' }
Line ''
Line '[ОПЕРАТИВНАЯ ПАМЯТЬ]'
if ($memory.Count) {
    $sum = ($memory | Measure-Object -Property Capacity -Sum).Sum
    Line ('Всего: {0} ГБ, планок: {1}' -f (GB $sum), $memory.Count)
    $i = 0
    foreach ($m in $memory) {
        $i++
        $mhz = if ($m.ConfiguredClockSpeed) { $m.ConfiguredClockSpeed } elseif ($m.Speed) { $m.Speed } else { '?' }
        Line ('Планка {0}: {1} ГБ, {2}, {3} МГц, {4} {5}' -f $i, (GB $m.Capacity), (RamType $m), $mhz, $m.Manufacturer, ([string]$m.PartNumber).Trim())
    }
} else { Line 'Не удалось прочитать RAM' }
Line ''
Line '[НАКОПИТЕЛИ]'
if ($drives.Count) {
    $i = 0
    foreach ($d in $drives) {
        $i++
        $serial = ([string]$d.SerialNumber -replace '\s+', '').ToUpperInvariant()
        $matches = @()
        if ($serial) {
            $matches = @($physical | Where-Object { (([string]$_.SerialNumber -replace '\s+', '').ToUpperInvariant()) -eq $serial })
        }
        if ($matches.Count -ne 1) {
            $matches = @($physical | Where-Object { $_.FriendlyName -eq $d.Model })
        }
        $p = if ($matches.Count -eq 1) { $matches[0] } else { $null }
        $kind = 'не определён'
        if ($p -and "$($p.MediaType)" -in @('SSD','HDD')) { $kind = "$($p.MediaType)" }
        elseif ($d.Model -match '(?i)\bSSD\b|NVMe') { $kind = 'SSD (по модели)' }
        $diskInfo = Get-Disk -Number $d.Index -ErrorAction SilentlyContinue
        $bus = if ($diskInfo -and "$($diskInfo.BusType)" -notin @('Unknown','Unspecified')) { "$($diskInfo.BusType)" }
               elseif ($d.PNPDeviceID -match '(?i)NVME') { 'NVMe' }
               elseif ($d.InterfaceType -eq 'USB') { 'USB' }
               else { 'не определён' }
        $health = if ($p) { "$($p.HealthStatus) (оценка Windows, не полный SMART)" } else { 'не определено' }
        Line ('Диск {0}: {1}' -f $i, $d.Model)
        Line ('  Тип: {0}; объём: {1:N0} ГБ (~{2} ГиБ в Windows); подключение: {3}' -f $kind, ([double]$d.Size / 1e9), (GB $d.Size), $bus)
        Line ('  Здоровье: {0}' -f $health)
        if ($p) {
            $rel = Get-StorageReliabilityCounter -PhysicalDisk $p -ErrorAction SilentlyContinue
            if ($rel -and $null -ne $rel.PowerOnHours -and $rel.PowerOnHours -gt 0) {
                Line ('  Наработка (если поддерживается): {0} ч' -f $rel.PowerOnHours)
            }
        }
    }
} else { Line 'Не удалось прочитать диски' }
Line 'Полный SMART / износ SSD: проверить в CrystalDiskInfo (скриншот).'
Line ''
Line '[ВИДЕОКАРТА]'
if ($video.Count) {
    foreach ($v in $video) {
        $type = 'не определено'
        if ($v.Name -match '(?i)Intel.*(HD Graphics|UHD Graphics|Iris)|AMD Radeon\(TM\) Graphics') { $type = 'вероятно встроенная' }
        elseif ($v.Name -match '(?i)NVIDIA|GeForce|Quadro|Radeon\s+(RX|R[579]\b|HD\s|Pro\s)') { $type = 'вероятно дискретная' }
        Line ('Модель: {0}; тип: {1}' -f $v.Name, $type)
        if ($type -eq 'вероятно дискретная' -and $v.AdapterRAM -gt 0) {
            Line ('Видеопамять по WMI: {0} ГБ (может определяться неточно)' -f (GB $v.AdapterRAM))
        }
    }
} else { Line 'Не удалось прочитать GPU' }
Line ''
Line '[МАТЕРИНСКАЯ ПЛАТА / КОРПУС]'
Line ('Плата: {0} {1}' -f $board.Manufacturer, $board.Product)
Line ('BIOS: {0}' -f $bios.SMBIOSBIOSVersion)
$chassisCode = if ($enclosure.ChassisTypes) { [int]$enclosure.ChassisTypes[0] } else { 0 }
$chassis = switch ($chassisCode) {
    3 {'Desktop'} 4 {'Low Profile Desktop'} 6 {'Mini Tower'} 7 {'Tower'}
    13 {'All-in-One'} 15 {'Space Saving'} 16 {'Small / Lunch Box'}
    23 {'Rack Mount'} default {'не определён'}
}
Line ('Корпус (по BIOS): {0}' -f $chassis)
Line 'Чипсет: требует уточнения по модели платы.'
Line 'Блок питания (бренд / Вт): посмотреть наклейку внутри корпуса.'
Line ''
Line '[СИСТЕМА / ПРОВЕРИТЬ ВРУЧНУЮ]'
Line ('ОС: {0}; версия {1}' -f $os.Caption, $os.Version)
Line 'Активация Windows: проверить вручную.'
Line 'Разъёмы HDMI / DP / VGA, USB, Wi-Fi / Bluetooth: осмотреть и проверить.'
Line 'Внешний вид, дефекты, шум / температура, работоспособность: проверить.'
Line 'Комплектация (монитор, кабели, клавиатура, мышь): заполнить.'
Line 'ВАЖНО: перед продажей надёжно стереть корпоративные данные.'

$report = $lines -join [Environment]::NewLine
Write-Host $report
try {
    $folder = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    $outDir = Join-Path $folder 'Reports'
    New-Item -Path $outDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
    $safeId = $Id -replace '[^a-zA-Z0-9а-яА-ЯёЁ_-]', '_'
    $path = Join-Path $outDir ('{0}_{1:yyyyMMdd_HHmmss}.txt' -f $safeId, (Get-Date))
    [System.IO.File]::WriteAllText($path, $report, (New-Object System.Text.UTF8Encoding($true)))
    Write-Host "`nОТЧЁТ СОХРАНЁН: $path" -ForegroundColor Green
} catch {
    Write-Warning "Не удалось сохранить отчёт: $($_.Exception.Message)"
}
