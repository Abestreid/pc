#requires -version 3.0
<#
PcToPc.ps1 v2.0.0

Прямая передача папок и файлов с одного Windows 10/11 ПК на другой через интернет.
- ничего не устанавливает, без регистраций и сторонних программ - только PowerShell;
- передает все вложенные папки и файлы (включая пустые папки), структура сохраняется;
- файлы любого размера (больше 4 GB тоже);
- после обрыва сам переподключается и докачивает с того же места;
- повторный запуск пропускает уже полностью переданные файлы;
- сам открывает порт в Windows Firewall и на роутере (UPnP), после работы закрывает;
- доступ защищен PIN-кодом из кода подключения.

Получатель: пункт 2 -> папка (Enter = Downloads\Torrents) -> отправить код второй стороне.
Отправитель: пункт 1 -> перетащить папки -> вставить код.
Если не соединяется: на отправителе пункт 3, на получателе пункт 4 (меняется, кто ждет подключения).

Примеры без меню:
  .\PcToPc.ps1 -Mode Receive -Dest 'C:\Users\owner\Downloads\Torrents'
  .\PcToPc.ps1 -Mode Send -Paths 'D:\Soft\Photoshop.2021' -Code '1.2.3.4:42873:123456'
#>

[CmdletBinding()]
param(
    [ValidateSet('Menu', 'Send', 'Receive')]
    [string]$Mode = 'Menu',
    [switch]$Listen,
    [string[]]$Paths,
    [string]$Dest,
    [string]$Code,
    [int]$Port = 42873,
    [string]$Pin,
    [switch]$Local,
    [switch]$NoAdmin
)

$ScriptVersion = '2.0.0'
$SelfUrl = 'https://raw.githubusercontent.com/Abestreid/pc/main/PcToPc.ps1'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Magic = 'DFT2'
$BufferSize = 1MB
$RuleName = "PcToPc-$Port"
$LogFile = Join-Path $env:TEMP 'PcToPc.log'

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {
    try { [Net.ServicePointManager]::SecurityProtocol = 3072 } catch {}
}

# Windows PowerShell 5.1 корректно читает кириллицу из UTF-8 BOM.
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
function Write-Ok([string]$Text)   { Write-Host "[OK] $Text" -ForegroundColor Green }
function Write-Info([string]$Text) { Write-Host "[INFO] $Text" -ForegroundColor Cyan }
function Write-Warn([string]$Text) { Write-Host "[ВНИМАНИЕ] $Text" -ForegroundColor Yellow }
function Write-Fail([string]$Text) { Write-Host "[ОШИБКА] $Text" -ForegroundColor Red }

