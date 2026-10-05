# PC scripts

Набор простых PowerShell-скриптов для Windows.

## Как запустить PowerShell

Все команды ниже лучше запускать **от имени администратора**.

### Windows 7

1. Нажмите **Пуск**.
2. В поиске введите `PowerShell`.
3. Нажмите правой кнопкой на **Windows PowerShell**.
4. Выберите **Запуск от имени администратора**.
5. Скопируйте нужную команду ниже, вставьте в окно PowerShell и нажмите **Enter**.

### Windows 10

1. Нажмите **Пуск**.
2. Введите `PowerShell`.
3. Нажмите правой кнопкой на **Windows PowerShell**.
4. Выберите **Запуск от имени администратора**.
5. Вставьте нужную команду и нажмите **Enter**.

### Windows 11

1. Нажмите **Пуск**.
2. Введите `PowerShell`.
3. Откройте **Windows PowerShell** или **Терминал** от имени администратора.
4. Вставьте нужную команду и нажмите **Enter**.

---

## 1. Проблемы с активацией Windows или Office

Если Windows или Office постоянно показывает уведомление об активации, просит ввести ключ или перейти к активации. Используйте только для своей лицензированной копии Windows/Office.

```powershell
[Net.ServicePointManager]::SecurityProtocol = 3072; iex ((New-Object Net.WebClient).DownloadString('https://get.activated.win/'))
```

Это внешний проект **Microsoft Activation Scripts (MAS)**, а не наш скрипт.

---

## 2. Старый офисный ПК тормозит - быстро оптимизировать Windows

Для старых или слабых офисных компьютеров на Windows 10/11. Скрипт отключает много ненужных фоновых компонентов Windows и настраивает систему под браузер, CRM, MicroSIP и обычную офисную работу.

```powershell
[Net.ServicePointManager]::SecurityProtocol = 3072; iex ((New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/Abestreid/pc/main/OfficeLiteOptimizer.ps1'))
```

Скрипт: `OfficeLiteOptimizer.ps1`.

---

## 3. Лень искать, скачивать и устанавливать Office вручную

Автоматическая установка Microsoft Office. Скрипт сам определяет Windows, разрядность, объем ОЗУ и язык системы, скачивает официальный Office Deployment Tool и устанавливает Office с серверов Microsoft.

```powershell
[Net.ServicePointManager]::SecurityProtocol = 3072; iex ((New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/Abestreid/pc/main/OfficeAutoInstaller.ps1'))
```

Скрипт: `OfficeAutoInstaller.ps1`.

По умолчанию устанавливается **Office Professional 2024 Retail**. Язык выбирается по языку Windows. Если Office уже установлен, скрипт ничего поверх него не ставит. Активацию Office этот скрипт не выполняет.

Windows 7/8/8.1 скрипт распознает, но современный Office на них не устанавливает.


---

## 4. Передать большие папки напрямую между Windows 10 и Windows 11

Скрипт: \`DirectFolderTransfer.ps1\`.

Запускается одинаково на обоих компьютерах. PowerShell:

\`\`\`powershell
$u="https://raw.githubusercontent.com/Abestreid/pc/main/DirectFolderTransfer.ps1"; $f="$env:TEMP\DirectFolderTransfer.ps1"; Invoke-WebRequest $u -OutFile $f; powershell.exe -NoProfile -ExecutionPolicy Bypass -File $f
\`\`\`

Дальше:

1. На принимающем Windows 11 выбрать \`2 - ПОЛУЧАТЕЛЬ\`.
2. Путь по умолчанию: \`C:\Users\owner\Downloads\Torrents\`. Можно вставить или перетащить другой путь.
3. Получатель покажет \`КОД ПОДКЛЮЧЕНИЯ\`.
4. На отправляющем Windows 10 выбрать \`1 - ОТПРАВИТЕЛЬ\`.
5. Вставить код подключения.
6. Перетащить или вставить путь к первой папке, затем ко второй и т.д.
7. Пустой Enter завершает выбор. Скрипт покажет число файлов и общий объем, после подтверждения начнет передачу.

Передаются все вложенные папки и файлы с сохранением структуры. При обрыве незавершенный файл сохраняется как \`.pctransfer.part\`; повторный запуск продолжает его с уже записанного места.

Для защищенного соединения используется Tailscale. Если его нет, скрипт предложит установить актуальную стабильную версию с официального сервера Tailscale. Публичный IP, проброс портов на роутере и открытие SMB/445 не требуются.
