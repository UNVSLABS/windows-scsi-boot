# A client's disk and target on the storage server, removed, for clients/remove-client.sh (docs/clients.md). Refuses
# while the target has a session, which is a client that's running. Run as admin. Safe to re-run.
param([Parameter(Mandatory)][string]$Name)
#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. "$PSScriptRoot\..\..\servers\common.ps1"

$path = "$($s.SanDataDrive):\iSCSI\clients\$Name.vhdx"
$t = Get-IscsiServerTarget -TargetName $Name -ErrorAction SilentlyContinue
if ($t.Status -eq 'Connected') {
  # A client that's just been switched off keeps its session for a couple of minutes, until the target's idle check
  Start-Sleep 150
  if ((Get-IscsiServerTarget -TargetName $Name).Status -eq 'Connected') { throw "$Name is running: target $Name has a session" }
}
if ($t) { Remove-IscsiServerTarget -TargetName $Name }
if (Get-IscsiVirtualDisk -Path $path -ErrorAction SilentlyContinue) { Remove-IscsiVirtualDisk -Path $path }
Remove-Item $path -Force -ErrorAction SilentlyContinue
"$Name`: no disk or target"
