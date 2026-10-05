#requires -Version 5.1
<#
PC Direct Folder Transfer
Windows 10 / Windows 11

Сценарий:
- Получатель запускает режим 2 и выбирает папку назначения.
- Отправитель запускает режим 1, выбирает папки/файлы.
- Отправитель автоматически находит получателя среди Tailscale-устройств.
- Паролей, токенов и кодов подключения нет.
#>

[CmdletBinding()]
param(
    [ValidateSet("Menu","Sender","Receiver")]
    [string]$Mode = "Menu",
    [string[]]$Source,
    [string]$Destination,
    [int]$Port = 42873
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$ProtocolVersion = 2
$BufferSize = 1MB
$FirewallRule = $null
$LogFile = $null

function Write-Info([string]$Text) { Write-Host "[INFO] $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text)   { Write-Host "[OK]   $Text" -ForegroundColor Green }
function Write-Warn([string]$Text) { Write-Host "[WARN] $Text" -ForegroundColor Yellow }

function Init-Log {
    $dir = Join-Path $env:LOCALAPPDATA "PCDirectTransfer\logs"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $script:LogFile = Join-Path $dir ("transfer-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
}

function Log([string]$Text) {
    if ($script:LogFile) {
        Add-Content -LiteralPath $script:LogFile -Value ("{0:u} {1}" -f (Get-Date), $Text) -Encoding UTF8
    }
}

function Is-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Restart-ReceiverAsAdmin {
    if (-not $PSCommandPath) {
        throw "Не удалось определить путь к скрипту для перезапуска."
    }

    Write-Warn "Для получателя нужны права администратора для временного правила Windows Firewall."
    Write-Info "Подтвердите запрос UAC."

    $args = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", ('"{0}"' -f $PSCommandPath),
        "-Mode", "Receiver",
        "-Port", $Port
    )

    if (-not [string]::IsNullOrWhiteSpace($Destination)) {
        $args += @("-Destination", ('"{0}"' -f $Destination))
    }

    Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList ($args -join " ")
    exit
}

function Find-Tailscale {
    $cmd = Get-Command tailscale.exe -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    $paths = @(
        (Join-Path $env:ProgramFiles "Tailscale\tailscale.exe"),
        (Join-Path $env:LOCALAPPDATA "Tailscale\tailscale.exe")
    )

    foreach ($path in $paths) {
        if (Test-Path -LiteralPath $path) {
            return $path
        }
    }

    return $null
}

function Install-Tailscale {
    Write-Warn "Tailscale не установлен."
    $answer = Read-Host "Установить Tailscale автоматически? [Y/n]"
    if ($answer -and $answer -notmatch '^(y|yes|д|да)$') {
        throw "Без Tailscale передача не запускается."
    }

    $installer = Join-Path $env:TEMP "tailscale-setup.exe"

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Write-Info "Определяю актуальный официальный установщик Tailscale..."

        $page = Invoke-WebRequest -Uri "https://pkgs.tailscale.com/stable/" -UseBasicParsing
        $matches = [regex]::Matches($page.Content, 'href="(tailscale-setup-(\d+\.\d+\.\d+)\.exe)"')

        if ($matches.Count -eq 0) {
            throw "Не удалось найти установщик Tailscale."
        }

        $items = foreach ($match in $matches) {
            [pscustomobject]@{
                File = $match.Groups[1].Value
                Version = [version]$match.Groups[2].Value
            }
        }

        $latest = $items | Sort-Object Version -Descending | Select-Object -First 1
        $url = "https://pkgs.tailscale.com/stable/" + $latest.File

        Write-Info "Скачиваю Tailscale $($latest.Version)..."
        Invoke-WebRequest -Uri $url -OutFile $installer -UseBasicParsing

        Write-Info "Запускаю установщик..."
        $proc = Start-Process -FilePath $installer -Verb RunAs -PassThru -Wait
        if ($proc.ExitCode -ne 0) {
            Write-Warn "Установщик завершился с кодом $($proc.ExitCode)."
        }
    }
    finally {
        if (Test-Path -LiteralPath $installer) {
            Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
        }
    }

    Start-Sleep -Seconds 2

    $exe = Find-Tailscale
    if (-not $exe) {
        throw "Tailscale не найден после установки."
    }

    return $exe
}

function Ensure-Tailscale {
    $exe = Find-Tailscale

    if (-not $exe) {
        $exe = Install-Tailscale
    }

    Write-Ok "Tailscale найден."
    return $exe
}

function Get-TailscaleIPv4([string]$Exe) {
    $ip = $null

    try {
        $ip = (& $Exe ip -4 2>$null | Select-Object -First 1)
    }
    catch {}

    if ([string]::IsNullOrWhiteSpace($ip)) {
        Write-Warn "Этот компьютер еще не подключен к Tailscale."
        Write-Info "Откроется авторизация. На обоих компьютерах войдите в одну Tailscale-сеть."
        & $Exe up

        for ($i = 0; $i -lt 90; $i++) {
            Start-Sleep -Seconds 2

            try {
                $ip = (& $Exe ip -4 2>$null | Select-Object -First 1)
            }
            catch {}

            if (-not [string]::IsNullOrWhiteSpace($ip)) {
                break
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($ip)) {
        throw "Не удалось получить Tailscale IPv4."
    }

    return $ip.Trim()
}

function Format-Size([int64]$Bytes) {
    if ($Bytes -ge 1TB) { return ("{0:N2} TB" -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ("{0:N2} GB" -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ("{0:N2} MB" -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ("{0:N2} KB" -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

function Read-Exactly {
    param(
        [System.IO.Stream]$Stream,
        [byte[]]$Buffer,
        [int]$Count
    )

    $read = 0

    while ($read -lt $Count) {
        $n = $Stream.Read($Buffer, $read, $Count - $read)

        if ($n -le 0) {
            throw "Соединение закрыто удаленным компьютером."
        }

        $read += $n
    }
}

function Send-Json {
    param(
        [System.IO.Stream]$Stream,
        $Object
    )

    $json = $Object | ConvertTo-Json -Compress -Depth 8
    $payload = [Text.Encoding]::UTF8.GetBytes($json)

    if ($payload.Length -gt 8MB) {
        throw "Слишком большое служебное сообщение."
    }

    $len = [BitConverter]::GetBytes([int]$payload.Length)

    if ([BitConverter]::IsLittleEndian) {
        [Array]::Reverse($len)
    }

    $Stream.Write($len, 0, 4)
    $Stream.Write($payload, 0, $payload.Length)
    $Stream.Flush()
}

function Receive-Json {
    param([System.IO.Stream]$Stream)

    $len = New-Object byte[] 4
    Read-Exactly -Stream $Stream -Buffer $len -Count 4

    if ([BitConverter]::IsLittleEndian) {
        [Array]::Reverse($len)
    }

    $count = [BitConverter]::ToInt32($len, 0)

    if ($count -lt 2 -or $count -gt 8MB) {
        throw "Некорректное служебное сообщение."
    }

    $payload = New-Object byte[] $count
    Read-Exactly -Stream $Stream -Buffer $payload -Count $count

    return ([Text.Encoding]::UTF8.GetString($payload) | ConvertFrom-Json)
}

function Normalize-DraggedPath([string]$Path) {
    if ($null -eq $Path) {
        return $null
    }

    return $Path.Trim().Trim('"').Trim("'")
}

function Get-Entries([string[]]$Paths) {
    $result = New-Object System.Collections.ArrayList

    foreach ($raw in $Paths) {
        $path = Normalize-DraggedPath $raw

        if ([string]::IsNullOrWhiteSpace($path)) {
            continue
        }

        if (-not (Test-Path -LiteralPath $path)) {
            throw "Путь не найден: $path"
        }

        $rootItem = Get-Item -LiteralPath $path -Force

        if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Write-Warn "Пропущена ссылка/reparse point: $($rootItem.FullName)"
            continue
        }

        if (-not $rootItem.PSIsContainer) {
            [void]$result.Add([pscustomobject]@{
                Kind = "File"
                Local = $rootItem.FullName
                Relative = $rootItem.Name
                Length = [int64]$rootItem.Length
                Ticks = [int64]$rootItem.LastWriteTimeUtc.Ticks
            })

            continue
        }

        $root = $rootItem.FullName.TrimEnd("\")
        $rootName = Split-Path -Leaf $root

        [void]$result.Add([pscustomobject]@{
            Kind = "Directory"
            Local = $root
            Relative = $rootName
            Length = [int64]0
            Ticks = [int64]$rootItem.LastWriteTimeUtc.Ticks
        })

        $children = Get-ChildItem -LiteralPath $root -Force -Recurse -ErrorAction Stop

        foreach ($item in $children) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                Write-Warn "Пропущена ссылка/reparse point: $($item.FullName)"
                continue
            }

            $relativeInside = $item.FullName.Substring($root.Length).TrimStart("\")
            $relative = Join-Path $rootName $relativeInside

            if ($item.PSIsContainer) {
                [void]$result.Add([pscustomobject]@{
                    Kind = "Directory"
                    Local = $item.FullName
                    Relative = $relative
                    Length = [int64]0
                    Ticks = [int64]$item.LastWriteTimeUtc.Ticks
                })
            }
            else {
                [void]$result.Add([pscustomobject]@{
                    Kind = "File"
                    Local = $item.FullName
                    Relative = $relative
                    Length = [int64]$item.Length
                    Ticks = [int64]$item.LastWriteTimeUtc.Ticks
                })
            }
        }
    }

    return ,$result
}

function Get-SafePath {
    param(
        [string]$Root,
        [string]$Relative
    )

    if ([string]::IsNullOrWhiteSpace($Relative)) {
        throw "Получен пустой путь."
    }

    $rel = $Relative.Replace("/", "\")

    if ([IO.Path]::IsPathRooted($rel)) {
        throw "Заблокирован абсолютный удаленный путь."
    }

    $base = [IO.Path]::GetFullPath($Root).TrimEnd("\") + "\"
    $full = [IO.Path]::GetFullPath((Join-Path $base $rel))

    if (-not $full.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Заблокирован выход за пределы папки назначения."
    }

    return $full
}

function Get-FreeBytes([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    $drive = New-Object IO.DriveInfo($root)

    return [int64]$drive.AvailableFreeSpace
}

function Add-TemporaryFirewallRule {
    param(
        [string]$Ip,
        [int]$ListenPort
    )

    if (-not (Is-Admin)) {
        throw "Для получателя нужны права администратора."
    }

    $name = "PC Direct Transfer $Ip $ListenPort"

    Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule -ErrorAction SilentlyContinue

    $firewallArgs = @{
        DisplayName = $name
        Direction = "Inbound"
        Action = "Allow"
        Protocol = "TCP"
        LocalAddress = $Ip
        LocalPort = $ListenPort
        RemoteAddress = "100.64.0.0/10"
        Profile = "Any"
    }

    New-NetFirewallRule @firewallArgs | Out-Null

    $script:FirewallRule = $name
    Write-Ok "Windows Firewall настроен для Tailscale TCP/$ListenPort."
}

function Remove-TemporaryFirewallRule {
    if ($script:FirewallRule) {
        Get-NetFirewallRule -DisplayName $script:FirewallRule -ErrorAction SilentlyContinue |
            Remove-NetFirewallRule -ErrorAction SilentlyContinue

        $script:FirewallRule = $null
    }
}

function Get-TailscalePeers([string]$Exe) {
    $jsonText = (& $Exe status --json 2>$null | Out-String)

    if ([string]::IsNullOrWhiteSpace($jsonText)) {
        throw "Tailscale не вернул список устройств."
    }

    $status = $jsonText | ConvertFrom-Json
    $result = New-Object System.Collections.ArrayList

    if ($null -eq $status.Peer) {
        return @()
    }

    foreach ($property in $status.Peer.PSObject.Properties) {
        $peer = $property.Value

        if ($peer.Online -ne $true) {
            continue
        }

        $ip = $null

        foreach ($candidate in @($peer.TailscaleIPs)) {
            if ([string]$candidate -match '^100\.') {
                $ip = [string]$candidate
                break
            }
        }

        if ([string]::IsNullOrWhiteSpace($ip)) {
            continue
        }

        $name = [string]$peer.HostName

        if ([string]::IsNullOrWhiteSpace($name)) {
            $name = [string]$peer.DNSName
        }

        if ([string]::IsNullOrWhiteSpace($name)) {
            $name = $ip
        }

        [void]$result.Add([pscustomobject]@{
            Name = $name.TrimEnd(".")
            Ip = $ip
        })
    }

    return @($result)
}

function Test-TcpPort {
    param(
        [string]$Ip,
        [int]$RemotePort,
        [int]$TimeoutMs = 900
    )

    $client = New-Object Net.Sockets.TcpClient

    try {
        $async = $client.BeginConnect($Ip, $RemotePort, $null, $null)

        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs)) {
            return $false
        }

        $client.EndConnect($async)
        return $client.Connected
    }
    catch {
        return $false
    }
    finally {
        $client.Close()
    }
}

function Find-Receiver {
    param(
        [string]$Exe,
        [int]$ReceiverPort
    )

    Write-Host ""
    Write-Info "Ищу компьютер, на котором запущен режим ПОЛУЧАТЕЛЬ..."

    for ($attempt = 1; $attempt -le 12; $attempt++) {
        $peers = @(Get-TailscalePeers $Exe)
        $found = New-Object System.Collections.ArrayList

        foreach ($peer in $peers) {
            Write-Host ("  Проверяю {0} ({1})..." -f $peer.Name, $peer.Ip) -ForegroundColor DarkGray

            if (Test-TcpPort -Ip $peer.Ip -RemotePort $ReceiverPort) {
                [void]$found.Add($peer)
            }
        }

        if ($found.Count -eq 1) {
            Write-Ok "Получатель найден автоматически: $($found[0].Name) ($($found[0].Ip))"
            return $found[0]
        }

        if ($found.Count -gt 1) {
            Write-Host ""
            Write-Warn "Найдено несколько компьютеров-получателей:"

            for ($i = 0; $i -lt $found.Count; $i++) {
                Write-Host ("{0} - {1} ({2})" -f ($i + 1), $found[$i].Name, $found[$i].Ip)
            }

            $choiceText = Read-Host "Выберите номер"
            $choice = 0

            if (-not [int]::TryParse($choiceText, [ref]$choice)) {
                throw "Неверный номер."
            }

            if ($choice -lt 1 -or $choice -gt $found.Count) {
                throw "Неверный номер."
            }

            return $found[$choice - 1]
        }

        if ($attempt -lt 12) {
            Write-Warn "Получатель пока не найден. Попытка $attempt/12. Жду 2 секунды..."
            Start-Sleep -Seconds 2
        }
    }

    throw "Получатель не найден. На Windows 11 сначала запустите этот же скрипт, выберите 2 - ПОЛУЧАТЕЛЬ и оставьте окно открытым."
}

function Show-Route {
    param(
        [string]$Exe,
        [string]$Target
    )

    Write-Info "Проверяю маршрут Tailscale..."

    try {
        $lines = @(& $Exe ping --c 3 $Target 2>&1)
        $lines | ForEach-Object { Write-Host "  $_" }

        $direct = $false

        foreach ($line in $lines) {
            $text = [string]$line

            if ($text -match '\svia\s' -and $text -notmatch 'DERP' -and $text -notmatch 'peer-relay') {
                $direct = $true
            }
        }

        if ($direct) {
            Write-Ok "Подтвержден прямой P2P-маршрут."
        }
        else {
            Write-Warn "Прямой маршрут не подтвержден. Tailscale может использовать зашифрованный relay."
        }
    }
    catch {
        Write-Warn "Проверка маршрута не удалась, продолжаю подключение."
    }
}

function Receive-Session {
    param(
        [Net.Sockets.TcpClient]$Client,
        [string]$Root
    )

    $stream = $Client.GetStream()
    $stream.ReadTimeout = 300000
    $stream.WriteTimeout = 300000

    $hello = Receive-Json $stream

    if ($hello.type -ne "hello" -or [int]$hello.protocol -ne $ProtocolVersion) {
        Send-Json $stream @{
            type = "error"
            message = "Несовместимая версия скрипта. Обновите скрипт на обоих компьютерах."
        }

        throw "Несовместимая версия протокола."
    }

    Send-Json $stream @{
        type = "hello-ok"
        computer = $env:COMPUTERNAME
    }

    Write-Ok "Подключен отправитель: $($hello.computer)"

    $summary = Receive-Json $stream

    if ($summary.type -ne "summary") {
        throw "Не получена информация об объеме передачи."
    }

    $totalBytes = [int64]$summary.totalBytes
    $totalFiles = [int]$summary.totalFiles
    $free = Get-FreeBytes $Root

    Write-Info "Будет принято: $totalFiles файлов, $(Format-Size $totalBytes)."
    Write-Info "Свободно: $(Format-Size $free)."

    Send-Json $stream @{
        type = "summary-ok"
        freeBytes = $free
    }

    $receivedFiles = 0
    $receivedBytes = [int64]0

    while ($true) {
        $msg = Receive-Json $stream

        if ($msg.type -eq "done") {
            Send-Json $stream @{
                type = "done-ok"
                files = $receivedFiles
                bytes = $receivedBytes
            }

            Write-Ok "Передача завершена: $receivedFiles файлов, $(Format-Size $receivedBytes)."
            return
        }

        if ($msg.type -eq "directory") {
            $dir = Get-SafePath -Root $Root -Relative ([string]$msg.path)
            New-Item -ItemType Directory -Path $dir -Force | Out-Null

            Send-Json $stream @{
                type = "directory-ok"
            }

            continue
        }

        if ($msg.type -ne "file") {
            throw "Неизвестная команда: $($msg.type)"
        }

        $dest = Get-SafePath -Root $Root -Relative ([string]$msg.path)
        $parent = Split-Path -Parent $dest

        New-Item -ItemType Directory -Path $parent -Force | Out-Null

        $length = [int64]$msg.length
        $ticks = [int64]$msg.ticks

        if (Test-Path -LiteralPath $dest -PathType Leaf) {
            $existing = Get-Item -LiteralPath $dest -Force

            if ([int64]$existing.Length -eq $length -and [int64]$existing.LastWriteTimeUtc.Ticks -eq $ticks) {
                Send-Json $stream @{
                    type = "ready"
                    offset = $length
                    skip = $true
                }

                $endMessage = Receive-Json $stream

                if ($endMessage.type -ne "file-end") {
                    throw "Ошибка протокола после пропущенного файла."
                }

                Send-Json $stream @{
                    type = "file-ok"
                    skipped = $true
                }

                $receivedFiles++
                $receivedBytes += $length
                continue
            }
        }

        $part = $dest + ".pctransfer.part"
        $offset = [int64]0

        if (Test-Path -LiteralPath $part -PathType Leaf) {
            $offset = [int64](Get-Item -LiteralPath $part -Force).Length

            if ($offset -gt $length) {
                Remove-Item -LiteralPath $part -Force
                $offset = 0
            }
        }

        $remaining = $length - $offset
        $freeNow = Get-FreeBytes $Root

        if ($freeNow -lt $remaining) {
            Send-Json $stream @{
                type = "error"
                message = "Недостаточно свободного места для $($msg.path). Нужно $(Format-Size $remaining), доступно $(Format-Size $freeNow)."
            }

            throw "Недостаточно свободного места."
        }

        Send-Json $stream @{
            type = "ready"
            offset = $offset
            skip = $false
        }

        $fileStream = New-Object IO.FileStream(
            $part,
            [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None,
            $BufferSize,
            [IO.FileOptions]::SequentialScan
        )

        try {
            $fileStream.Position = $offset
            $buffer = New-Object byte[] $BufferSize
            $done = [int64]0

            while ($done -lt $remaining) {
                $need = [int][Math]::Min([int64]$buffer.Length, $remaining - $done)
                $n = $stream.Read($buffer, 0, $need)

                if ($n -le 0) {
                    throw "Соединение оборвалось при получении $($msg.path)."
                }

                $fileStream.Write($buffer, 0, $n)
                $done += $n
            }

            $fileStream.Flush()
        }
        finally {
            $fileStream.Dispose()
        }

        $fileEnd = Receive-Json $stream

        if ($fileEnd.type -ne "file-end") {
            throw "Ошибка протокола после файла."
        }

        $actual = [int64](Get-Item -LiteralPath $part -Force).Length

        if ($actual -ne $length) {
            throw "Размер принятого файла не совпал: $($msg.path)."
        }

        if (Test-Path -LiteralPath $dest) {
            Remove-Item -LiteralPath $dest -Force
        }

        Move-Item -LiteralPath $part -Destination $dest -Force
        [IO.File]::SetLastWriteTimeUtc(
            $dest,
            (New-Object DateTime($ticks, [DateTimeKind]::Utc))
        )

        Send-Json $stream @{
            type = "file-ok"
            skipped = $false
        }

        $receivedFiles++
        $receivedBytes += $length

        Write-Ok "Получен: $($msg.path)"
    }
}

function Run-Receiver([string]$Exe) {
    if (-not (Is-Admin)) {
        Restart-ReceiverAsAdmin
    }

    $ip = Get-TailscaleIPv4 $Exe
    $defaultPath = "C:\Users\owner\Downloads\Torrents"

    if ([string]::IsNullOrWhiteSpace($Destination)) {
        Write-Host ""
        $entered = Read-Host "Папка для загрузки [Enter = $defaultPath]"

        if ([string]::IsNullOrWhiteSpace($entered)) {
            $script:Destination = $defaultPath
        }
        else {
            $script:Destination = Normalize-DraggedPath $entered
        }
    }

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $root = [IO.Path]::GetFullPath($Destination)

    Add-TemporaryFirewallRule -Ip $ip -ListenPort $Port

    $listener = New-Object Net.Sockets.TcpListener(
        [Net.IPAddress]::Parse($ip),
        $Port
    )

    $listener.Start()

    try {
        Clear-Host

        Write-Host "============================================================" -ForegroundColor DarkCyan
        Write-Host "              ПОЛУЧАТЕЛЬ ГОТОВ" -ForegroundColor Green
        Write-Host "============================================================" -ForegroundColor DarkCyan
        Write-Host ""
        Write-Host "Папка назначения:"
        Write-Host "  $root" -ForegroundColor White
        Write-Host ""
        Write-Host "Ничего копировать и отправлять НЕ НУЖНО." -ForegroundColor Yellow
        Write-Host "На другом компьютере выберите 1 - ОТПРАВИТЕЛЬ."
        Write-Host "Он найдет этот компьютер автоматически."
        Write-Host ""
        Write-Host "Не закрывайте это окно."
        Write-Host "============================================================"
        Write-Host ""

        while ($true) {
            Write-Info "ОЖИДАЮ ОТПРАВИТЕЛЯ..."

            $client = $listener.AcceptTcpClient()

            try {
                Write-Info "Подключение от $($client.Client.RemoteEndPoint)"
                Receive-Session -Client $client -Root $root
                break
            }
            catch {
                $message = $_.Exception.Message
                Write-Warn $message
                Log $_.Exception.ToString()

                try {
                    if ($client -and $client.Connected) {
                        Send-Json $client.GetStream() @{
                            type = "error"
                            message = "Ошибка на принимающем ПК: $message"
                        }
                    }
                }
                catch {}
            }
            finally {
                $client.Close()
            }
        }
    }
    finally {
        $listener.Stop()
        Remove-TemporaryFirewallRule
    }
}

function Read-Sources {
    $list = New-Object System.Collections.ArrayList

    Write-Host ""
    Write-Host "Перетащите папку/файл в это окно или вставьте путь."
    Write-Host "Можно добавить несколько папок."
    Write-Host "Пустой Enter - закончить выбор."
    Write-Host ""

    while ($true) {
        $raw = Read-Host "Путь"

        if ([string]::IsNullOrWhiteSpace($raw)) {
            break
        }

        $path = Normalize-DraggedPath $raw

        if (-not (Test-Path -LiteralPath $path)) {
            Write-Warn "Не найдено: $path"
            continue
        }

        [void]$list.Add($path)
        Write-Ok "Добавлено: $path"
    }

    return @($list)
}

function Send-Entries {
    param(
        [IO.Stream]$Stream,
        $Entries
    )

    $files = @($Entries | Where-Object { $_.Kind -eq "File" })
    $totalFiles = $files.Count
    $totalBytes = [int64]0

    foreach ($file in $files) {
        $totalBytes += [int64]$file.Length
    }

    Send-Json $Stream @{
        type = "summary"
        totalFiles = $totalFiles
        totalBytes = $totalBytes
    }

    $summaryAck = Receive-Json $Stream

    if ($summaryAck.type -eq "error") {
        throw [string]$summaryAck.message
    }

    if ($summaryAck.type -ne "summary-ok") {
        throw "Получатель не подтвердил начало передачи."
    }

    Write-Info "Файлов: $totalFiles"
    Write-Info "Общий размер: $(Format-Size $totalBytes)"

    $completedFiles = 0
    $completedBytes = [int64]0
    $watch = [Diagnostics.Stopwatch]::StartNew()

    foreach ($entry in $Entries) {
        if ($entry.Kind -eq "Directory") {
            Send-Json $Stream @{
                type = "directory"
                path = $entry.Relative
            }

            $ack = Receive-Json $Stream

            if ($ack.type -eq "error") {
                throw [string]$ack.message
            }

            if ($ack.type -ne "directory-ok") {
                throw "Получатель не подтвердил создание папки."
            }

            continue
        }

        Write-Host ""
        Write-Info ("{0}/{1}: {2} ({3})" -f ($completedFiles + 1), $totalFiles, $entry.Relative, (Format-Size $entry.Length))

        Send-Json $Stream @{
            type = "file"
            path = $entry.Relative
            length = [int64]$entry.Length
            ticks = [int64]$entry.Ticks
        }

        $ready = Receive-Json $Stream

        if ($ready.type -eq "error") {
            throw [string]$ready.message
        }

        if ($ready.type -ne "ready") {
            throw "Получатель не готов принять файл."
        }

        $offset = [int64]$ready.offset

        if ($offset -lt 0 -or $offset -gt [int64]$entry.Length) {
            throw "Получено некорректное смещение продолжения."
        }

        if ($offset -lt [int64]$entry.Length) {
            if ($offset -gt 0) {
                Write-Info "Продолжаю файл с $(Format-Size $offset)."
            }

            $fileStream = New-Object IO.FileStream(
                $entry.Local,
                [IO.FileMode]::Open,
                [IO.FileAccess]::Read,
                [IO.FileShare]::Read,
                $BufferSize,
                [IO.FileOptions]::SequentialScan
            )

            try {
                $fileStream.Position = $offset
                $buffer = New-Object byte[] $BufferSize
                $sent = $offset
                $lastUpdate = [DateTime]::MinValue

                while ($sent -lt [int64]$entry.Length) {
                    $need = [int][Math]::Min(
                        [int64]$buffer.Length,
                        [int64]$entry.Length - $sent
                    )

                    $n = $fileStream.Read($buffer, 0, $need)

                    if ($n -le 0) {
                        throw "Исходный файл неожиданно закончился."
                    }

                    $Stream.Write($buffer, 0, $n)
                    $sent += $n

                    if (((Get-Date) - $lastUpdate).TotalMilliseconds -ge 400 -or $sent -eq [int64]$entry.Length) {
                        if ($entry.Length -gt 0) {
                            $percent = [int](100.0 * $sent / $entry.Length)
                        }
                        else {
                            $percent = 100
                        }

                        $elapsed = [Math]::Max($watch.Elapsed.TotalSeconds, 0.1)
                        $speed = ($completedBytes + $sent) / $elapsed

                        $status = "$(Format-Size $sent) / $(Format-Size $entry.Length) | $(Format-Size ([int64]$speed))/s"

                        Write-Progress -Activity $entry.Relative -Status $status -PercentComplete $percent
                        $lastUpdate = Get-Date
                    }
                }

                $Stream.Flush()
            }
            finally {
                $fileStream.Dispose()
                Write-Progress -Activity $entry.Relative -Completed
            }
        }
        else {
            Write-Info "Файл уже есть у получателя - пропуск."
        }

        Send-Json $Stream @{
            type = "file-end"
        }

        $ack = Receive-Json $Stream

        if ($ack.type -eq "error") {
            throw [string]$ack.message
        }

        if ($ack.type -ne "file-ok") {
            throw "Получатель не подтвердил файл."
        }

        $completedFiles++
        $completedBytes += [int64]$entry.Length

        $elapsed = [Math]::Max($watch.Elapsed.TotalSeconds, 0.1)
        $speed = $completedBytes / $elapsed
        $remaining = [Math]::Max([int64]0, $totalBytes - $completedBytes)

        if ($speed -gt 0) {
            $etaSeconds = [int]($remaining / $speed)
        }
        else {
            $etaSeconds = 0
        }

        $eta = [TimeSpan]::FromSeconds($etaSeconds)

        Write-Ok "Общий прогресс: $completedFiles/$totalFiles | $(Format-Size $completedBytes)/$(Format-Size $totalBytes) | $(Format-Size ([int64]$speed))/s | осталось ~$($eta.ToString('hh\:mm\:ss'))"
    }

    Send-Json $Stream @{
        type = "done"
    }

    $done = Receive-Json $Stream

    if ($done.type -eq "error") {
        throw [string]$done.message
    }

    if ($done.type -ne "done-ok") {
        throw "Получатель не подтвердил завершение."
    }

    $watch.Stop()
}

function Run-Sender([string]$Exe) {
    [void](Get-TailscaleIPv4 $Exe)

    if (-not $Source -or $Source.Count -eq 0) {
        $script:Source = Read-Sources
    }

    if (-not $Source -or $Source.Count -eq 0) {
        throw "Не выбрана ни одна папка или файл."
    }

    Write-Info "Сканирую все папки и подпапки..."
    $entries = Get-Entries -Paths $Source

    if ($entries.Count -eq 0) {
        throw "Нет данных для передачи."
    }

    $fileEntries = @($entries | Where-Object { $_.Kind -eq "File" })
    $totalBytes = [int64]0

    foreach ($file in $fileEntries) {
        $totalBytes += [int64]$file.Length
    }

    Write-Host ""
    Write-Host "Найдено:"
    Write-Host "  Файлов: $($fileEntries.Count)"
    Write-Host "  Размер:  $(Format-Size $totalBytes)"
    Write-Host ""

    $answer = Read-Host "Начать передачу? [Y/n]"

    if ($answer -and $answer -notmatch '^(y|yes|д|да)$') {
        Write-Warn "Передача отменена."
        return
    }

    $receiver = Find-Receiver -Exe $Exe -ReceiverPort $Port

    Show-Route -Exe $Exe -Target $receiver.Ip

    $client = New-Object Net.Sockets.TcpClient

    try {
        Write-Info "Подключаюсь к $($receiver.Name) ($($receiver.Ip))..."

        $async = $client.BeginConnect($receiver.Ip, $Port, $null, $null)

        if (-not $async.AsyncWaitHandle.WaitOne(15000)) {
            throw "Таймаут подключения к получателю."
        }

        $client.EndConnect($async)

        $stream = $client.GetStream()
        $stream.ReadTimeout = 300000
        $stream.WriteTimeout = 300000

        Send-Json $stream @{
            type = "hello"
            protocol = $ProtocolVersion
            computer = $env:COMPUTERNAME
        }

        $hello = Receive-Json $stream

        if ($hello.type -eq "error") {
            throw [string]$hello.message
        }

        if ($hello.type -ne "hello-ok") {
            throw "Получатель вернул неизвестный ответ."
        }

        Write-Ok "Соединение установлено с $($hello.computer)."

        Send-Entries -Stream $stream -Entries $entries

        Write-Host ""
        Write-Ok "ВСЕ ФАЙЛЫ УСПЕШНО ПЕРЕДАНЫ."
    }
    finally {
        $client.Close()
    }
}

function Menu {
    Clear-Host

    Write-Host "============================================================" -ForegroundColor DarkCyan
    Write-Host "     ПРЯМАЯ ПЕРЕДАЧА ПАПОК - WINDOWS 10 / 11" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor DarkCyan
    Write-Host ""
    Write-Host "1 - ОТПРАВИТЕЛЬ"
    Write-Host "2 - ПОЛУЧАТЕЛЬ"
    Write-Host "0 - Выход"
    Write-Host ""

    switch (Read-Host "Выберите") {
        "1" { return "Sender" }
        "2" { return "Receiver" }
        "0" { return "Exit" }
        default { throw "Неверный пункт меню." }
    }
}

try {
    Init-Log

    if ($Mode -eq "Menu") {
        $Mode = Menu

        if ($Mode -eq "Exit") {
            exit
        }
    }

    $tailscale = Ensure-Tailscale

    if ($Mode -eq "Receiver") {
        Run-Receiver $tailscale
    }
    elseif ($Mode -eq "Sender") {
        Run-Sender $tailscale
    }
}
catch {
    Write-Host ""
    Write-Host "[ОШИБКА] $($_.Exception.Message)" -ForegroundColor Red

    Log $_.Exception.ToString()

    if ($LogFile) {
        Write-Host "Лог: $LogFile"
    }

    exit 1
}
finally {
    Remove-TemporaryFirewallRule
}
