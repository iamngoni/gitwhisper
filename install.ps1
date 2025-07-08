# Check for admin privileges
$IsAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
if (-not $IsAdmin) {
  Write-Error "❌ Please run this script as Administrator."
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

$downloadUrl = "https://github.com/$repo/releases/download/$version/gitwhisper-windows.tar.gz"
$tmpDir = "$env:TEMP\gitwhisper-install"
$installDir = "$env:ProgramFiles\GitWhisper"

Write-Host "⬇️  Downloading GitWhisper $version..."

# Prepare install dirs
if (Test-Path $tmpDir) { Remove-Item $tmpDir -Recurse -Force }
New-Item -ItemType Directory -Path $tmpDir | Out-Null
New-Item -ItemType Directory -Force -Path $installDir | Out-Null

# Download + extract
Invoke-WebRequest -Uri $downloadUrl -OutFile "$tmpDir\gitwhisper.tar.gz"
tar -xzf "$tmpDir\gitwhisper.tar.gz" -C $tmpDir

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
