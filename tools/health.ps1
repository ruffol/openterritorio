param(
  [int]$Port = 3000,
  [switch]$Public
)

$ErrorActionPreference = 'Stop'
if (-not ((& adb devices) | Select-String 'device$')) { throw 'No hay dispositivo ADB conectado.' }

$ipLine = (& adb shell "ip -4 addr show wlan0 2>/dev/null | grep 'inet '") -join ' '
$ip = if ($ipLine -match 'inet\s+([0-9.]+)/') { $matches[1] } else { 'desconocida' }

Write-Host "=== Dispositivo ==="
& adb shell "getprop ro.product.model; getprop ro.build.version.release; getprop ro.build.version.sdk; getprop ro.product.cpu.abilist"
Write-Host "Wi-Fi: $ip"
& adb shell "dumpsys battery | grep -E 'level|temperature|status'"
& adb shell "df -h /data | tail -n1"

$urls = @("http://$ip`:$Port/healthz")
if ($Public) { $urls += 'https://tienda.tlalchichi.xyz/healthz' }
foreach ($url in $urls) {
  try {
    $response = Invoke-WebRequest -Uri $url -TimeoutSec 8 -UseBasicParsing
    Write-Host "OK  $url -> $($response.Content)"
  } catch {
    Write-Host "ERR $url -> $($_.Exception.Message)"
  }
}
