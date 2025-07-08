param (
  [string]$Version = "latest"
)

$repo = "iamngoni/gitwhisper"
$apiUrl = "https://api.github.com/repos/$repo/releases/latest"

# Determine version if "latest"
if ($Version -eq "latest") {
  try {
    Write-Host "📡 Fetching latest release..."
    $headers = @{ 'User-Agent' = 'gitwhisper-installer' }
    $latest = Invoke-RestMethod -Uri $apiUrl -Headers $headers
    $Version = $latest.tag_name
    Write-Host "📦 Latest version: $Version"
  } catch {
    Write-Error "❌ Failed to fetch latest release. Please specify a version manually."
    exit 1
  }
}

$downloadUrl = "https://github.com/$repo/releases/download/$Version/gitwhisper-windows.tar.gz"
$tmpDir = "$env:TEMP\gitwhisper-install"
$installDir = "$env:ProgramFiles\GitWhisper"

Write-Host "⬇️  Downloading GitWhisper $Version..."

# Create folders
if (Test-Path $tmpDir) { Remove-Item $tmpDir -Recurse -Force }
New-Item -ItemType Directory -Path $tmpDir | Out-Null
New-Item -ItemType Directory -Force -Path $installDir | Out-Null

# Download + extract
Invoke-WebRequest -Uri $downloadUrl -OutFile "$tmpDir\gitwhisper.tar.gz"
tar -xzf "$tmpDir\gitwhisper.tar.gz" -C $tmpDir

# Move binary
Move-Item "$tmpDir\gitwhisper.exe" "$installDir\gitwhisper.exe" -Force
Copy-Item "$installDir\gitwhisper.exe" "$installDir\gw.exe" -Force

# Add to PATH if needed
$envPath = [Environment]::GetEnvironmentVariable("Path", [EnvironmentVariableTarget]::Machine)
if ($envPath -notlike "*$installDir*") {
  [Environment]::SetEnvironmentVariable("Path", "$envPath;$installDir", [EnvironmentVariableTarget]::Machine)
  Write-Host "🔧 Added $installDir to system PATH."
}

Write-Host "✅ Installed gitwhisper and gw to $installDir"
& "$installDir\gitwhisper.exe" --version
