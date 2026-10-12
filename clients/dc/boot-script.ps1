# A client's own iPXE script, clients/<mac>.ipxe on the domain controller, for clients/new-client.sh (docs/clients.md):
# its name, initiator and disk, then the clients' menu (boot/client.ipxe), which boots Windows from the disk. Run as
# admin. clients/dc/remove-client.ps1 deletes it.
param(
  [Parameter(Mandatory)][string]$Name,
  [Parameter(Mandatory)][string]$Mac,
  [Parameter(Mandatory)][string]$InitiatorIqn,
  [Parameter(Mandatory)][string]$TargetIqn
)
#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. "$PSScriptRoot\..\..\servers\common.ps1"

$id = $Mac.ToLower() -replace ':', '-' # as iPXE's ${net0/mac:hexhyp}
$script = "$($s.BootFiles)\clients\$id.ipxe"
$lines = @(
  '#!ipxe'
  "# $Name, a diskless client (clients/new-client.sh)"
  "set client $Name"
  "set initiator-iqn $InitiatorIqn"
  "set root-path iscsi:$($s.SanAddress)::::$TargetIqn"
  'chain ../client.ipxe'
)
New-Item -ItemType Directory -Force (Split-Path $script) | Out-Null
Copy-Item "$root\boot\*.ipxe" $s.BootFiles -Force
Remove-Item "$($s.BootFiles)\jobs\$id.cmd" -Force -ErrorAction SilentlyContinue # a test's WinPE job (image/nic-test.sh)
[IO.File]::WriteAllText($script, ($lines -join "`n") + "`n")
icacls $s.BootFiles /reset /t /q | Out-Null # IIS's anonymous user must be able to read every file
$response = Invoke-WebRequest "http://$($s.DcAddress)/boot/clients/$id.ipxe" -UseBasicParsing # as iPXE fetches it
if ($response.Content -notmatch [regex]::Escape($TargetIqn)) { throw "http://.../boot/clients/$id.ipxe isn't the new script" }
"$Name`: boot script clients/$id.ipxe, disk $TargetIqn"
