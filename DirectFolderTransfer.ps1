#requires -Version 5.1
<#
PC Direct Folder Transfer
Windows 10 / Windows 11
Secure transport: Tailscale (WireGuard)
#>

[CmdletBinding()]
param(
    [ValidateSet("Menu","Sender","Receiver")]
    [string]$Mode = "Menu",
    [string[]]$Source,
    [string]$Destination,
    [string]$ConnectionCode,
    [int]$Port = 42873
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$ProtocolVersion = 1
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
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Restart-ReceiverAsAdmin {
    if (-not $PSCommandPath) {
        throw "Не удалось определить путь к скрипту для перезапуска от администратора."
    }

    Write-Warn "Для режима получателя нужны права администратора только для временного правила Windows Firewall."
    Write-Info "Сейчас появится запрос UAC."

    $args = @("-NoProfile","-ExecutionPolicy","Bypass","-File",('"{0}"' -f $PSCommandPath),"-Mode","Receiver","-Port",$Port)
    if ($Destination) {
        $args += @("-Destination",('"{0}"' -f $Destination))
    }

    Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList ($args -join " ")
    exit
}

function Find-Tailscale {
    $cmd = Get-Command tailscale.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $paths = @(
        (Join-Path $env:ProgramFiles "Tailscale\tailscale.exe"),
        (Join-Path $env:LOCALAPPDATA "Tailscale\tailscale.exe")
    )

    foreach ($p in $paths) {
        if (Test-Path -LiteralPath $p) { return $p }
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
        Write-Info "Определяю актуальный официальный установщик Tailscale..."
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $page = Invoke-WebRequest -Uri "https://pkgs.tailscale.com/stable/" -UseBasicParsing
        $matches = [regex]::Matches($page.Content, 'href="(tailscale-setup-(\d+\.\d+\.\d+)\.exe)"')
        if ($matches.Count -eq 0) {
            throw "Не удалось найти установщик на официальной странице пакетов."
        }

        $items = foreach ($m in $matches) {
            [pscustomobject]@{
                File = $m.Groups[1].Value
                Version = [version]$m.Groups[2].Value
            }
        }

        $latest = $items | Sort-Object Version -Descending | Select-Object -First 1
        $url = "https://pkgs.tailscale.com/stable/" + $latest.File

        Write-Info "Скачиваю Tailscale $($latest.Version)..."
        Invoke-WebRequest -Uri $url -OutFile $installer -UseBasicParsing

        Write-Info "Запускаю официальный установщик..."
        $proc = Start-Process -FilePath $installer -Verb RunAs -PassThru -Wait
        if ($proc.ExitCode -ne 0) {
            Write-Warn "Установщик вернул код $($proc.ExitCode)."
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
    } catch {}

    if ([string]::IsNullOrWhiteSpace($ip)) {
        Write-Warn "Компьютер еще не подключен к Tailscale."
        Write-Info "Откроется авторизация Tailscale. На обоих компьютерах проще всего войти в один аккаунт."
        & $Exe up

        for ($i = 0; $i -lt 90; $i++) {
            Start-Sleep -Seconds 2
            try {
                $ip = (& $Exe ip -4 2>$null | Select-Object -First 1)
            } catch {}
            if (-not [string]::IsNullOrWhiteSpace($ip)) { break }
        }
    }

    if ([string]::IsNullOrWhiteSpace($ip)) {
        throw "Не удалось получить Tailscale IP. Проверьте, что Tailscale подключен."
    }

    return $ip.Trim()
}

function New-Token {
    $bytes = New-Object byte[] 24
    $rng = New-Object Security.Cryptography.RNGCryptoServiceProvider
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return ([Convert]::ToBase64String($bytes)).TrimEnd("=").Replace("+","-").Replace("/","_")
}

function Format-Size([int64]$Bytes) {
    if ($Bytes -ge 1TB) { return ("{0:N2} TB" -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ("{0:N2} GB" -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ("{0:N2} MB" -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ("{0:N2} KB" -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

function Read-Exactly {
    param([System.IO.Stream]$Stream,[byte[]]$Buffer,[int]$Count)

    $done = 0
    while ($done -lt $Count) {
        $n = $Stream.Read($Buffer, $done, $Count - $done)
        if ($n -le 0) { throw "Соединение закрыто." }
        $done += $n
    }
}

function Send-Json {
    param([System.IO.Stream]$Stream,$Object)

    $json = $Object | ConvertTo-Json -Compress -Depth 8
    $payload = [Text.Encoding]::UTF8.GetBytes($json)
    if ($payload.Length -gt 8MB) { throw "Слишком большое служебное сообщение." }

    $len = [BitConverter]::GetBytes([int]$payload.Length)
    if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($len) }

    $Stream.Write($len,0,4)
    $Stream.Write($payload,0,$payload.Length)
    $Stream.Flush()
}

function Receive-Json {
    param([System.IO.Stream]$Stream)

    $len = New-Object byte[] 4
    Read-Exactly -Stream $Stream -Buffer $len -Count 4
    if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($len) }

    $count = [BitConverter]::ToInt32($len,0)
    if ($count -lt 2 -or $count -gt 8MB) { throw "Некорректное служебное сообщение." }

    $payload = New-Object byte[] $count
    Read-Exactly -Stream $Stream -Buffer $payload -Count $count
    return ([Text.Encoding]::UTF8.GetString($payload) | ConvertFrom-Json)
}

function Normalize-DraggedPath([string]$Path) {
    if ($null -eq $Path) { return $null }
    return $Path.Trim().Trim('"').Trim("'")
}

function Get-Entries([string[]]$Paths) {
    $result = New-Object System.Collections.ArrayList

    foreach ($raw in $Paths) {
        $path = Normalize-DraggedPath $raw
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        if (-not (Test-Path -LiteralPath $path)) { throw "Путь не найден: $path" }

        $rootItem = Get-Item -LiteralPath $path -Force

        if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Write-Warn "Пропущен reparse point: $($rootItem.FullName)"
            continue
        }

        if (-not $rootItem.PSIsContainer) {
            [void]$result.Add([pscustomobject]@{Kind="File";Local=$rootItem.FullName;Relative=$rootItem.Name;Length=[int64]$rootItem.Length;Ticks=[int64]$rootItem.LastWriteTimeUtc.Ticks})
            continue
        }

        $root = $rootItem.FullName.TrimEnd("\")
        $rootName = Split-Path -Leaf $root

        [void]$result.Add([pscustomobject]@{Kind="Directory";Local=$root;Relative=$rootName;Length=[int64]0;Ticks=[int64]$rootItem.LastWriteTimeUtc.Ticks})

        Get-ChildItem -LiteralPath $root -Force -Recurse | ForEach-Object {
            if (($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                Write-Warn "Пропущен reparse point: $($_.FullName)"
                return
            }

            $relativeInside = $_.FullName.Substring($root.Length).TrimStart("\")
            $relative = Join-Path $rootName $relativeInside

            if ($_.PSIsContainer) {
                [void]$result.Add([pscustomobject]@{Kind="Directory";Local=$_.FullName;Relative=$relative;Length=[int64]0;Ticks=[int64]$_.LastWriteTimeUtc.Ticks})
            } else {
                [void]$result.Add([pscustomobject]@{Kind="File";Local=$_.FullName;Relative=$relative;Length=[int64]$_.Length;Ticks=[int64]$_.LastWriteTimeUtc.Ticks})
            }
        }
    }

    return ,$result
}

function Get-SafePath([string]$Root,[string]$Relative) {
    if ([string]::IsNullOrWhiteSpace($Relative)) { throw "Получен пустой путь." }

    $rel = $Relative.Replace("/","\")
    if ([IO.Path]::IsPathRooted($rel)) { throw "Заблокирован абсолютный удаленный путь." }

    $base = [IO.Path]::GetFullPath($Root).TrimEnd("\") + "\"
    $full = [IO.Path]::GetFullPath((Join-Path $base $rel))

    if (-not $full.StartsWith($base,[StringComparison]::OrdinalIgnoreCase)) {
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

function Add-TemporaryFirewallRule([string]$Ip,[int]$ListenPort) {
    if (-not (Is-Admin)) { throw "Нужны права администратора." }

    $name = "PC Direct Transfer $Ip $ListenPort"
    Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue

    $fw = @{
        DisplayName = $name
        Direction = "Inbound"
        Action = "Allow"
        Protocol = "TCP"
        LocalAddress = $Ip
        LocalPort = $ListenPort
        RemoteAddress = "100.64.0.0/10"
        Profile = "Any"
    }
    New-NetFirewallRule @fw | Out-Null

    $script:FirewallRule = $name
    Write-Ok "Firewall разрешен только для сети Tailscale и TCP/$ListenPort."
}

function Remove-TemporaryFirewallRule {
    if ($script:FirewallRule) {
        Get-NetFirewallRule -DisplayName $script:FirewallRule -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
        $script:FirewallRule = $null
    }
}

function Show-Route([string]$Exe,[string]$Target) {
    Write-Info "Проверяю маршрут Tailscale..."
    try {
        $lines = @(& $Exe ping --c 3 $Target 2>&1)
        $lines | ForEach-Object { Write-Host "  $_" }

        $direct = $false
        foreach ($line in $lines) {
            $s = [string]$line
            if ($s -match "\svia\s" -and $s -notmatch "DERP" -and $s -notmatch "peer-relay") { $direct = $true }
        }

        if ($direct) { Write-Ok "Подтвержден прямой P2P-маршрут." }
        else { Write-Warn "Прямой маршрут пока не подтвержден. Tailscale может использовать зашифрованный relay." }
    } catch {
        Write-Warn "Не удалось проверить маршрут, но подключение все равно будет проверено."
    }
}

function Receive-Session {
    param([Net.Sockets.TcpClient]$Client,[string]$ExpectedToken,[string]$Root)

    $stream = $Client.GetStream()
    $stream.ReadTimeout = 300000
    $stream.WriteTimeout = 300000

    $hello = Receive-Json $stream
    if ($hello.type -ne "hello" -or [int]$hello.protocol -ne $ProtocolVersion) {
        Send-Json $stream @{type="error";message="Protocol mismatch"}
        throw "Несовместимая версия протокола."
    }

    if ([string]$hello.token -cne $ExpectedToken) {
        Send-Json $stream @{type="error";message="Invalid token"}
        throw "Неверный код подключения."
    }

    Send-Json $stream @{type="hello-ok";computer=$env:COMPUTERNAME}
    Write-Ok "Подключен отправитель: $($hello.computer)"

    $summary = Receive-Json $stream
    if ($summary.type -ne "summary") { throw "Не получена информация об объеме передачи." }

    $totalBytes = [int64]$summary.totalBytes
    $totalFiles = [int]$summary.totalFiles
    $free = Get-FreeBytes $Root

    Write-Info "Отправитель: $totalFiles файлов, $(Format-Size $totalBytes)."
    Write-Info "Свободно на диске назначения: $(Format-Size $free)."

    if ($free -lt $totalBytes) {
        Write-Warn "Свободного места меньше полного объема передачи. Уже имеющиеся/частично переданные файлы будут учтены по мере передачи."
    }

    Send-Json $stream @{type="summary-ok";freeBytes=$free}

    $receivedFiles = 0
    $receivedBytes = [int64]0

    while ($true) {
        $msg = Receive-Json $stream

        if ($msg.type -eq "done") {
            Send-Json $stream @{type="done-ok";files=$receivedFiles;bytes=$receivedBytes}
            Write-Ok "Передача завершена: $receivedFiles файлов, $(Format-Size $receivedBytes)."
            return
        }

        if ($msg.type -eq "directory") {
            $dir = Get-SafePath $Root ([string]$msg.path)
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Send-Json $stream @{type="directory-ok"}
            continue
        }

        if ($msg.type -ne "file") { throw "Неизвестная команда: $($msg.type)" }

        $dest = Get-SafePath $Root ([string]$msg.path)
        $parent = Split-Path -Parent $dest
        New-Item -ItemType Directory -Path $parent -Force | Out-Null

        $length = [int64]$msg.length
        $ticks = [int64]$msg.ticks

        if (Test-Path -LiteralPath $dest -PathType Leaf) {
            $existing = Get-Item -LiteralPath $dest -Force
            if ([int64]$existing.Length -eq $length -and [int64]$existing.LastWriteTimeUtc.Ticks -eq $ticks) {
                Send-Json $stream @{type="ready";offset=$length;skip=$true}
                $ack = Receive-Json $stream
                if ($ack.type -ne "file-end") { throw "Ошибка синхронизации протокола." }
                Send-Json $stream @{type="file-ok";skipped=$true}
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
            Send-Json $stream @{type="error";message="Недостаточно свободного места для файла $($msg.path). Нужно $(Format-Size $remaining), доступно $(Format-Size $freeNow)."}
            throw "Недостаточно свободного места для файла $($msg.path)."
        }

        Send-Json $stream @{type="ready";offset=$offset;skip=$false}
        $fs = New-Object IO.FileStream($part,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::Write,[IO.FileShare]::None,$BufferSize,[IO.FileOptions]::SequentialScan)

        try {
            $fs.Position = $offset
            $buffer = New-Object byte[] $BufferSize
            $done = [int64]0

            while ($done -lt $remaining) {
                $need = [int][Math]::Min([int64]$buffer.Length,$remaining - $done)
                $n = $stream.Read($buffer,0,$need)
                if ($n -le 0) { throw "Соединение оборвалось при получении $($msg.path)." }
                $fs.Write($buffer,0,$n)
                $done += $n
            }

            $fs.Flush()
        } finally {
            $fs.Dispose()
        }

        $fileEnd = Receive-Json $stream
        if ($fileEnd.type -ne "file-end") { throw "Ошибка синхронизации после файла." }

        $actual = [int64](Get-Item -LiteralPath $part -Force).Length
        if ($actual -ne $length) { throw "Размер файла не совпал: $($msg.path)." }

        if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Force }
        Move-Item -LiteralPath $part -Destination $dest -Force
        [IO.File]::SetLastWriteTimeUtc($dest,(New-Object DateTime($ticks,[DateTimeKind]::Utc)))

        Send-Json $stream @{type="file-ok";skipped=$false}
        $receivedFiles++
        $receivedBytes += $length
        Write-Ok "Получен: $($msg.path)"
    }
}

function Run-Receiver([string]$Exe) {
    if (-not (Is-Admin)) { Restart-ReceiverAsAdmin }

    $ip = Get-TailscaleIPv4 $Exe
    $defaultPath = "C:\Users\owner\Downloads\Torrents"

    if ([string]::IsNullOrWhiteSpace($Destination)) {
        Write-Host ""
        $entered = Read-Host "Папка для загрузки [Enter = $defaultPath]"
        if ([string]::IsNullOrWhiteSpace($entered)) { $script:Destination = $defaultPath }
        else { $script:Destination = Normalize-DraggedPath $entered }
    }

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $root = [IO.Path]::GetFullPath($Destination)

    $token = New-Token
    $code = "$ip|$Port|$token"

    Add-TemporaryFirewallRule $ip $Port
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Parse($ip),$Port)
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
        Write-Host "КОД ПОДКЛЮЧЕНИЯ - отправьте его отправителю:"
        Write-Host ""
        Write-Host "  $code" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Не закрывайте это окно до завершения передачи."
        Write-Host "============================================================"
        Write-Host ""

        while ($true) {
            Write-Info "Ожидаю отправителя..."
            $client = $listener.AcceptTcpClient()
            try {
                Write-Info "Подключение от $($client.Client.RemoteEndPoint)"
                Receive-Session -Client $client -ExpectedToken $token -Root $root
                break
            } catch {
                Write-Warn $_.Exception.Message
                Log $_.Exception.ToString()
            } finally {
                $client.Close()
            }
        }
    } finally {
        $listener.Stop()
        Remove-TemporaryFirewallRule
    }
}

function Read-Sources {
    $list = New-Object System.Collections.ArrayList

    Write-Host ""
    Write-Host "Перетащите папку/файл в это окно или вставьте путь."
    Write-Host "Можно добавлять несколько папок. Пустой Enter - закончить выбор."
    Write-Host ""

    while ($true) {
        $raw = Read-Host "Путь"
        if ([string]::IsNullOrWhiteSpace($raw)) { break }

        $p = Normalize-DraggedPath $raw
        if (-not (Test-Path -LiteralPath $p)) {
            Write-Warn "Не найдено: $p"
            continue
        }

        [void]$list.Add($p)
        Write-Ok "Добавлено: $p"
    }

    return @($list)
}

function Parse-ConnectionCode([string]$Code) {
    $parts = $Code.Trim().Split("|")
    if ($parts.Count -ne 3) { throw "Некорректный код подключения. Нужна строка вида IP|PORT|TOKEN." }

    $parsedPort = 0
    if (-not [int]::TryParse($parts[1],[ref]$parsedPort)) { throw "Некорректный порт в коде подключения." }

    return [pscustomobject]@{Ip=$parts[0];Port=$parsedPort;Token=$parts[2]}
}

function Send-Entries {
    param([IO.Stream]$Stream,$Entries)

    $files = @($Entries | Where-Object { $_.Kind -eq "File" })
    $totalFiles = $files.Count
    $totalBytes = [int64]0
    foreach ($f in $files) { $totalBytes += [int64]$f.Length }

    Send-Json $Stream @{type="summary";totalFiles=$totalFiles;totalBytes=$totalBytes}
    $summaryAck = Receive-Json $Stream
    if ($summaryAck.type -eq "error") { throw $summaryAck.message }
    if ($summaryAck.type -ne "summary-ok") { throw "Получатель не подтвердил свободное место." }

    Write-Info "Файлов: $totalFiles"
    Write-Info "Общий размер: $(Format-Size $totalBytes)"

    $completedFiles = 0
    $completedBytes = [int64]0
    $watch = [Diagnostics.Stopwatch]::StartNew()

    foreach ($entry in $Entries) {
        if ($entry.Kind -eq "Directory") {
            Send-Json $Stream @{type="directory";path=$entry.Relative}
            $ack = Receive-Json $Stream
            if ($ack.type -ne "directory-ok") { throw "Не удалось создать папку у получателя." }
            continue
        }

        Write-Host ""
        Write-Info ("{0}/{1}: {2} ({3})" -f ($completedFiles + 1),$totalFiles,$entry.Relative,(Format-Size $entry.Length))

        Send-Json $Stream @{type="file";path=$entry.Relative;length=[int64]$entry.Length;ticks=[int64]$entry.Ticks}
        $ready = Receive-Json $Stream
        if ($ready.type -eq "error") { throw [string]$ready.message }
        if ($ready.type -ne "ready") { throw "Получатель не готов принять файл." }

        $offset = [int64]$ready.offset
        if ($offset -lt 0 -or $offset -gt [int64]$entry.Length) { throw "Получено некорректное смещение для продолжения." }

        if ($offset -lt [int64]$entry.Length) {
            if ($offset -gt 0) { Write-Info "Продолжение с $(Format-Size $offset)." }

            $fs = New-Object IO.FileStream($entry.Local,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read,$BufferSize,[IO.FileOptions]::SequentialScan)

            try {
                $fs.Position = $offset
                $buffer = New-Object byte[] $BufferSize
                $sent = $offset
                $lastUpdate = [DateTime]::MinValue

                while ($sent -lt [int64]$entry.Length) {
                    $need = [int][Math]::Min([int64]$buffer.Length,[int64]$entry.Length - $sent)
                    $n = $fs.Read($buffer,0,$need)
                    if ($n -le 0) { throw "Исходный файл неожиданно закончился." }

                    $Stream.Write($buffer,0,$n)
                    $sent += $n

                    if (((Get-Date) - $lastUpdate).TotalMilliseconds -ge 400 -or $sent -eq [int64]$entry.Length) {
                        $pct = if ($entry.Length -gt 0) { [int](100.0 * $sent / $entry.Length) } else { 100 }
                        $elapsed = [Math]::Max($watch.Elapsed.TotalSeconds,0.1)
                        $speed = ($completedBytes + $sent) / $elapsed
                        $status = "$(Format-Size $sent) / $(Format-Size $entry.Length) | $(Format-Size ([int64]$speed))/s"
                        Write-Progress -Activity $entry.Relative -Status $status -PercentComplete $pct
                        $lastUpdate = Get-Date
                    }
                }

                $Stream.Flush()
            } finally {
                $fs.Dispose()
                Write-Progress -Activity $entry.Relative -Completed
            }
        } else {
            Write-Info "Уже передан - пропуск."
        }

        Send-Json $Stream @{type="file-end"}
        $ack = Receive-Json $Stream
        if ($ack.type -ne "file-ok") { throw "Получатель не подтвердил файл." }

        $completedFiles++
        $completedBytes += [int64]$entry.Length

        $elapsed = [Math]::Max($watch.Elapsed.TotalSeconds,0.1)
        $speed = $completedBytes / $elapsed
        $remaining = [Math]::Max([int64]0,$totalBytes - $completedBytes)
        $etaSec = if ($speed -gt 0) { [int]($remaining / $speed) } else { 0 }
        $eta = [TimeSpan]::FromSeconds($etaSec)
        $progressText = "Общий прогресс: $completedFiles/$totalFiles, $(Format-Size $completedBytes)/$(Format-Size $totalBytes), $(Format-Size ([int64]$speed))/s, осталось ~$($eta.ToString('hh\:mm\:ss'))"
        Write-Ok $progressText
    }

    Send-Json $Stream @{type="done"}
    $done = Receive-Json $Stream
    if ($done.type -ne "done-ok") { throw "Получатель не подтвердил завершение." }
    $watch.Stop()
}

function Run-Sender([string]$Exe) {
    [void](Get-TailscaleIPv4 $Exe)

    if ([string]::IsNullOrWhiteSpace($ConnectionCode)) {
        Write-Host ""
        $script:ConnectionCode = Read-Host "Вставьте КОД ПОДКЛЮЧЕНИЯ с компьютера-получателя"
    }

    $conn = Parse-ConnectionCode $ConnectionCode

    if (-not $Source -or $Source.Count -eq 0) {
        $script:Source = Read-Sources
    }

    if (-not $Source -or $Source.Count -eq 0) { throw "Не выбрана ни одна папка или файл." }

    Write-Info "Сканирую все папки и подпапки..."
    $entries = Get-Entries $Source
    if ($entries.Count -eq 0) { throw "Нет данных для передачи." }

    $fileEntries = @($entries | Where-Object { $_.Kind -eq "File" })
    $totalBytes = [int64]0
    foreach ($f in $fileEntries) { $totalBytes += [int64]$f.Length }

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

    Show-Route $Exe $conn.Ip

    $client = New-Object Net.Sockets.TcpClient
    try {
        Write-Info "Подключаюсь к $($conn.Ip):$($conn.Port)..."
        $async = $client.BeginConnect($conn.Ip,$conn.Port,$null,$null)
        if (-not $async.AsyncWaitHandle.WaitOne(15000)) { throw "Таймаут подключения. Проверьте получателя и код подключения." }
        $client.EndConnect($async)

        $stream = $client.GetStream()
        $stream.ReadTimeout = 300000
        $stream.WriteTimeout = 300000

        Send-Json $stream @{type="hello";protocol=$ProtocolVersion;token=$conn.Token;computer=$env:COMPUTERNAME}
        $hello = Receive-Json $stream
        if ($hello.type -eq "error") { throw $hello.message }
        if ($hello.type -ne "hello-ok") { throw "Получатель вернул неизвестный ответ." }

        Write-Ok "Соединение установлено с $($hello.computer)."
        Send-Entries -Stream $stream -Entries $entries

        Write-Host ""
        Write-Ok "ВСЕ ФАЙЛЫ УСПЕШНО ПЕРЕДАНЫ."
    } finally {
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
        if ($Mode -eq "Exit") { exit }
    }

    $tailscale = Ensure-Tailscale

    if ($Mode -eq "Receiver") { Run-Receiver $tailscale }
    elseif ($Mode -eq "Sender") { Run-Sender $tailscale }
}
catch {
    Write-Host ""
    Write-Host "[ОШИБКА] $($_.Exception.Message)" -ForegroundColor Red
    Log $_.Exception.ToString()
    if ($LogFile) { Write-Host "Лог: $LogFile" }
    exit 1
}
finally {
    Remove-TemporaryFirewallRule
}
