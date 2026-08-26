# Signs build\windows\x64\runner\Release\OmniChat.msix with the OmniChat dev cert
# from Cert:\CurrentUser\My, then verifies the signature.
#
# Why not msix:create's built-in signing? The AppxManifest Publisher must exactly
# equal the signing cert subject ("CN=OmniChat Dev"); any mismatch makes SignTool
# fail with "SignerSign() failed" (-2147024885 / 0x8007000b). This script pins the
# cert by thumbprint so packaging and signing can't drift apart.
#
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tool/sign_msix.ps1 [-MsixPath <path>]
param(
    [string]$MsixPath = ''
)
$ErrorActionPreference = 'Stop'

$thumbprint = '14400D0709E999163C8ADF0DB5FA4D6225226128'   # CN=OmniChat Dev

$cert = Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Thumbprint -eq $thumbprint }
if (-not $cert) { throw "Dev signing cert $thumbprint not found in Cert:\CurrentUser\My" }

$root = Split-Path -Parent $PSScriptRoot
if (-not $MsixPath) { $MsixPath = Join-Path $root 'build\windows\x64\runner\Release\OmniChat.msix' }
if (-not (Test-Path $MsixPath)) { throw "MSIX not found: $MsixPath" }

$signtool = 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\signtool.exe'

& $signtool sign /fd SHA256 /sha1 $thumbprint $MsixPath
if ($LASTEXITCODE -ne 0) { throw "signtool sign failed with exit code $LASTEXITCODE" }

Write-Host "`nVerifying ..."
& $signtool verify /pa $MsixPath
if ($LASTEXITCODE -ne 0) { throw "signtool verify failed with exit code $LASTEXITCODE" }
Write-Host "`nSigned OK."
