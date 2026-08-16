# Runs the Windows App Certification Kit (WACK) against the OmniChat MSIX.
# Usage (elevated): powershell -NoProfile -ExecutionPolicy Bypass -File tool/run_wack.ps1
$ErrorActionPreference = 'Continue'

$appcert = 'C:\Program Files (x86)\Windows Kits\10\App Certification Kit\appcert.exe'
$root    = Split-Path -Parent $PSScriptRoot
$msix    = Join-Path $root 'build\windows\x64\runner\Release\OmniChat.msix'
$report  = Join-Path $root 'build\wack_report.xml'

if (-not (Test-Path $msix)) {
    Write-Host "MSIX not found: $msix"
    exit 2
}

Write-Host "Running WACK on $msix ..."
$appxArgs = @(
    'test',
    '/apptype', 'appx',
    '/appxPackagePath', $msix,
    '/reportoutputpath', $report
)
& $appcert @appxArgs
$code = $LASTEXITCODE
Write-Host "appcert exit code: $code"
Write-Host "Report: $report"
exit $code
