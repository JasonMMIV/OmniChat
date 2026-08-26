# Exports the working OmniChat dev signing certificate to windows/certs\omnichat_dev.pfx.
# The cert lives in Cert:\CurrentUser\My (thumbprint 14400D0709E999163C8ADF0DB5FA4D6225226128,
# subject CN=OmniChat Dev). Its subject MUST stay identical to the AppxManifest Publisher
# ("CN=OmniChat Dev") or SignTool fails with SignerSign() 0x8007000b.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tool/export_dev_pfx.ps1 [-Password omnichat]
param(
    [string]$Password = 'omnichat'
)
$ErrorActionPreference = 'Stop'

$cert = Get-ChildItem Cert:\CurrentUser\My |
    Where-Object { $_.Thumbprint -eq '14400D0709E999163C8ADF0DB5FA4D6225226128' }
if (-not $cert) { throw 'Dev signing cert 14400D07... not found in Cert:\CurrentUser\My' }

$root = Split-Path -Parent $PSScriptRoot
$pfxPath = Join-Path $root 'windows\certs\omnichat_dev.pfx'
$pass = ConvertTo-SecureString -String $Password -Force -AsPlainText
Export-PfxCertificate -Cert $cert -FilePath $pfxPath -Password $pass | Out-Null
Write-Host ("Exported " + $cert.SubjectName.Name + " -> " + $pfxPath)
