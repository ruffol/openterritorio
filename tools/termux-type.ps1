param(
  [Parameter(Mandatory = $true)]
  [string]$Command
)

$ErrorActionPreference = 'Stop'
$device = & adb devices | Select-String 'device$'
if (-not $device) { throw 'No hay dispositivo ADB conectado.' }

$focus = (& adb shell "dumpsys window | grep -m1 mCurrentFocus") -join ' '
if ($focus -match 'AtchDlg|PopupWindow|InputMethod') {
  & adb shell input keyevent 4 | Out-Null
  Start-Sleep -Milliseconds 800
}

& adb shell am start -n com.termux/.app.TermuxActivity | Out-Null
Start-Sleep -Seconds 2

$encoded = $Command -replace ' ', '%s'
& adb shell input text $encoded
Start-Sleep -Milliseconds 400
& adb shell input keyevent 66
Write-Host "Enviado a Termux: $Command"
