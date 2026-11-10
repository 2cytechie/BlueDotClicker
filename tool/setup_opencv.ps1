param(
    [string]$Version = '4.13.0',
    [string]$Url = ''
)

# Download the official OpenCV Windows prebuilt package and extract it to third_party/opencv/
# Usage:
#   powershell -ExecutionPolicy Bypass -File tool/setup_opencv.ps1
#   powershell -ExecutionPolicy Bypass -File tool/setup_opencv.ps1 -Url <mirror-url>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repoRoot = Split-Path -Parent $PSScriptRoot
$destRoot = Join-Path $repoRoot 'third_party\opencv'
$configPath = Join-Path $destRoot 'opencv\build\OpenCVConfig.cmake'

if (Test-Path $configPath) {
    Write-Host "OpenCV already installed: $configPath"
    Write-Host "OpenCV_DIR=$(Join-Path $destRoot 'opencv\build')"
    exit 0
}

if (-not $Url) {
    $Url = "https://github.com/opencv/opencv/releases/download/$Version/opencv-$Version-windows.exe"
}

$installer = Join-Path $env:TEMP "opencv-$Version-windows.exe"
Write-Host "Downloading OpenCV $Version ..."
Write-Host "  URL: $Url"
Invoke-WebRequest -Uri $Url -OutFile $installer -UseBasicParsing -TimeoutSec 1800

New-Item -ItemType Directory -Force -Path $destRoot | Out-Null
Write-Host "Extracting to $destRoot ..."
Start-Process -FilePath $installer -ArgumentList "-o`"$destRoot`"", '-y' -Wait

if (-not (Test-Path $configPath)) {
    throw "OpenCVConfig.cmake not found after extraction ($configPath). Please verify the archive, or install OpenCV manually and set OpenCV_DIR."
}

Write-Host "OpenCV installed."
Write-Host "OpenCV_DIR=$(Join-Path $destRoot 'opencv\build')"
