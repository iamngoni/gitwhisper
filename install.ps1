# Check for admin privileges
$IsAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
if (-not $IsAdmin) {
  Write-Host "`n❌ Please run this script as Administrator.`n" -ForegroundColor Red
  Write-Host "Right-click on PowerShell and select 'Run as administrator'."
  Write-Host "`nPress any key to exit..."
  $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
  exit 1
}

$repo = "iamngoni/gitwhisper"
$apiUrl = "https://api.github.com/repos/$repo/releases/latest"

# Get latest version tag
try {
  Write-Host "📡 Fetching latest release..."
  $headers = @{ 'User-Agent' = 'gitwhisper-installer' }
  $latest = Invoke-RestMethod -Uri $apiUrl -Headers $headers
  $version = $latest.tag_name
  Write-Host "📦 Latest version: $version"
} catch {
  Write-Error "❌ Failed to fetch latest release."
  exit 1
}

$baseUrl = "https://github.com/$repo/releases/download/$version"
$tmpDir = Join-Path $env:TEMP ("gitwhisper-install-" + [guid]::NewGuid().ToString("N"))
$installDir = "$env:ProgramFiles\GitWhisper"

Write-Host "⬇️  Downloading GitWhisper $version..."

# Prepare install dirs
if (Test-Path $tmpDir) { Remove-Item $tmpDir -Recurse -Force }
New-Item -ItemType Directory -Path $tmpDir | Out-Null
New-Item -ItemType Directory -Force -Path $installDir | Out-Null

# Download
$asset = "gitwhisper-windows-x64.tar.gz"
$legacy = $false
try {
  Invoke-WebRequest -Uri "$baseUrl/$asset" -OutFile "$tmpDir\$asset" -Headers $headers
} catch {
  # Releases up to v1.0.8 used a single Windows asset name.
  $asset = "gitwhisper-windows.tar.gz"
  $legacy = $true
  Invoke-WebRequest -Uri "$baseUrl/$asset" -OutFile "$tmpDir\$asset" -Headers $headers
}

# Verify checksum (published from v1.0.9 onwards)
$checksumFile = "$tmpDir\$asset.sha256"
$hasChecksum = $true
try {
  Invoke-WebRequest -Uri "$baseUrl/$asset.sha256" -OutFile $checksumFile -Headers $headers
} catch {
  $hasChecksum = $false
}

if ($hasChecksum) {
  $expected = ((Get-Content $checksumFile -Raw).Trim() -split '\s+')[0].ToLower()
  $actual = (Get-FileHash "$tmpDir\$asset" -Algorithm SHA256).Hash.ToLower()
  if ($expected -ne $actual) {
    Write-Error "❌ Checksum mismatch for $asset (expected $expected, got $actual)."
    exit 1
  }
  Write-Host "🔒 Verified checksum for $asset"
} elseif ($legacy) {
  # Releases up to v1.0.8 published no checksums.
  Write-Warning "$version has no published checksum for $asset; skipping verification."
} else {
  Write-Error "❌ Could not download the checksum for $asset; refusing to install an unverified binary."
  exit 1
}

# Extract
tar -xzf "$tmpDir\$asset" -C $tmpDir

# Move binaries
Move-Item "$tmpDir\gitwhisper.exe" "$installDir\gitwhisper.exe" -Force
Copy-Item "$installDir\gitwhisper.exe" "$installDir\gw.exe" -Force

# Update system PATH if not already added
$envPath = [Environment]::GetEnvironmentVariable("Path", [EnvironmentVariableTarget]::Machine)
if ($envPath -notlike "*$installDir*") {
  [Environment]::SetEnvironmentVariable("Path", "$envPath;$installDir", [EnvironmentVariableTarget]::Machine)
  Write-Host "🔧 Added $installDir to system PATH."
}

Write-Host "✅ Installed gitwhisper and gw to $installDir"
& "$installDir\gitwhisper.exe" --version
