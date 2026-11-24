param(
  [string]$Version,
  [int]$BuildNumber = 0,
  [string]$Notes = '',
  [string]$Apk,
  [string]$Flutter = 'flutter',
  [switch]$SkipBuild,
  [switch]$NoPush,
  # Publicación remota por HTTPS (no necesita cable ni adb).
  [switch]$Remote,
  [string]$RemoteUrl = 'https://tienda.tlalchichi.xyz',
  [string]$Token = $env:OPENTERITORIO_TOKEN
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$app = Join-Path $root 'app'
$dist = Join-Path $root 'dist\app'

if (-not $Version) {
  $pubspec = Get-Content (Join-Path $app 'pubspec.yaml') -Raw
  if ($pubspec -match '(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)') {
    $Version = $matches[1]
    if ($BuildNumber -le 0) { $BuildNumber = [int]$matches[2] }
  } else {
    throw 'No pude leer version: X.Y.Z+N de pubspec.yaml; pasa -Version y -BuildNumber.'
  }
}
if ($BuildNumber -le 0) { throw 'Indica -BuildNumber (versionCode) mayor que el instalado.' }

if (-not $SkipBuild) {
  Push-Location $app
  try {
    & $Flutter build apk --release `
      --build-name $Version --build-number $BuildNumber
    if ($LASTEXITCODE -ne 0) { throw 'flutter build falló' }
  } finally {
    Pop-Location
  }
}

$apkPath = if ($Apk) { $Apk } else { Join-Path $app 'build\app\outputs\flutter-apk\app-release.apk' }
if (-not (Test-Path $apkPath)) { throw "No existe el APK: $apkPath" }

New-Item -ItemType Directory -Force $dist | Out-Null
$targetApk = Join-Path $dist 'openterritorio.apk'
Copy-Item $apkPath $targetApk -Force

$size = (Get-Item $targetApk).Length
$sha = (Get-FileHash $targetApk -Algorithm SHA256).Hash.ToLower()
$manifest = [ordered]@{
  version      = $Version
  version_code = $BuildNumber
  apk          = 'openterritorio.apk'
  size_bytes   = $size
  sha256       = $sha
  notes        = $Notes
  published_at = (Get-Date).ToUniversalTime().ToString('o')
}
$manifestPath = Join-Path $dist 'latest.json'
$json = $manifest | ConvertTo-Json
# Sin BOM: JSON.parse del backend fallaría con el BOM que añade PowerShell 5.1.
[System.IO.File]::WriteAllText($manifestPath, $json, (New-Object System.Text.UTF8Encoding($false)))

if ($Remote) {
  if (-not $Token) { throw 'Indica -Token o define la variable OPENTERITORIO_TOKEN.' }
  $base = $RemoteUrl.TrimEnd('/')
  $query = 'version={0}&version_code={1}&sha256={2}&notes={3}' -f `
    $Version, $BuildNumber, $sha, [uri]::EscapeDataString($Notes)
  Write-Host ("Subiendo {0} MB a {1} ..." -f ([math]::Round($size / 1MB, 1)), $base)
  $response = Invoke-WebRequest -Uri "$base/api/app/upload?$query" `
    -Method Post -InFile $targetApk -ContentType 'application/octet-stream' `
    -Headers @{ Authorization = 'Bearer ' + $Token } -TimeoutSec 1800 -UseBasicParsing
  $body = $response.Content | ConvertFrom-Json
  if ($response.StatusCode -ne 201) { throw "subida HTTP $($response.StatusCode)" }
  if ($body.sha256 -ne $sha) { throw 'el servidor devolvió un sha256 distinto' }
  # Verificación independiente: lo que sirve /api/app/latest es lo que acaba de subirse.
  $latest = Invoke-RestMethod -Uri "$base/api/app/latest" `
    -Headers @{ Authorization = 'Bearer ' + $Token } -TimeoutSec 120
  if ($latest.version_code -ne $BuildNumber -or $latest.sha256 -ne $sha) {
    throw 'la verificación contra /api/app/latest falló'
  }
  Write-Host ("Publicado por HTTPS: v{0} (code {1}), {2} bytes" -f $latest.version, $latest.version_code, $latest.size_bytes)
} elseif (-not $NoPush) {
  $device = (& adb devices) | Select-String 'device$'
  if (-not $device) { throw 'No hay dispositivo ADB conectado (usa -Remote para publicar por HTTPS).' }
  $remote = '/sdcard/Download/openterritorio-app'
  $stamp = (Get-Date -Format 'yyyyMMdd-HHmmss') + "-v$Version-$BuildNumber"
  $stampFile = Join-Path $dist 'app.stamp'
  Set-Content -Path $stampFile -Value $stamp -NoNewline

  & adb shell "mkdir -p $remote" | Out-Host
  & adb push $targetApk "$remote/openterritorio.apk" | Out-Host
  & adb push $manifestPath "$remote/latest.json" | Out-Host
  & adb push $stampFile "$remote/app.stamp" | Out-Host
}

$sizeMb = [math]::Round($size / 1MB, 1)
Write-Host ''
Write-Host "Publicado v$Version (code $BuildNumber), $sizeMb MB, sha256=$sha"
Write-Host "Manifiesto: $manifestPath"
Write-Host 'OTA: GET /api/app/latest y /api/app/download (Bearer token)'
if (-not $NoPush) {
  Write-Host 'El watcher del teléfono copia el APK a ~/openterritorio/app/ en <= 10 s.'
}
