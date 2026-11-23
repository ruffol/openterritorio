param(
  [Parameter(Mandatory = $true)]
  [string]$Command,
  [string]$HostIp = '192.168.100.3',
  [int]$Port = 8022,
  [string]$User = 'u0_a187'
)

$ErrorActionPreference = 'Stop'
$key = Join-Path (Split-Path -Parent $PSScriptRoot) 'backup\phone_ed25519'
if (-not (Test-Path $key)) { throw "No existe la clave $key" }

& ssh -p $Port -i $key `
  -o StrictHostKeyChecking=no `
  -o UserKnownHostsFile=NUL `
  -o BatchMode=yes `
  "$User@$HostIp" $Command
exit $LASTEXITCODE
