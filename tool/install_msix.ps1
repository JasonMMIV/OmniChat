# Installs build\windows\x64\runner\Release\OmniChat.msix for the current user.
# If an existing package with the same Identity Name but a different Publisher is
# present, it is removed first (Windows refuses cross-publisher upgrades).
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$msix = Join-Path $root 'build\windows\x64\runner\Release\OmniChat.msix'
$name = 'com.psyche.omnichat'

if (-not (Test-Path $msix)) {
    throw "MSIX not found: $msix. Run flutter build windows --release first."
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead($msix)
try {
    $sqliteEntry = $zip.Entries | Where-Object { $_.FullName -eq 'sqlite3.dll' }
    if (-not $sqliteEntry) {
        throw "sqlite3.dll is missing from $msix. SQLite chat storage would fall back to Hive; rebuild the release bundle."
    }

    $entry = $zip.Entries | Where-Object { $_.FullName -eq 'AppxManifest.xml' }
    if (-not $entry) {
        throw "AppxManifest.xml is missing from $msix."
    }
    $reader = New-Object System.IO.StreamReader($entry.Open())
    try {
        $manifest = $reader.ReadToEnd()
    } finally {
        $reader.Close()
    }
} finally {
    $zip.Dispose()
}

$existing = Get-AppxPackage -Name $name
if ($existing) {
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
