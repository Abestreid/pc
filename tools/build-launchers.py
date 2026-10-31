"""Regenerate the Windows launcher and copyable command after any script change."""
import hashlib
import pathlib
import argparse

root = pathlib.Path(__file__).resolve().parents[1]
digest = hashlib.sha256((root / 'PcSaleInventory.ps1').read_bytes()).hexdigest()
parser = argparse.ArgumentParser()
parser.add_argument('--ref', default='refs/heads/main', help='Immutable commit containing the script, preferred for released launchers')
args = parser.parse_args()

def echo_lines(path, target):
    lines = []
    source = path.read_text(encoding='utf-8-sig')
    if path.name == 'download.vbs':
        source = source.replace('/pc/refs/heads/main/PcSaleInventory.ps1', '/pc/' + args.ref + '/PcSaleInventory.ps1')
    for i, line in enumerate(source.splitlines()):
        escaped = line.replace('^', '^^').replace('%', '%%')
        for char in '&|<>':
            escaped = escaped.replace(char, '^' + char)
        lines.append(('>' if i == 0 else '>>') + '"%' + target + '%" echo ' + escaped)
    return lines

lines = [
    '@echo off', 'setlocal', 'title PC Sale Inventory - Windows 7 / 10 / 11',
    'set "PC_SCRIPT=%TEMP%\\PcSaleInventory-%RANDOM%-%RANDOM%.ps1"',
    'set "PC_LOADER=%TEMP%\\PcInventoryDownload-%RANDOM%.vbs"',
    'set "PC_CHECKER=%TEMP%\\PcInventoryCheck-%RANDOM%.ps1"',
    'set "PC_EXPECTED_SHA256=' + digest + '"',
]
lines += echo_lines(root / 'launcher/download.vbs', 'PC_LOADER')
lines += echo_lines(root / 'launcher/verify-and-run.ps1', 'PC_CHECKER')
lines += [
    'cscript.exe //nologo "%PC_LOADER%" "%PC_SCRIPT%"',
    'if errorlevel 1 goto download_error',
    'if not exist "%PC_SCRIPT%" goto download_error',
    'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PC_CHECKER%" -Path "%PC_SCRIPT%"',
    'set "PC_RESULT=%ERRORLEVEL%"', 'pause', 'exit /b %PC_RESULT%',
    ':download_error', 'echo Unable to download the script. Check Internet access.', 'pause', 'exit /b 1',
]
for name in ['PcSaleInventory.cmd', 'PcSaleInventory-Win7.cmd']:
    (root / name).write_bytes(('\r\n'.join(lines) + '\r\n').encode('ascii'))
# A short PS2-compatible alternative; pinning the hash permits HTTP download on old Win7.
command = (
    "$ErrorActionPreference='Stop'; $f=Join-Path $env:TEMP 'PcSaleInventory.ps1'; "
    "(New-Object Net.WebClient).DownloadFile('http://test.abeslab.by/pc/PcSaleInventory.ps1',$f); "
    "$s=[Security.Cryptography.SHA256]::Create(); "
    "$h=[BitConverter]::ToString($s.ComputeHash([IO.File]::ReadAllBytes($f))).Replace('-','').ToLowerInvariant(); $s.Clear(); "
    "if($h -ne '" + digest + "'){throw 'Download verification failed'}; "
    "& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $f"
)
(root / 'launch-command.txt').write_bytes((command + '\r\n').encode('ascii'))
print('Generated launcher and command; pinned script SHA256: ' + digest)
