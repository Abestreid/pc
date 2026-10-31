@echo off
setlocal
title PC Sale Inventory - Windows 7 / 10 / 11
set "PC_SCRIPT=%TEMP%\PcSaleInventory-%RANDOM%-%RANDOM%.ps1"
set "PC_LOADER=%TEMP%\PcInventoryDownload-%RANDOM%.vbs"
set "PC_CHECKER=%TEMP%\PcInventoryCheck-%RANDOM%.ps1"
set "PC_EXPECTED_SHA256=91836ff59f2e7bd567afcab7b09268a859220032bb8be44610f4fda9089122b1"
>"%PC_LOADER%" echo Option Explicit
>>"%PC_LOADER%" echo Dim h, s, lastError
>>"%PC_LOADER%" echo Function Fetch(url)
>>"%PC_LOADER%" echo     On Error Resume Next
>>"%PC_LOADER%" echo     Fetch = False
>>"%PC_LOADER%" echo     Err.Clear
>>"%PC_LOADER%" echo     Set h = CreateObject("WinHttp.WinHttpRequest.5.1")
>>"%PC_LOADER%" echo     h.SetTimeouts 15000, 15000, 30000, 30000
>>"%PC_LOADER%" echo     h.Open "GET", url, False
>>"%PC_LOADER%" echo     If Err.Number ^<^> 0 Then
>>"%PC_LOADER%" echo         lastError = Err.Description
>>"%PC_LOADER%" echo         Exit Function
>>"%PC_LOADER%" echo     End If
>>"%PC_LOADER%" echo     If Left(url, 6) = "https:" Then
>>"%PC_LOADER%" echo         h.Option(9) = 2048
>>"%PC_LOADER%" echo         Err.Clear
>>"%PC_LOADER%" echo     End If
>>"%PC_LOADER%" echo     h.Send
>>"%PC_LOADER%" echo     If Err.Number ^<^> 0 Then
>>"%PC_LOADER%" echo         lastError = Err.Description
>>"%PC_LOADER%" echo         Exit Function
>>"%PC_LOADER%" echo     End If
>>"%PC_LOADER%" echo     If h.Status ^<^> 200 Then
>>"%PC_LOADER%" echo         lastError = "HTTP " ^& h.Status
>>"%PC_LOADER%" echo         Exit Function
>>"%PC_LOADER%" echo     End If
>>"%PC_LOADER%" echo     Set s = CreateObject("ADODB.Stream")
>>"%PC_LOADER%" echo     s.Type = 1
>>"%PC_LOADER%" echo     s.Open
>>"%PC_LOADER%" echo     s.Write h.ResponseBody
>>"%PC_LOADER%" echo     s.SaveToFile WScript.Arguments(0), 2
>>"%PC_LOADER%" echo     s.Close
>>"%PC_LOADER%" echo     If Err.Number ^<^> 0 Then
>>"%PC_LOADER%" echo         lastError = Err.Description
>>"%PC_LOADER%" echo         Exit Function
>>"%PC_LOADER%" echo     End If
>>"%PC_LOADER%" echo     Fetch = True
>>"%PC_LOADER%" echo End Function
>>"%PC_LOADER%" echo If Fetch("https://raw.githubusercontent.com/Abestreid/pc/afd48134ff24f16123b6e32b7b9f2f76c4a57a75/PcSaleInventory.ps1") Then WScript.Quit 0
>>"%PC_LOADER%" echo If Fetch("https://test.abeslab.by/pc/PcSaleInventory.ps1") Then WScript.Quit 0
>>"%PC_LOADER%" echo If Fetch("http://test.abeslab.by/pc/PcSaleInventory.ps1") Then WScript.Quit 0
>>"%PC_LOADER%" echo WScript.Echo "Download failed: " ^& lastError
>>"%PC_LOADER%" echo WScript.Quit 1
>"%PC_CHECKER%" echo param([string]$Path)
>>"%PC_CHECKER%" echo $ErrorActionPreference = 'Stop'
>>"%PC_CHECKER%" echo $sha = [Security.Cryptography.SHA256]::Create()
>>"%PC_CHECKER%" echo try { $actual = [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($Path))).Replace('-','').ToLowerInvariant() }
>>"%PC_CHECKER%" echo finally { $sha.Clear() }
>>"%PC_CHECKER%" echo if ($actual -ne $env:PC_EXPECTED_SHA256) { throw 'Downloaded script integrity check failed. Download a fresh PcSaleInventory.cmd from https://test.abeslab.by/pc/' }
>>"%PC_CHECKER%" echo ^& $Path
cscript.exe //nologo "%PC_LOADER%" "%PC_SCRIPT%"
if errorlevel 1 goto download_error
if not exist "%PC_SCRIPT%" goto download_error
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PC_CHECKER%" -Path "%PC_SCRIPT%"
set "PC_RESULT=%ERRORLEVEL%"
pause
exit /b %PC_RESULT%
:download_error
echo Unable to download the script. Check Internet access.
pause
exit /b 1
