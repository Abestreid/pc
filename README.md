# PC scripts

## 1. Microsoft Activation Scripts (внешний проект)

```powershell
[Net.ServicePointManager]::SecurityProtocol = 3072; iex ((New-Object Net.WebClient).DownloadString('https://get.activated.win/'))
```

## 2. OfficeLiteOptimizer - оптимизация Windows 10/11

```powershell
[Net.ServicePointManager]::SecurityProtocol = 3072; iex ((New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/Abestreid/pc/main/OfficeLiteOptimizer.ps1'))
```

## 3. OfficeAutoInstaller - автоматическая установка Microsoft Office

```powershell
[Net.ServicePointManager]::SecurityProtocol = 3072; iex ((New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/Abestreid/pc/main/OfficeAutoInstaller.ps1'))
```

Скрипт автоматически определяет Windows, архитектуру, объем ОЗУ и язык системы. Язык Office выбирается по языку Windows, разрядность выбирает официальный Office Deployment Tool. По умолчанию устанавливается Office Professional 2024 Retail. Уже установленный Office не удаляется и не перезаписывается. Активация не выполняется.

Windows 7/8/8.1 распознаются, но установка современного Office блокируется, поскольку эти системы не поддерживаются современными версиями Office.
