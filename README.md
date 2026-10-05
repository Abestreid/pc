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

На обоих компьютерах запустите:

\`\`\`powershell
$u="https://raw.githubusercontent.com/Abestreid/pc/main/DirectFolderTransfer.ps1"; $f="$env:TEMP\DirectFolderTransfer.ps1"; Invoke-WebRequest $u -OutFile $f; powershell.exe -NoProfile -ExecutionPolicy Bypass -File $f
\`\`\`

Порядок:

1. На Windows 11 выбрать \`2 - ПОЛУЧАТЕЛЬ\`.
2. Указать папку назначения. По умолчанию: \`C:\Users\owner\Downloads\Torrents\`.
3. Оставить окно открытым. Никаких кодов, паролей или IP копировать не нужно.
4. На Windows 10 выбрать \`1 - ОТПРАВИТЕЛЬ\`.
5. Перетащить или вставить пути к нужным папкам/файлам.
6. Пустой Enter завершает выбор.
7. Отправитель автоматически найдет компьютер, где запущен режим получателя, через Tailscale.
8. Подтвердить передачу.

Сохраняются все вложенные папки и файлы. Незавершенный файл хранится с суффиксом \`.pctransfer.part\`; при повторном запуске передача продолжается.

Tailscale используется как защищенная сеть между компьютерами. Публичный IP, проброс портов и SMB/445 не нужны.
