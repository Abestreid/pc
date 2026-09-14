#requires -version 3.0
<#
OfficeAutoInstaller.ps1 v1.0.1

Автоматический установщик Microsoft Office для Windows 10/11.
- определяет версию Windows, архитектуру, объем RAM и язык системы;
- не удаляет и не перезаписывает уже установленный Office;
- загружает Office Deployment Tool с серверов Microsoft;
- проверяет цифровую подпись Microsoft перед запуском;
- язык Office выбирается через MatchOS с резервом en-us;
- разрядность Office ODT выбирает автоматически;
- по умолчанию устанавливается Office Professional 2024 Retail;
- активация не выполняется.

Windows 7/8/8.1 распознаются, но установка современного Office блокируется как неподдерживаемая.

Примеры:
  .\OfficeAutoInstaller.ps1
  .\OfficeAutoInstaller.ps1 -ProductId HomeBusiness2024Retail
  .\OfficeAutoInstaller.ps1 -ProductId ProPlus2024Volume
#>

[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9]+$')]
    [string]$ProductId = 'Professional2024Retail'
)

$ScriptVersion = '1.0.1'
$SelfUrl = 'https://raw.githubusercontent.com/Abestreid/pc/main/OfficeAutoInstaller.ps1'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {
    try { [Net.ServicePointManager]::SecurityProtocol = 3072 } catch {}
}

# Windows PowerShell 5.1 корректно читает кириллицу из UTF-8 BOM.
# Дополнительно переключаем консоль на UTF-8, чтобы не было кракозябр.
try { & "$env:SystemRoot\System32\chcp.com" 65001 | Out-Null } catch {}
try {
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [Console]::InputEncoding = $utf8
    [Console]::OutputEncoding = $utf8
    $global:OutputEncoding = $utf8
} catch {}

function Write-Title([string]$Text) {
    Write-Host "`n============================================================" -ForegroundColor DarkCyan
    Write-Host " $Text" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor DarkCyan
}

function Write-Ok([string]$Text) {
    Write-Host "[OK] $Text" -ForegroundColor Green
}

function Write-Info([string]$Text) {
    Write-Host "[INFO] $Text" -ForegroundColor Cyan
}

function Write-Warn([string]$Text) {
    Write-Host "[ВНИМАНИЕ] $Text" -ForegroundColor Yellow
}

function Write-Stop([string]$Text) {
    Write-Host "[СТОП] $Text" -ForegroundColor Yellow
}

function Write-Fail([string]$Text) {
    Write-Host "[ОШИБКА] $Text" -ForegroundColor Red
}

function Test-Admin {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch { return $false }
}

