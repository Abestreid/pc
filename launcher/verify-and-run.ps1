param([string]$Path)
$ErrorActionPreference = 'Stop'
$sha = [Security.Cryptography.SHA256]::Create()
try { $actual = [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($Path))).Replace('-','').ToLowerInvariant() }
finally { $sha.Clear() }
if ($actual -ne $env:PC_EXPECTED_SHA256) { throw 'Downloaded script integrity check failed. Download a fresh PcSaleInventory.cmd from https://test.abeslab.by/pc/' }
& $Path
