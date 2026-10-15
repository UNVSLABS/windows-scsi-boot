# Remove a build's files from the domain controller when image/build.sh ends, however it ends (docs/golden-image.md):
# the answer files on the install share, and the build VM's WinPE job and iPXE script over HTTP, which hold passwords;
# and the share's account, disabled with a new password. Run as admin. Safe to re-run.
param([Parameter(Mandatory)][string]$Mac) # the build VM's
#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. "$PSScriptRoot\..\..\servers\common.ps1"

$id = $Mac.ToLower() -replace ':', '-' # as iPXE's ${net0/mac:hexhyp}, and the DHCP server's client ID
Remove-Item "$($s.InstallShare)\build" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$($s.BootFiles)\jobs\$id.cmd", "$($s.BootFiles)\clients\$id.ipxe" -Force -ErrorAction SilentlyContinue
Import-Module ActiveDirectory
if (Get-ADUser -Filter "SamAccountName -eq '$($s.ShareAccount)'") {
  Disable-ADAccount $s.ShareAccount
  $bytes = [byte[]]::new(32)
  [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
  Set-ADAccountPassword $s.ShareAccount -Reset -NewPassword (ConvertTo-SecureString ('Aa1' + [Convert]::ToBase64String($bytes)) -AsPlainText -Force)
}
Get-SmbSession | Where-Object ClientUserName -eq "$($s.NetbiosName)\$($s.ShareAccount)" | Close-SmbSession -Force
"removed the build's files; $($s.NetbiosName)\$($s.ShareAccount) is disabled"
