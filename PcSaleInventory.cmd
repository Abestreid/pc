@echo off
setlocal
title PC Sale Inventory - Windows 7 / 10 / 11
set "PC_SCRIPT=%TEMP%\PcSaleInventory.ps1"
set "PC_LOADER=%TEMP%\PcInventoryDownload.vbs"
>"%PC_LOADER%" echo Option Explicit
>>"%PC_LOADER%" echo Dim h, s
>>"%PC_LOADER%" echo Set h = CreateObject("WinHttp.WinHttpRequest.5.1")
>>"%PC_LOADER%" echo h.SetTimeouts 15000, 15000, 120000, 120000
>>"%PC_LOADER%" echo h.Open "GET", "https://raw.githubusercontent.com/Abestreid/pc/refs/heads/main/PcSaleInventory.ps1", False
>>"%PC_LOADER%" echo h.Option(9) = 2048
>>"%PC_LOADER%" echo h.Send
>>"%PC_LOADER%" echo If h.Status ^<^> 200 Then WScript.Echo "Download failed: HTTP " ^& h.Status : WScript.Quit 1
>>"%PC_LOADER%" echo Set s = CreateObject("ADODB.Stream")
>>"%PC_LOADER%" echo s.Type = 1
>>"%PC_LOADER%" echo s.Open
>>"%PC_LOADER%" echo s.Write h.ResponseBody
>>"%PC_LOADER%" echo s.SaveToFile WScript.Arguments(0), 2
>>"%PC_LOADER%" echo s.Close
cscript.exe //nologo "%PC_LOADER%" "%PC_SCRIPT%"
if errorlevel 1 goto download_error
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PC_SCRIPT%"
set "PC_RESULT=%ERRORLEVEL%"
pause
exit /b %PC_RESULT%
:download_error
echo Unable to download the script. Check Internet access and Windows TLS 1.2 support.
pause
exit /b 1
