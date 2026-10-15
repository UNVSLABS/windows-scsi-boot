# Promote the domain controller to the first domain controller of a new forest (docs/requirements.md). Takes the
# Directory Services Restore Mode password from servers\secret.txt. Run as admin, from a copy of the repo's servers/ and
# boot/ (setup.sh makes it, and runs this again after each restart). Done once it prints "already a domain controller".
#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. "$PSScriptRoot\..\common.ps1"
$dsrm = Read-Secret # first, so that it's deleted whatever happens next

$cs = Get-CimInstance Win32_ComputerSystem
if ($cs.DomainRole -ge 4) { "already a domain controller of $($cs.Domain)"; return } # 4 and 5: backup and primary DC

if ($dsrm -notmatch '^[A-Za-z0-9]{16,}$') { throw 'need the DSRM password, 16+ letters and digits, in secret.txt' }
Wait-ServicingIdle

Install-Feature AD-Domain-Services, DNS
Import-Module ADDSDeployment
# The local Administrator and admin accounts become domain accounts, with the same passwords. A DNS delegation from
# the parent zone can't be made here, as that zone isn't on a Windows DNS server: the clients ask this server directly.
$result = Install-ADDSForest -DomainName $s.DomainName -DomainNetbiosName $s.NetbiosName `
  -ForestMode Win2025 -DomainMode Win2025 -InstallDns `
  -SafeModeAdministratorPassword (ConvertTo-SecureString $dsrm -AsPlainText -Force) `
  -NoRebootOnCompletion -Force -WarningAction SilentlyContinue
if ($result.Status -ne 'Success') { throw "promotion: $($result.Status): $($result.Message)" }
Restart-ForRerun "new domain controller of $($s.DomainName)"
