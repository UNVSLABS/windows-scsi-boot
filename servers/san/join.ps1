# Join the storage server to the domain (PLAN.md, phase 1). Takes the password of the domain account <NetbiosName>\admin
# from servers\secret.txt. Run as admin, from a copy of the repo's servers/ (setup.sh makes it, and runs this again after
# the restart). Done once it prints "already in".
#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. "$PSScriptRoot\..\common.ps1"
$password = Read-Secret # first, so that it's deleted whatever happens next

$nic =@(Get-NetAdapter -Physical | Where-Object Status -eq 'Up')[0]
Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses $s.DcAddress # to find the domain

$cs = Get-CimInstance Win32_ComputerSystem
if ($cs.PartOfDomain -and $cs.Domain -eq $s.DomainName) { "already in $($s.DomainName)"; return }

if (-not $password) { throw "need the password of $($s.NetbiosName)\admin in secret.txt" }
$credential = [pscredential]::new("$($s.NetbiosName)\admin", (ConvertTo-SecureString $password -AsPlainText -Force))
Add-Computer -DomainName $s.DomainName -Credential $credential -Force -WarningAction SilentlyContinue
Restart-ForRerun "joined $($s.DomainName)"