# При запуске однострочной командой файла на диске еще нет.
# Поэтому для UAC повторно загружаем этот же скрипт из GitHub.
if (-not (Test-Admin)) {
    Write-Warn 'Требуются права администратора. Сейчас появится запрос UAC.'
    $safeProductId = $ProductId.Replace("'", "''")
    $payload = @"
[Net.ServicePointManager]::SecurityProtocol = 3072
`$client = New-Object Net.WebClient
`$client.Encoding = [Text.Encoding]::UTF8
`$source = `$client.DownloadString('$SelfUrl')
`$script = [ScriptBlock]::Create(`$source)
& `$script -ProductId '$safeProductId'
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($payload))
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    try {
        Start-Process -FilePath $ps -Verb RunAs -ArgumentList "-NoExit -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded" | Out-Null
    }
    catch {
        Write-Fail "Не удалось получить права администратора: $($_.Exception.Message)"
    }
    return
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$root = Join-Path $env:ProgramData 'OfficeAutoInstaller'
$work = Join-Path $root $stamp
New-Item -ItemType Directory -Path $work -Force | Out-Null
$logPath = Join-Path $work 'installer.log'
try { Start-Transcript -Path $logPath -Force | Out-Null } catch {}

function Stop-Installer([int]$Code, [string]$Message) {
    if ($Message) {
        switch ($Code) {
            0  { Write-Ok $Message }
            10 { Write-Stop $Message }
            20 { Write-Stop $Message }
            default { Write-Fail $Message }
        }
    }
    Write-Info "Журнал: $logPath"
    try { Stop-Transcript | Out-Null } catch {}
    $global:LASTEXITCODE = $Code
    return $Code
}

function Get-SystemInfo {
    $os = $null
    $cs = $null
    try { $os = Get-WmiObject Win32_OperatingSystem -ErrorAction Stop } catch {}
    try { $cs = Get-WmiObject Win32_ComputerSystem -ErrorAction Stop } catch {}

    $build = 0
    if ($os -and $os.BuildNumber) { [void][int]::TryParse([string]$os.BuildNumber, [ref]$build) }

    $family = 'Unknown'
    if ($build -ge 22000) { $family = 'Windows 11' }
    elseif ($build -ge 10240) { $family = 'Windows 10' }
    elseif ($build -ge 9200) { $family = 'Windows 8/8.1' }
    elseif ($build -ge 7600) { $family = 'Windows 7' }

    $caption = if ($os -and $os.Caption) { [string]$os.Caption } else { $family }

    $arch = 'неизвестно'
    try {
        if ([Environment]::Is64BitOperatingSystem) { $arch = '64-bit' } else { $arch = '32-bit' }
    }
    catch {
        if ($env:PROCESSOR_ARCHITEW6432 -or $env:PROCESSOR_ARCHITECTURE -match 'AMD64|ARM64') { $arch = '64-bit' } else { $arch = '32-bit' }
    }

    $ramGB = 0
    if ($cs -and $cs.TotalPhysicalMemory) {
        $ramGB = [math]::Round(([double]$cs.TotalPhysicalMemory / 1GB), 1)
    }

    $lang = 'неизвестно'
    try { $lang = [Globalization.CultureInfo]::InstalledUICulture.Name } catch {}

    return New-Object PSObject -Property @{
        Family = $family
        Caption = $caption
        Build = $build
        Architecture = $arch
        RamGB = $ramGB
        Language = $lang
    }
}

function Get-ExistingOffice {
    $items = New-Object System.Collections.ArrayList

    # Не обращаемся к отсутствующему пути через Get-ItemProperty -ErrorAction Stop.
    # Иначе Start-Transcript пишет PS>TerminatingError даже если исключение затем перехвачено.
    $c2rPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office\ClickToRun\Configuration'
    )
    foreach ($path in $c2rPaths) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $cfg = Get-ItemProperty -LiteralPath $path -ErrorAction SilentlyContinue
        if ($cfg -and $cfg.ProductReleaseIds) {
            [void]$items.Add("Click-to-Run: $($cfg.ProductReleaseIds)")
        }
    }

    $uninstallRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($rootPath in $uninstallRoots) {
        Get-ItemProperty -Path $rootPath -ErrorAction SilentlyContinue |
            Where-Object {
                $_.DisplayName -and
                $_.DisplayName -match 'Microsoft (365|Office)' -and
                $_.DisplayName -notmatch 'Update|Language Pack|Proofing|Click-to-Run Extensibility'
            } |
            ForEach-Object { [void]$items.Add([string]$_.DisplayName) }
    }

    $wordCandidates = @(
        (Join-Path $env:ProgramFiles 'Microsoft Office\root\Office16\WINWORD.EXE')
    )
    if (${env:ProgramFiles(x86)}) {
        $wordCandidates += (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Office\root\Office16\WINWORD.EXE')
    }
    foreach ($candidate in $wordCandidates) {
        if (Test-Path -LiteralPath $candidate) { [void]$items.Add("Word: $candidate") }
    }

    return @($items | Select-Object -Unique)
}

function Test-MicrosoftSignature([string]$Path) {
    try {
        $sig = Get-AuthenticodeSignature -FilePath $Path -ErrorAction Stop
        if ($sig.Status -ne 'Valid') { return $false }
        if (-not $sig.SignerCertificate) { return $false }
        return ([string]$sig.SignerCertificate.Subject -match 'Microsoft')
    }
    catch { return $false }
}

function Download-File([string]$Url, [string]$Destination) {
    Write-Info "Скачивание: $Url"
    $wc = New-Object Net.WebClient
    $wc.Headers['User-Agent'] = "Mozilla/5.0 OfficeAutoInstaller/$ScriptVersion"
    $wc.DownloadFile($Url, $Destination)
}

function Resolve-OdtPackageUrl {
    $pages = @(
        'https://www.microsoft.com/en-us/download/details.aspx?id=49117',
        'https://www.microsoft.com/en-us/download/confirmation.aspx?id=49117'
    )
    $pattern = 'https://download\.microsoft\.com/download/[^"''<>\s]+/officedeploymenttool_[^"''<>\s]+\.exe'

    foreach ($page in $pages) {
        try {
            $wc = New-Object Net.WebClient
            $wc.Headers['User-Agent'] = "Mozilla/5.0 OfficeAutoInstaller/$ScriptVersion"
            $html = $wc.DownloadString($page)
            try { $html = [Net.WebUtility]::HtmlDecode($html) } catch {}
            $match = [regex]::Match($html, $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($match.Success) { return $match.Value }
        }
        catch {}
    }
    return $null
}

function Get-OdtSetup([string]$Directory) {
    $setupPath = Join-Path $Directory 'setup.exe'
    $packageUrl = Resolve-OdtPackageUrl

    if ($packageUrl) {
        $packagePath = Join-Path $Directory 'OfficeDeploymentTool.exe'
        try {
            Download-File $packageUrl $packagePath
            if (-not (Test-MicrosoftSignature $packagePath)) {
                throw 'Цифровая подпись пакета ODT не прошла проверку.'
            }
            Write-Ok 'Пакет Office Deployment Tool подписан Microsoft.'

            $p = Start-Process -FilePath $packagePath -ArgumentList '/quiet', "/extract:$Directory" -Wait -PassThru
            if ($p.ExitCode -ne 0) {
                throw "Распаковка ODT завершилась с кодом $($p.ExitCode)."
            }
            if (Test-Path -LiteralPath $setupPath) {
                if (-not (Test-MicrosoftSignature $setupPath)) {
                    throw 'Цифровая подпись setup.exe ODT не прошла проверку.'
                }
                return $setupPath
            }
        }
        catch {
            Write-Warn "Не удалось использовать пакет из Download Center: $($_.Exception.Message)"
        }
    }

    # Резервный путь: официальный CDN Microsoft с самим setup.exe ODT.
    # Перед запуском файл обязательно проверяется по Authenticode.
    $cdnUrl = 'https://officecdn.microsoft.com/pr/wsus/setup.exe'
    try {
        Download-File $cdnUrl $setupPath
        if (-not (Test-MicrosoftSignature $setupPath)) {
            throw 'Цифровая подпись setup.exe с Microsoft CDN не прошла проверку.'
        }
        Write-Ok 'Office Deployment Tool загружен с Microsoft CDN и подпись проверена.'
        return $setupPath
    }
    catch {
        throw "Не удалось получить безопасный Office Deployment Tool: $($_.Exception.Message)"
    }
}

function Get-ChannelAttribute([string]$Id) {
    if ($Id -match '2024Volume$') { return ' Channel="PerpetualVL2024"' }
    if ($Id -match '2021Volume$') { return ' Channel="PerpetualVL2021"' }
    if ($Id -match '^O365') { return ' Channel="Current"' }
    return ''
}

function Find-OfficeApplications {
    $result = New-Object System.Collections.ArrayList
    $roots = @($env:ProgramFiles)
    if (${env:ProgramFiles(x86)}) { $roots += ${env:ProgramFiles(x86)} }

    $apps = @(
        @{ Name = 'Word'; File = 'WINWORD.EXE' },
        @{ Name = 'Excel'; File = 'EXCEL.EXE' },
        @{ Name = 'PowerPoint'; File = 'POWERPNT.EXE' },
        @{ Name = 'Outlook'; File = 'OUTLOOK.EXE' }
    )

    foreach ($app in $apps) {
        $found = $false
        foreach ($base in $roots) {
            $path = Join-Path $base ("Microsoft Office\root\Office16\" + $app.File)
            if (Test-Path -LiteralPath $path) {
                [void]$result.Add("$($app.Name): $path")
                $found = $true
                break
            }
        }
        if (-not $found) { [void]$result.Add("$($app.Name): не найден") }
    }
    return @($result)
}

Write-Title "Автоматическая установка Microsoft Office - версия $ScriptVersion"
Write-Info 'Активация Office этим скриптом не выполняется.'
Write-Info 'Для активации используйте принадлежащую вам лицензию, учетную запись или ключ Microsoft.'

$sys = Get-SystemInfo
Write-Title 'Проверка компьютера'
Write-Host ("Windows:       {0}" -f $sys.Caption)
Write-Host ("Семейство:     {0}" -f $sys.Family)
Write-Host ("Сборка:        {0}" -f $sys.Build)
Write-Host ("Архитектура:   {0}" -f $sys.Architecture)
Write-Host ("ОЗУ:           {0} ГБ" -f $sys.RamGB)
Write-Host ("Язык Windows:  {0}" -f $sys.Language)
Write-Host ("Продукт Office:{0}" -f " $ProductId")

if ($sys.Family -eq 'Windows 7' -or $sys.Family -eq 'Windows 8/8.1') {
    Write-Warn "$($sys.Family) распознана, но современный Office 2024 на ней не поддерживается."
    Write-Warn 'Скрипт намеренно не устанавливает старые неподдерживаемые версии Office.'
    [void](Stop-Installer 20 'Установка остановлена без изменений системы.')
    return
}

if ($sys.Family -eq 'Unknown') {
    [void](Stop-Installer 21 'Версия Windows не распознана. Установка не начата.')
    return
}

if ($sys.Family -eq 'Windows 10') {
    Write-Warn 'Windows 10 снята с поддержки Microsoft 14 октября 2025 года.'
    Write-Warn 'Office 2024 может устанавливаться, но актуальная поддерживаемая платформа Microsoft - Windows 11.'
}

$existing = Get-ExistingOffice
if ($existing.Count -gt 0) {
    Write-Title 'Office уже обнаружен'
    foreach ($item in $existing) { Write-Host " - $item" }
    Write-Warn 'Чтобы не повредить существующую лицензию и профиль Office, автоматическая переустановка отменена.'
    [void](Stop-Installer 10 'Изменения не выполнялись. Это штатная защитная остановка.')
    return
}

try {
    $systemDrive = Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'"
    if ($systemDrive -and $systemDrive.FreeSpace) {
        $freeGB = [math]::Round(([double]$systemDrive.FreeSpace / 1GB), 1)
        Write-Info "Свободно на $env:SystemDrive $freeGB ГБ"
        if ($freeGB -lt 5) {
            [void](Stop-Installer 22 'Недостаточно свободного места. Требуется минимум 5 ГБ, рекомендуется 8 ГБ и более.')
            return
        }
        elseif ($freeGB -lt 8) {
            Write-Warn 'Свободного места меньше 8 ГБ. Установка возможна, но запас небольшой.'
        }
    }
}
catch {}

Write-Title 'Подготовка Office Deployment Tool'
try {
    $setup = Get-OdtSetup $work
    Write-Ok "ODT готов: $setup"
}
catch {
    [void](Stop-Installer 30 $_.Exception.Message)
    return
}

$channel = Get-ChannelAttribute $ProductId
$configPath = Join-Path $work 'configuration.xml'
$xml = @"
<Configuration>
  <Add AllowCdnFallback="TRUE"$channel>
    <Product ID="$ProductId">
      <Language ID="MatchOS" Fallback="en-us" />
    </Product>
  </Add>
  <Display Level="Full" AcceptEULA="TRUE" />
  <Updates Enabled="TRUE" />
  <Property Name="AUTOACTIVATE" Value="0" />
</Configuration>
"@

try {
    [IO.File]::WriteAllText($configPath, $xml, (New-Object Text.UTF8Encoding($false)))
    Write-Ok 'Конфигурация создана.'
    Write-Info 'Язык Office: как в Windows (MatchOS), резервный язык: en-us.'
    Write-Info 'Разрядность Office: автоматически выбирается ODT по Windows, ОЗУ и существующей архитектуре.'
}
catch {
    [void](Stop-Installer 31 "Не удалось создать configuration.xml: $($_.Exception.Message)")
    return
}

Write-Title 'Установка Office'
Write-Info 'Office будет скачан напрямую с CDN Microsoft. Скорость зависит от интернет-соединения.'
try {
    $args = "/configure `"$configPath`""
    $proc = Start-Process -FilePath $setup -ArgumentList $args -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        [void](Stop-Installer 40 "Office Deployment Tool завершился с кодом $($proc.ExitCode).")
        return
    }
}
catch {
    [void](Stop-Installer 41 "Ошибка запуска установки Office: $($_.Exception.Message)")
    return
}

Start-Sleep -Seconds 3
Write-Title 'Проверка результата'
$apps = Find-OfficeApplications
foreach ($app in $apps) {
    if ($app -match 'не найден$') { Write-Warn $app } else { Write-Ok $app }
}

$wordFound = @($apps | Where-Object { $_ -like 'Word:*' -and $_ -notmatch 'не найден$' }).Count -gt 0
$excelFound = @($apps | Where-Object { $_ -like 'Excel:*' -and $_ -notmatch 'не найден$' }).Count -gt 0
if (-not ($wordFound -and $excelFound)) {
    [void](Stop-Installer 50 'ODT завершился, но основные приложения Office не найдены. Проверьте журнал и окно установщика Microsoft.')
    return
}

Write-Host ''
Write-Ok 'Microsoft Office установлен.'
Write-Info 'Если Office запросит активацию, войдите в лицензированную учетную запись Microsoft или введите принадлежащий вам ключ.'
[void](Stop-Installer 0 'Готово.')