function Write-Log([string]$Text) {
    try { Add-Content -LiteralPath $LogFile -Value ("{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $Text) -Encoding UTF8 } catch {}
}

function Test-Admin {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch { return $false }
}

# Админ нужен только чтобы открыть порт в Windows Firewall.
# При запуске однострочной командой файла на диске еще нет - для UAC повторно загружаем скрипт из GitHub.
if (-not $NoAdmin -and -not (Test-Admin)) {
    Write-Warn 'Требуются права администратора (открыть порт в Windows Firewall). Сейчас появится запрос UAC.'
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if ($PSCommandPath) {
        $argList = "-NoExit -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    }
    else {
        $payload = @"
[Net.ServicePointManager]::SecurityProtocol = 3072
`$client = New-Object Net.WebClient
`$client.Encoding = [Text.Encoding]::UTF8
`$source = `$client.DownloadString('$SelfUrl')
`$script = [ScriptBlock]::Create(`$source)
& `$script
"@
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($payload))
        $argList = "-NoExit -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded"
    }
    try {
        Start-Process -FilePath $ps -Verb RunAs -ArgumentList $argList | Out-Null
        return
    }
    catch {
        Write-Warn "Без прав администратора. Если Windows спросит про доступ к сети - нажмите 'Разрешить'."
        $NoAdmin = $true
    }
}

# Ошибка, после которой повторять бессмысленно (неверный PIN, мало места и т.п.)
function New-FatalError([string]$Message) { return (New-Object ApplicationException($Message)) }

# ---------------------------------------------------------------- утилиты

function Format-Size([double]$Bytes) {
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0:N0} B' -f $Bytes)
}

function Format-Eta([double]$Seconds) {
    if ($Seconds -lt 0 -or [double]::IsInfinity($Seconds) -or [double]::IsNaN($Seconds)) { return '--:--:--' }
    $t = [TimeSpan]::FromSeconds([Math]::Min($Seconds, 359999))
    return ('{0:00}:{1:00}:{2:00}' -f [Math]::Floor($t.TotalHours), $t.Minutes, $t.Seconds)
}

$script:ProgressLast = 0
$script:SessionBytes = 0
function Show-Progress([long]$Done, [long]$Total, [Diagnostics.Stopwatch]$Watch, [string]$Name, [switch]$Force) {
    $now = $Watch.ElapsedMilliseconds
    if (-not $Force -and ($now - $script:ProgressLast) -lt 500) { return }
    $script:ProgressLast = $now
    $sec = [Math]::Max($Watch.Elapsed.TotalSeconds, 0.001)
    $speed = $script:SessionBytes / $sec
    $pct = 100.0
    if ($Total -gt 0) { $pct = $Done * 100.0 / $Total }
    $eta = -1
    if ($speed -gt 0) { $eta = ($Total - $Done) / $speed }
    $line = '[{0,5:N1}%] {1} / {2}  {3}/s  осталось {4}  {5}' -f $pct, (Format-Size $Done), (Format-Size $Total), (Format-Size $speed), (Format-Eta $eta), $Name
    $width = 119
    try { $width = [Console]::WindowWidth - 1 } catch {}
    if ($width -lt 40) { $width = 79 }
    if ($line.Length -gt $width) { $line = $line.Substring(0, $width) }
    Write-Host ("`r" + $line.PadRight($width)) -NoNewline
}

function Get-CleanPaths([string]$Line) {
    # Перетаскивание в окно PowerShell дает "путь в кавычках"; можно перетащить несколько сразу.
    $result = @()
    if ($Line -match '"') {
        foreach ($m in [regex]::Matches($Line, '"([^"]+)"')) { $result += $m.Groups[1].Value.Trim() }
    }
    elseif ($Line -match "^\s*&?\s*'") {
        foreach ($m in [regex]::Matches($Line, "'([^']+)'")) { $result += $m.Groups[1].Value.Trim() }
    }
    else {
        $t = $Line.Trim().TrimStart('&').Trim()
        if ($t) { $result += $t }
    }
    return , $result
}

function Get-HttpText([string]$Url, [int]$TimeoutMs = 6000) {
    try {
        $req = [Net.HttpWebRequest]::Create($Url)
        $req.Timeout = $TimeoutMs
        $req.ReadWriteTimeout = $TimeoutMs
        $req.UserAgent = 'PcToPc'
        $resp = $req.GetResponse()
        try { return (New-Object IO.StreamReader($resp.GetResponseStream())).ReadToEnd().Trim() }
        finally { $resp.Close() }
    }
    catch { return $null }
}

function Test-PrivateIPv4([string]$Ip) {
    $a = $null
    if (-not [Net.IPAddress]::TryParse($Ip, [ref]$a)) { return $true }
    $b = $a.GetAddressBytes()
    if ($b.Length -ne 4) { return $false }
    if ($b[0] -eq 10 -or $b[0] -eq 127 -or $b[0] -eq 0) { return $true }
    if ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) { return $true }
    if ($b[0] -eq 192 -and $b[1] -eq 168) { return $true }
    if ($b[0] -eq 100 -and $b[1] -ge 64 -and $b[1] -le 127) { return $true }
    if ($b[0] -eq 169 -and $b[1] -eq 254) { return $true }
    return $false
}

function Get-PublicIPv4 {
    foreach ($u in 'https://api.ipify.org', 'https://ipv4.icanhazip.com', 'https://ifconfig.me/ip') {
        $t = Get-HttpText $u
        $a = $null
        if ($t -and [Net.IPAddress]::TryParse($t, [ref]$a) -and $a.AddressFamily -eq 'InterNetwork') { return $t }
    }
    return $null
}

function Get-PublicIPv6 {
    foreach ($u in 'https://api6.ipify.org', 'https://ipv6.icanhazip.com') {
        $t = Get-HttpText $u 4000
        $a = $null
        if ($t -and [Net.IPAddress]::TryParse($t, [ref]$a) -and $a.AddressFamily -eq 'InterNetworkV6') { return $t }
    }
    return $null
}

# ---------------------------------------------------------------- UPnP: проброс порта на роутере без захода в роутер

$script:Upnp = $null

function Invoke-UpnpSoap([string]$ControlUrl, [string]$ServiceType, [string]$Action, [string]$Body) {
    $xml = '<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>' +
        "<u:$Action xmlns:u=`"$ServiceType`">$Body</u:$Action></s:Body></s:Envelope>"
    $bytes = [Text.Encoding]::UTF8.GetBytes($xml)
    $req = [Net.HttpWebRequest]::Create($ControlUrl)
    $req.Method = 'POST'
    $req.Timeout = 6000
    $req.ContentType = 'text/xml; charset="utf-8"'
    $req.Headers.Add('SOAPAction', "`"$ServiceType#$Action`"")
    $req.ContentLength = $bytes.Length
    $rs = $req.GetRequestStream(); $rs.Write($bytes, 0, $bytes.Length); $rs.Close()
    $resp = $req.GetResponse()
    try { return (New-Object IO.StreamReader($resp.GetResponseStream())).ReadToEnd() } finally { $resp.Close() }
}

function Find-UpnpGateway {
    $locations = @()
    $udp = New-Object Net.Sockets.UdpClient(0)
    try {
        $udp.Client.ReceiveTimeout = 1000
        $target = New-Object Net.IPEndPoint([Net.IPAddress]::Parse('239.255.255.250'), 1900)
        foreach ($st in 'urn:schemas-upnp-org:device:InternetGatewayDevice:1', 'urn:schemas-upnp-org:service:WANIPConnection:1', 'urn:schemas-upnp-org:service:WANPPPConnection:1', 'urn:schemas-upnp-org:device:InternetGatewayDevice:2') {
            $msg = "M-SEARCH * HTTP/1.1`r`nHOST: 239.255.255.250:1900`r`nMAN: `"ssdp:discover`"`r`nMX: 2`r`nST: $st`r`n`r`n"
            $b = [Text.Encoding]::ASCII.GetBytes($msg)
            [void]$udp.Send($b, $b.Length, $target)
        }
        $deadline = [DateTime]::UtcNow.AddSeconds(3)
        while ([DateTime]::UtcNow -lt $deadline) {
            try {
                $ep = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0)
                $data = $udp.Receive([ref]$ep)
                $text = [Text.Encoding]::ASCII.GetString($data)
                if ($text -match '(?im)^LOCATION:\s*(\S+)') {
                    if ($locations -notcontains $Matches[1]) { $locations += $Matches[1] }
                }
            }
            catch {}
        }
    }
    finally { $udp.Close() }

    foreach ($loc in $locations) {
        $desc = Get-HttpText $loc 5000
        if (-not $desc) { continue }
        try { [xml]$x = $desc } catch { continue }
        $base = $loc
        $ub = $x.GetElementsByTagName('URLBase')
        if ($ub.Count -gt 0 -and $ub[0].InnerText) { $base = $ub[0].InnerText }
        foreach ($svc in $x.GetElementsByTagName('service')) {
            $type = [string]$svc.serviceType
            if ($type -match 'WANIPConnection|WANPPPConnection') {
                $ctrl = (New-Object Uri((New-Object Uri($base)), [string]$svc.controlURL)).AbsoluteUri
                $u = New-Object Uri($loc)
                # Свой локальный IP в сторону роутера
                $s = New-Object Net.Sockets.Socket([Net.Sockets.AddressFamily]::InterNetwork, [Net.Sockets.SocketType]::Dgram, [Net.Sockets.ProtocolType]::Udp)
                try { $s.Connect($u.Host, 1900); $localIp = $s.LocalEndPoint.Address.ToString() } finally { $s.Close() }
                return @{ Control = $ctrl; Type = $type; LocalIp = $localIp; External = $null }
            }
        }
    }
    return $null
}

function Open-UpnpPort([int]$P) {
    try {
        $gw = Find-UpnpGateway
        if (-not $gw) {
            Write-Warn 'Роутер не ответил по UPnP - порт на роутере открыть не удалось.'
            Write-Warn 'Если вторая сторона не подключится: поменяйтесь ролями (пункты 3/4) или включите UPnP в настройках роутера.'
            return $null
        }
        try {
            $r = Invoke-UpnpSoap $gw.Control $gw.Type 'GetExternalIPAddress' ''
            if ($r -match '<NewExternalIPAddress>([^<]*)<') { $gw.External = $Matches[1] }
        } catch {}
        $del = "<NewRemoteHost></NewRemoteHost><NewExternalPort>$P</NewExternalPort><NewProtocol>TCP</NewProtocol>"
        try { Invoke-UpnpSoap $gw.Control $gw.Type 'DeletePortMapping' $del | Out-Null } catch {}
        $ok = $false
        foreach ($lease in 0, 86400) {
            try {
                $body = "<NewRemoteHost></NewRemoteHost><NewExternalPort>$P</NewExternalPort><NewProtocol>TCP</NewProtocol><NewInternalPort>$P</NewInternalPort>" +
                    "<NewInternalClient>$($gw.LocalIp)</NewInternalClient><NewEnabled>1</NewEnabled><NewPortMappingDescription>PcToPc</NewPortMappingDescription><NewLeaseDuration>$lease</NewLeaseDuration>"
                Invoke-UpnpSoap $gw.Control $gw.Type 'AddPortMapping' $body | Out-Null
                $ok = $true; break
            } catch { Write-Log "UPnP AddPortMapping lease=$lease : $($_.Exception.Message)" }
        }
        if (-not $ok) { Write-Warn 'Роутер отказал в пробросе порта по UPnP.'; return $null }
        $script:Upnp = $gw
        Write-Ok "Порт $P открыт на роутере (UPnP). Внешний IP роутера: $($gw.External)"
        return $gw
    }
    catch {
        Write-Log "UPnP: $($_.Exception.Message)"
        Write-Warn 'UPnP не сработал.'
        return $null
    }
}

function Close-UpnpPort([int]$P) {
    if (-not $script:Upnp) { return }
    $del = "<NewRemoteHost></NewRemoteHost><NewExternalPort>$P</NewExternalPort><NewProtocol>TCP</NewProtocol>"
    try { Invoke-UpnpSoap $script:Upnp.Control $script:Upnp.Type 'DeletePortMapping' $del | Out-Null } catch {}
    $script:Upnp = $null
}

# ---------------------------------------------------------------- Windows Firewall

$script:RuleAdded = $false
function Open-FirewallPort([int]$P) {
    if ($NoAdmin -or -not (Test-Admin)) { return }
    & netsh advfirewall firewall delete rule name="$RuleName" | Out-Null
    & netsh advfirewall firewall add rule name="$RuleName" dir=in action=allow protocol=TCP localport=$P profile=any | Out-Null
    if ($LASTEXITCODE -eq 0) { $script:RuleAdded = $true; Write-Ok "Порт $P открыт в Windows Firewall (временно)." }
    else { Write-Warn 'Не удалось добавить правило Windows Firewall.' }
}
function Close-FirewallPort {
    if ($script:RuleAdded) { & netsh advfirewall firewall delete rule name="$RuleName" | Out-Null; $script:RuleAdded = $false }
}

# ---------------------------------------------------------------- сбор файлов (отправитель)

function Get-Manifest([string[]]$Roots) {
    $files = New-Object Collections.ArrayList
    $dirs = New-Object Collections.ArrayList
    $seen = @{}
    $errors = New-Object Collections.ArrayList
    foreach ($root in $Roots) {
        $full = [IO.Path]::GetFullPath($root)
        if ([IO.File]::Exists($full)) {
            $fi = New-Object IO.FileInfo($full)
            if (-not $seen.ContainsKey($fi.Name)) {
                $seen[$fi.Name] = 1
                [void]$files.Add(@{ Rel = $fi.Name; Full = $fi.FullName; Size = $fi.Length; Time = $fi.LastWriteTimeUtc.Ticks })
            }
            continue
        }
        $di = New-Object IO.DirectoryInfo($full)
        $name = $di.Name.TrimEnd('\')
        if ($null -eq $di.Parent) { $name = 'Disk_' + $di.FullName.Substring(0, 1) }
        $stack = New-Object Collections.Stack
        $stack.Push(@($di, $name))
        while ($stack.Count -gt 0) {
            $item = $stack.Pop()
            $d = $item[0]; $relDir = $item[1]
            [void]$dirs.Add($relDir)
            try { $entries = $d.GetFileSystemInfos() }
            catch { [void]$errors.Add("$($d.FullName): $($_.Exception.Message)"); continue }
            foreach ($e in $entries) {
                $rel = $relDir + '\' + $e.Name
                if ($e -is [IO.DirectoryInfo]) {
                    # Ссылки/джанкшены не обходим, чтобы не зациклиться
                    if (($e.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                    $stack.Push(@($e, $rel))
                }
                elseif (-not $seen.ContainsKey($rel)) {
                    $seen[$rel] = 1
                    [void]$files.Add(@{ Rel = $rel; Full = $e.FullName; Size = $e.Length; Time = $e.LastWriteTimeUtc.Ticks })
                }
            }
        }
    }
    foreach ($er in $errors) { Write-Warn "Нет доступа: $er"; Write-Log "SCAN $er" }
    return @{ Files = $files; Dirs = $dirs }
}

function Read-SourcePaths {
    $list = @()
    Write-Host ''
    Write-Host 'Перетащите папку (или файл) в это окно либо вставьте путь и нажмите Enter.' -ForegroundColor White
    Write-Host 'Можно добавить несколько. Когда всё добавлено - просто нажмите Enter.' -ForegroundColor Gray
    while ($true) {
        $prompt = 'Путь'
        if ($list.Count -gt 0) { $prompt = 'Ещё путь (Enter = готово)' }
        $line = Read-Host $prompt
        if ([string]::IsNullOrWhiteSpace($line)) {
            if ($list.Count -gt 0) { break }
            continue
        }
        foreach ($p in (Get-CleanPaths $line)) {
            if (Test-Path -LiteralPath $p) {
                $fp = (Resolve-Path -LiteralPath $p).ProviderPath
                if ($list -notcontains $fp) { $list += $fp; Write-Ok "Добавлено: $fp" }
            }
            else { Write-Fail "Не найдено: $p" }
        }
    }
    return , $list
}

# ---------------------------------------------------------------- сессии передачи
# Протокол: манифест (папки, файлы, размеры) -> получатель отвечает, сколько байт каждого файла у него уже есть
# -> отправитель досылает только недостающее. Поэтому обрыв = просто новая сессия с того же места.

function Invoke-SendSession([IO.Stream]$Net, $Manifest, [long]$TotalAll) {
    $w = New-Object IO.BinaryWriter($Net, [Text.Encoding]::UTF8)
    $r = New-Object IO.BinaryReader($Net, [Text.Encoding]::UTF8)
    $files = $Manifest.Files

    $w.Write([int]$Manifest.Dirs.Count)
    foreach ($d in $Manifest.Dirs) { $w.Write([string]$d) }
    $w.Write([int]$files.Count)
    foreach ($f in $files) { $w.Write([string]$f.Rel); $w.Write([long]$f.Size); $w.Write([long]$f.Time) }
    $w.Flush()

    $ok = $r.ReadBoolean()
    $msg = $r.ReadString()
    if (-not $ok) { throw (New-FatalError "Получатель отказал: $msg") }
    if ($msg) { Write-Info $msg }
    $offsets = New-Object 'long[]' $files.Count
    for ($i = 0; $i -lt $files.Count; $i++) { $offsets[$i] = $r.ReadInt64() }

    $done = [long]0
    foreach ($o in $offsets) { $done += $o }
    if ($done -gt 0) { Write-Info ("Уже есть у получателя: {0} - продолжаю с этого места." -f (Format-Size $done)) }

    $buf = New-Object byte[] $BufferSize
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $script:SessionBytes = 0
    $failed = New-Object Collections.ArrayList
    for ($i = 0; $i -lt $files.Count; $i++) {
        $f = $files[$i]
        $off = $offsets[$i]
        if ($off -ge $f.Size) { continue }
        try { $fs = New-Object IO.FileStream($f.Full, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite, 65536) }
        catch {
            [void]$failed.Add($f.Rel); Write-Log "READ $($f.Full): $($_.Exception.Message)"
            continue
        }
        try {
            $w.Write([int]$i); $w.Flush()
            [void]$fs.Seek($off, [IO.SeekOrigin]::Begin)
            $left = $f.Size - $off
            while ($left -gt 0) {
                $want = [int][Math]::Min([long]$buf.Length, $left)
                $n = $fs.Read($buf, 0, $want)
                if ($n -le 0) { throw "Файл стал меньше во время передачи: $($f.Full)" }
                $Net.Write($buf, 0, $n)
                $left -= $n; $done += $n; $script:SessionBytes += $n
                Show-Progress $done $TotalAll $watch $f.Rel
            }
        }
        finally { $fs.Close() }
    }
    $w.Write([int]-1); $w.Flush()
    Show-Progress $done $TotalAll $watch '' -Force
    Write-Host ''
    [void]$r.ReadBoolean()
    return @{ Problems = $failed }
}

function Test-SafeRel([string]$Rel) {
    if ([string]::IsNullOrWhiteSpace($Rel)) { return $false }
    if ([IO.Path]::IsPathRooted($Rel) -or $Rel.Contains(':')) { return $false }
    foreach ($part in $Rel.Split('\')) { if ($part -eq '..' -or $part -eq '.' -or $part -eq '') { return $false } }
    if ($Rel.IndexOfAny([IO.Path]::GetInvalidPathChars()) -ge 0) { return $false }
    return $true
}

function Invoke-ReceiveSession([IO.Stream]$Net, [string]$DestRoot) {
    $w = New-Object IO.BinaryWriter($Net, [Text.Encoding]::UTF8)
    $r = New-Object IO.BinaryReader($Net, [Text.Encoding]::UTF8)

    $dirCount = $r.ReadInt32()
    $dirs = New-Object Collections.ArrayList
    for ($i = 0; $i -lt $dirCount; $i++) { [void]$dirs.Add($r.ReadString().Replace('/', '\')) }
    $count = $r.ReadInt32()
    $files = New-Object 'object[]' $count
    $total = [long]0
    for ($i = 0; $i -lt $count; $i++) {
        $rel = $r.ReadString().Replace('/', '\'); $size = $r.ReadInt64(); $time = $r.ReadInt64()
        $files[$i] = @{ Rel = $rel; Size = $size; Time = $time }
        $total += $size
    }

    $bad = $null
    foreach ($d in $dirs) { if (-not (Test-SafeRel $d)) { $bad = $d; break } }
    if (-not $bad) { foreach ($f in $files) { if (-not (Test-SafeRel $f.Rel)) { $bad = $f.Rel; break } } }
    if ($bad) {
        $w.Write($false); $w.Write("Недопустимый путь: $bad"); $w.Flush()
        throw (New-FatalError "Отправитель прислал недопустимый путь: $bad")
    }

    foreach ($d in $dirs) { [void][IO.Directory]::CreateDirectory((Join-Path $DestRoot $d)) }

    $offsets = New-Object 'long[]' $count
    $need = [long]0
    for ($i = 0; $i -lt $count; $i++) {
        $f = $files[$i]
        $final = Join-Path $DestRoot $f.Rel
        $part = $final + '.dftpart'
        $f.Final = $final; $f.Part = $part
        $off = [long]0
        if ([IO.File]::Exists($final) -and (New-Object IO.FileInfo($final)).Length -eq $f.Size) { $off = $f.Size }
        elseif ($f.Size -eq 0) {
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($final))
            [IO.File]::WriteAllBytes($final, (New-Object byte[] 0))
            try { [IO.File]::SetLastWriteTimeUtc($final, (New-Object DateTime($f.Time, [DateTimeKind]::Utc))) } catch {}
        }
        elseif ([IO.File]::Exists($part)) {
            $pl = (New-Object IO.FileInfo($part)).Length
            if ($pl -le $f.Size) { $off = $pl }
        }
        $offsets[$i] = $off
        $need += ($f.Size - $off)
    }

    $root = [IO.Path]::GetPathRoot($DestRoot)
    $free = (New-Object IO.DriveInfo($root)).AvailableFreeSpace
    $have = $total - $need
    if ($free -lt ($need + 50MB)) {
        $m = "Мало места на диске $root у получателя: нужно ещё $(Format-Size $need), свободно $(Format-Size $free)."
        $w.Write($false); $w.Write($m); $w.Flush()
        throw (New-FatalError $m)
    }
    $w.Write($true); $w.Write("У получателя свободно $(Format-Size $free), нужно $(Format-Size $need).")
    foreach ($o in $offsets) { $w.Write([long]$o) }
    $w.Flush()

    Write-Info ("Входящие: {0} файлов, {1}. Уже есть: {2}." -f $count, (Format-Size $total), (Format-Size $have))
    $buf = New-Object byte[] $BufferSize
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $script:SessionBytes = 0
    $done = $have
    while ($true) {
        $idx = $r.ReadInt32()
        if ($idx -eq -1) { break }
        if ($idx -lt 0 -or $idx -ge $count -or $offsets[$idx] -ge $files[$idx].Size) { throw "Неверный номер файла $idx" }
        $f = $files[$idx]
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($f.Part))
        $fs = New-Object IO.FileStream($f.Part, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::Write, [IO.FileShare]::None, 65536)
        try {
            $fs.SetLength($offsets[$idx])
            [void]$fs.Seek($offsets[$idx], [IO.SeekOrigin]::Begin)
            $left = $f.Size - $offsets[$idx]
            while ($left -gt 0) {
                $want = [int][Math]::Min([long]$buf.Length, $left)
                $n = $Net.Read($buf, 0, $want)
                if ($n -le 0) { throw 'Соединение закрыто другой стороной.' }
                $fs.Write($buf, 0, $n)
                $left -= $n; $done += $n; $script:SessionBytes += $n
                Show-Progress $done $total $watch $f.Rel
            }
        }
        finally { $fs.Close() }
        if ([IO.File]::Exists($f.Final)) {
            [IO.File]::SetAttributes($f.Final, [IO.FileAttributes]::Normal)
            [IO.File]::Delete($f.Final)
        }
        [IO.File]::Move($f.Part, $f.Final)
        try { [IO.File]::SetLastWriteTimeUtc($f.Final, (New-Object DateTime($f.Time, [DateTimeKind]::Utc))) } catch {}
        $offsets[$idx] = $f.Size
    }
    Show-Progress $done $total $watch '' -Force
    Write-Host ''
    $w.Write($true); $w.Flush()

    $missing = New-Object Collections.ArrayList
    for ($i = 0; $i -lt $count; $i++) { if ($offsets[$i] -lt $files[$i].Size) { [void]$missing.Add($files[$i].Rel) } }
    return @{ Problems = $missing }
}

# ---------------------------------------------------------------- сеть

function Parse-Code([string]$Text) {
    if (-not $Text) { return $null }
    $t = $Text.Trim().Trim('"', "'", ' ')
    if ($t -notmatch '^(?<hosts>.+):(?<port>\d{1,5}):(?<pin>\d{4,10})$') { return $null }
    $hosts = @()
    foreach ($h in $Matches['hosts'].Split(',')) { $h = $h.Trim().Trim('[', ']'); if ($h) { $hosts += $h } }
    return @{ Hosts = $hosts; Port = [int]$Matches['port']; Pin = $Matches['pin'] }
}

function Connect-Peer($CodeInfo) {
    foreach ($h in $CodeInfo.Hosts) {
        $addrs = @()
        $a = $null
        if ([Net.IPAddress]::TryParse($h, [ref]$a)) { $addrs = @($a) }
        else { try { $addrs = [Net.Dns]::GetHostAddresses($h) } catch { continue } }
        foreach ($ip in $addrs) {
            $c = New-Object Net.Sockets.TcpClient($ip.AddressFamily)
            try {
                $ar = $c.BeginConnect($ip, $CodeInfo.Port, $null, $null)
                if ($ar.AsyncWaitHandle.WaitOne(7000)) {
                    $c.EndConnect($ar)
                    if ($c.Connected) { return $c }
                }
            }
            catch {}
            $c.Close()
        }
    }
    return $null
}

function Initialize-Client([Net.Sockets.TcpClient]$Client) {
    $Client.NoDelay = $true
    $Client.ReceiveTimeout = 120000
    $Client.SendTimeout = 120000
    $Client.SendBufferSize = 1MB
    $Client.ReceiveBufferSize = 1MB
    $Client.Client.SetSocketOption([Net.Sockets.SocketOptionLevel]::Socket, [Net.Sockets.SocketOptionName]::KeepAlive, $true)
}

# Рукопожатие: подключающийся сообщает PIN и свою роль, ожидающий проверяет.
function Send-Hello([IO.Stream]$Net, [string]$PinCode, [string]$Role) {
    $w = New-Object IO.BinaryWriter($Net, [Text.Encoding]::UTF8)
    $r = New-Object IO.BinaryReader($Net, [Text.Encoding]::UTF8)
    $w.Write($Magic); $w.Write($PinCode); $w.Write($Role); $w.Flush()
    $ok = $r.ReadBoolean(); $msg = $r.ReadString()
    if (-not $ok) { throw (New-FatalError $msg) }
}

function Receive-Hello([IO.Stream]$Net, [string]$PinCode, [string]$MyRole) {
    $w = New-Object IO.BinaryWriter($Net, [Text.Encoding]::UTF8)
    $r = New-Object IO.BinaryReader($Net, [Text.Encoding]::UTF8)
    if ($r.ReadString() -ne $Magic) { return $false }
    $p = $r.ReadString(); $role = $r.ReadString()
    if ($p -ne $PinCode) {
        Start-Sleep -Seconds 2
        $w.Write($false); $w.Write('Неверный PIN в коде подключения.'); $w.Flush()
        Write-Warn 'Кто-то подключился с неверным PIN - отклонено.'
        return $false
    }
    if ($role -eq $MyRole) {
        $m = 'Обе стороны выбрали одно и то же. Один должен ОТПРАВЛЯТЬ, другой ПОЛУЧАТЬ.'
        $w.Write($false); $w.Write($m); $w.Flush(); Write-Warn $m
        return $false
    }
    $w.Write($true); $w.Write(''); $w.Flush()
    return $true
}

function Show-Code([string]$Text) {
    Write-Host ''
    Write-Host '  ================ КОД ПОДКЛЮЧЕНИЯ ================' -ForegroundColor Green
    Write-Host ''
    Write-Host "     $Text     " -ForegroundColor White -BackgroundColor DarkGreen
    Write-Host ''
    Write-Host '  ==================================================' -ForegroundColor Green
    try { Set-Clipboard -Value $Text; Write-Host '  Код уже скопирован - вставьте его в мессенджер и отправьте второй стороне.' -ForegroundColor Gray }
    catch { Write-Host '  Выделите код мышью, нажмите Enter (копировать) и отправьте второй стороне.' -ForegroundColor Gray }
    Write-Host ''
}

# Соединение + сессия с повторами: после обрыва новая сессия продолжает с того же места.
function Invoke-Transfer([string]$Role, [bool]$IsListener, $CodeInfo, [scriptblock]$Work) {
    if ($IsListener) {
        $pinCode = $Pin
        if (-not $pinCode) { $pinCode = '{0:D6}' -f (Get-Random -Minimum 100000 -Maximum 1000000) }
        $listener = $null
        try {
            try {
                $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::IPv6Any, $Port)
                $listener.Server.DualMode = $true
                $listener.Start()
            }
            catch {
                $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Any, $Port)
                $listener.Start()
            }
            Open-FirewallPort $Port

            $hosts = @()
            if ($Local) { $hosts = @('127.0.0.1') }
            else {
                Write-Info 'Открываю порт на роутере и определяю внешний адрес...'
                $gw = Open-UpnpPort $Port
                $v4 = Get-PublicIPv4
                $v6 = Get-PublicIPv6
                if ($v4) { $hosts += $v4 }
                if ($v6) { $hosts += "[$v6]" }
                if (-not $hosts) { throw (New-FatalError 'Нет интернета: не удалось определить внешний IP.') }
                if ($gw -and $gw.External -and $v4 -and ($gw.External -ne $v4 -or (Test-PrivateIPv4 $gw.External))) {
                    Write-Warn "Провайдер дал роутеру серый адрес ($($gw.External)), поэтому по IPv4 к этому ПК снаружи, скорее всего, не подключиться."
                    if ($v6) { Write-Info 'Но есть IPv6 - он тоже в коде, отправитель попробует его.' }
                    else { Write-Warn 'Если отправитель не подключится - поменяйтесь: здесь пункт 4, у отправителя пункт 3.' }
                }
            }
            Show-Code (($hosts -join ',') + (':{0}:{1}' -f $Port, $pinCode))
            Write-Info 'Жду подключения второй стороны... (Ctrl+C - отмена)'

            while ($true) {
                if (-not $listener.Pending()) { Start-Sleep -Milliseconds 200; continue }
                $client = $listener.AcceptTcpClient()
                try {
                    Initialize-Client $client
                    $client.ReceiveTimeout = 15000
                    $net = $client.GetStream()
                    if (-not (Receive-Hello $net $pinCode $Role)) { continue }
                    $client.ReceiveTimeout = 120000
                    Write-Ok "Подключено: $($client.Client.RemoteEndPoint)"
                    return (& $Work $net)
                }
                catch [ApplicationException] { Write-Host ''; Write-Fail $_.Exception.Message; return $null }
                catch {
                    Write-Host ''
                    Write-Warn "Связь прервалась: $($_.Exception.Message)"
                    Write-Log "NET $($_.Exception.Message)"
                    Write-Info 'Жду повторного подключения - передача продолжится с того же места...'
                }
                finally { $client.Close() }
            }
        }
        catch [ApplicationException] { Write-Fail $_.Exception.Message; return $null }
        finally {
            if ($listener) { $listener.Stop() }
            Close-UpnpPort $Port
            Close-FirewallPort
        }
    }
    else {
        $attempt = 0
        while ($true) {
            $attempt++
            Write-Info "Подключаюсь к $($CodeInfo.Hosts -join ' / ') ..."
            $client = Connect-Peer $CodeInfo
            if (-not $client) {
                if ($attempt -ge 3) {
                    Write-Warn 'Не подключается. Проверьте, что вторая сторона ждёт подключения и код верный.'
                    Write-Warn 'Если так и не подключится - поменяйтесь: у отправителя пункт 3, у получателя пункт 4.'
                }
                Write-Info 'Повтор через 5 секунд... (Ctrl+C - отмена)'
                Start-Sleep -Seconds 5
                continue
            }
            try {
                Initialize-Client $client
                $net = $client.GetStream()
                Send-Hello $net $CodeInfo.Pin $Role
                Write-Ok "Подключено к $($client.Client.RemoteEndPoint)"
                $attempt = 0
                return (& $Work $net)
            }
            catch [ApplicationException] { Write-Host ''; Write-Fail $_.Exception.Message; return $null }
            catch {
                Write-Host ''
                Write-Warn "Связь прервалась: $($_.Exception.Message)"
                Write-Log "NET $($_.Exception.Message)"
                Write-Info 'Переподключаюсь через 5 секунд - передача продолжится с того же места...'
                Start-Sleep -Seconds 5
            }
            finally { $client.Close() }
        }
    }
}

function Read-Code {
    while ($true) {
        $t = Read-Host 'Вставьте КОД ПОДКЛЮЧЕНИЯ от второй стороны (правый клик = вставить)'
        $c = Parse-Code $t
        if ($c) { return $c }
        Write-Fail 'Код не похож на правильный. Пример: 85.12.34.56:42873:123456'
    }
}

# ---------------------------------------------------------------- режимы

function Start-Send([bool]$IsListener) {
    $src = $Paths
    if (-not $src) { $src = Read-SourcePaths }
    foreach ($p in $src) { if (-not (Test-Path -LiteralPath $p)) { Write-Fail "Не найдено: $p"; return } }
    Write-Info 'Считаю файлы...'
    $manifest = Get-Manifest $src
    $total = [long]0
    foreach ($f in $manifest.Files) { $total += $f.Size }
    Write-Host ''
    Write-Host ("Найдено: {0} пап., {1} файлов, всего {2}" -f $manifest.Dirs.Count, $manifest.Files.Count, (Format-Size $total)) -ForegroundColor White
    if ($Mode -eq 'Menu') {
        $a = Read-Host 'Начать? (Enter = да, N = отмена)'
        if ($a -match '^[nNнН]') { return }
    }
    $codeInfo = $null
    if (-not $IsListener) {
        if ($Code) { $codeInfo = Parse-Code $Code; if (-not $codeInfo) { Write-Fail 'Неверный -Code'; return } }
        else { $codeInfo = Read-Code }
    }
    Write-Log "SEND start: $($src -join ' | ') files=$($manifest.Files.Count) bytes=$total"
    $res = Invoke-Transfer 'send' $IsListener $codeInfo { param($net) Invoke-SendSession $net $manifest $total }
    if ($null -eq $res) { return }
    Write-Host ''
    if ($res.Problems.Count -gt 0) {
        Write-Warn "Не удалось прочитать $($res.Problems.Count) файл(ов) (заняты/нет доступа). Лог: $LogFile"
        $res.Problems | Select-Object -First 20 | ForEach-Object { Write-Host "   $_" -ForegroundColor Yellow }
    }
    else { Write-Ok 'ГОТОВО. Всё передано.' }
    Write-Log "SEND done, problems=$($res.Problems.Count)"
}

function Start-Receive([bool]$IsListener) {
    $defaultDest = 'C:\Users\owner\Downloads\Torrents'
    if (-not (Test-Path -LiteralPath 'C:\Users\owner')) { $defaultDest = Join-Path $env:USERPROFILE 'Downloads\Torrents' }
    $d = $Dest
    if (-not $d) {
        Write-Host ''
        Write-Host "Куда сохранить? Enter = $defaultDest" -ForegroundColor White
        $line = Read-Host 'Папка (можно перетащить)'
        $d = $defaultDest
        if (-not [string]::IsNullOrWhiteSpace($line)) { $d = (Get-CleanPaths $line)[0] }
    }
    $d = [IO.Path]::GetFullPath($d)
    [void][IO.Directory]::CreateDirectory($d)
    Write-Ok "Сохраняю в: $d"
    $codeInfo = $null
    if (-not $IsListener) {
        if ($Code) { $codeInfo = Parse-Code $Code; if (-not $codeInfo) { Write-Fail 'Неверный -Code'; return } }
        else { $codeInfo = Read-Code }
    }
    Write-Log "RECV start: $d"
    $res = Invoke-Transfer 'recv' $IsListener $codeInfo { param($net) Invoke-ReceiveSession $net $d }
    if ($null -eq $res) { return }
    Write-Host ''
    if ($res.Problems.Count -gt 0) {
        Write-Warn "Не получено $($res.Problems.Count) файл(ов) - отправитель не смог их прочитать:"
        $res.Problems | Select-Object -First 20 | ForEach-Object { Write-Host "   $_" -ForegroundColor Yellow }
    }
    else { Write-Ok "ГОТОВО. Всё получено в: $d" }
    Write-Log "RECV done, problems=$($res.Problems.Count)"
    if ($Mode -eq 'Menu') { try { Start-Process explorer.exe $d } catch {} }
}

# ---------------------------------------------------------------- запуск

Write-Title "Прямая передача папок ПК -> ПК  v$ScriptVersion"

if ($Mode -eq 'Send') { Start-Send ([bool]$Listen); return }
if ($Mode -eq 'Receive') { Start-Receive (-not $Code); return }

Write-Host ''
Write-Host '  1 - ОТПРАВИТЬ папки' -ForegroundColor White
Write-Host '  2 - ПОЛУЧИТЬ папки' -ForegroundColor White
Write-Host ''
Write-Host '  Если 1 и 2 не смогли соединиться (провайдер закрыл входящие):' -ForegroundColor Gray
Write-Host '  3 - ОТПРАВИТЬ (ждать подключения получателя)' -ForegroundColor Gray
Write-Host '  4 - ПОЛУЧИТЬ (подключиться к отправителю по его коду)' -ForegroundColor Gray
Write-Host ''
$choice = ''
while ($choice -notmatch '^[1-4]$') { $choice = ([string](Read-Host 'Выберите 1-4')).Trim() }
switch ($choice) {
    '1' { Start-Send $false }
    '2' { Start-Receive $true }
    '3' { Start-Send $true }
    '4' { Start-Receive $false }
}
