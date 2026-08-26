# Installs build\windows\x64\runner\Release\OmniChat.msix for the current user.
# If an existing package with the same Identity Name but a different Publisher is
# present, it is removed first (Windows refuses cross-publisher upgrades).
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$msix = Join-Path $root 'build\windows\x64\runner\Release\OmniChat.msix'
$name = 'com.psyche.omnichat'

$existing = Get-AppxPackage -Name $name
if ($existing) {
    # Extract Publisher from the new manifest and compare.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($msix)
    $entry = $zip.Entries | Where-Object { $_.FullName -eq 'AppxManifest.xml' }
    $reader = New-Object System.IO.StreamReader($entry.Open())
    $manifest = $reader.ReadToEnd()
    $reader.Close(); $zip.Dispose()
    if ($manifest -match 'Publisher="([^"]+)"') { $newPublisher = $Matches[1] } else { $newPublisher = '' }

    if ($existing.Publisher -ne $newPublisher) {
        Write-Host ("Removing old package (Publisher '" + $existing.Publisher + "' != '" + $newPublisher + "') ...")
        Remove-AppxPackage -Package $existing.PackageFullName
    } else {
        Write-Host "Existing package has same publisher; upgrading in place."
    }
}

Add-AppxPackage -Path $msix
Get-AppxPackage -Name $name | Select-Object Name, Version, Publisher, InstallLocation | Format-List
