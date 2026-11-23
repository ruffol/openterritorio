param(
  [switch]$SkipTests,
  [int]$Port = 3000,
  [switch]$NoPush
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$server = Join-Path $root 'server'
$dist = Join-Path $root 'dist'
$stage = Join-Path $dist 'stage'
$npm = 'C:\Program Files\nodejs\npm.cmd'

$deviceLine = (& adb devices) | Select-String 'device$'
if (-not $deviceLine) { throw 'No hay dispositivo ADB conectado.' }

if (-not $SkipTests) {
  Push-Location $server
  try {
    & $npm test
    if ($LASTEXITCODE -ne 0) { throw 'las pruebas fallaron; no se despliega' }
  } finally {
    Pop-Location
  }
}

Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path (Join-Path $stage 'app') | Out-Null
Copy-Item -Recurse (Join-Path $server 'src') (Join-Path $stage 'app\src')
Copy-Item -Recurse (Join-Path $server 'public') (Join-Path $stage 'app\public')
Copy-Item (Join-Path $server 'package.json') (Join-Path $stage 'app\package.json')
Copy-Item -Recurse (Join-Path $server 'node_modules') (Join-Path $stage 'app\node_modules')
Copy-Item -Recurse (Join-Path $root 'proto') (Join-Path $stage 'proto')
Copy-Item -Recurse (Join-Path $root 'termux') (Join-Path $stage 'termux')

$tarPath = Join-Path $dist 'openterritorio.tar.gz'
Remove-Item $tarPath -Force -ErrorAction SilentlyContinue
& tar -czf $tarPath -C $stage .
if ($LASTEXITCODE -ne 0) { throw 'tar falló' }
$tarSize = [math]::Round((Get-Item $tarPath).Length / 1MB, 1)

$gitHash = 'nogit'
try { $gitHash = (& git -C $root rev-parse --short HEAD 2>$null) } catch {}
$stamp = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + $gitHash
$stampFile = Join-Path $dist 'stamp.txt'
Set-Content -Path $stampFile -Value $stamp -NoNewline

if (-not $NoPush) {
  & adb push $tarPath /sdcard/Download/openterritorio.tar.gz | Out-Host
  & adb push $stampFile /sdcard/Download/openterritorio.stamp | Out-Host
}

$ipLine = (& adb shell "ip -4 addr show wlan0 2>/dev/null | grep 'inet '") -join ' '
$ip = if ($ipLine -match 'inet\s+([0-9.]+)/') { $matches[1] } else { '192.168.100.3' }

Write-Host ''
Write-Host "Artefacto: $tarPath ($tarSize MB)  stamp=$stamp"
Write-Host "Telefono:  $ip  puerto $Port"

$uri = "http://$ip`:$Port/healthz"
$healthy = $false
for ($i = 0; $i -lt 20; $i++) {
  try {
    $response = Invoke-WebRequest -Uri $uri -TimeoutSec 3 -UseBasicParsing
    if ($response.StatusCode -eq 200) { $healthy = $true; break }
  } catch {}
  Start-Sleep -Seconds 1
}
if ($healthy) {
  Write-Host "OK $uri"
} else {
  Write-Host "Sin respuesta en $uri (si es la primera vez, ejecuta el bootstrap en Termux)."
}
