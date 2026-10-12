# A new client's disk on the storage server, for clients/new-client.sh (PLAN.md, Client lifecycle; docs/clients.md):
# - a differencing disk <data drive>:\iSCSI\clients\<name>.vhdx on a golden image, the newest sealed one unless given;
# - the client's identity in the answer file that sysprep left in it (Windows\Panther\unattend.xml): its computer name,
#   and its offline domain join, from servers\secret.txt;
# - SetupComplete.cmd, which deletes that answer file once Windows setup is done, as it holds the join's password;
# - target <name>, which accepts only the client's initiator.
# Prints the target's IQN. The client's first boot does the rest, with no prompts: WinPE from the image makes its NIC a
# boot NIC (image/winpe/firstboot.ps1) and restarts; then Windows finishes setup and joins the domain. Run as admin.
# Refuses a client that has a disk already: clients/remove-client.sh removes it.
param(
  [Parameter(Mandatory)][string]$Name,
  [Parameter(Mandatory)][string]$InitiatorIqn,
  [int]$Version # golden-v<version>
)
#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. "$PSScriptRoot\..\..\servers\common.ps1"
$accountData = Read-Secret # first, so that it's deleted whatever happens next
if (-not $accountData) { throw 'need the offline domain join data in secret.txt' }

$images = "$($s.SanDataDrive):\iSCSI\images"
if (-not $Version) {
  $Version = Get-ChildItem $images -Filter 'golden-v*.vhdx' | Where-Object IsReadOnly |
    ForEach-Object { [int]($_.BaseName -replace '^golden-v') } | Sort-Object | Select-Object -Last 1
  if (-not $Version) { throw "no sealed golden image in $images" }
}
$parent = "$images\golden-v$Version.vhdx"
if (-not (Test-Path $parent) -or -not (Get-Item $parent).IsReadOnly) { throw "golden-v$Version isn't built and sealed" }
$path = "$($s.SanDataDrive):\iSCSI\clients\$Name.vhdx"
if ((Test-Path $path) -or (Get-IscsiServerTarget -TargetName $Name -ErrorAction SilentlyContinue)) {
  throw "$Name has a disk or target already: clients/remove-client.sh removes them"
}

Step "$Name`: a new disk on golden-v$Version"
New-IscsiVirtualDisk -Path $path -ParentPath $parent | Out-Null
try {
  Use-WindowsVolume $path {
    param($volume)
    if (-not (Test-Path "$volume\Windows\Setup\Diskless\firstboot.ps1")) {
      throw "golden-v$Version has no first boot step for the client's NIC: it was sealed before clients/ (image/san/seal.ps1)"
    }
    $file = "$volume\Windows\Panther\unattend.xml"
    if (-not (Test-Path $file)) { throw "golden-v$Version has no answer file from sysprep, $file" }

    Step "$Name`: its computer name and domain join, in the answer file"
    $xml = [xml][IO.File]::ReadAllText($file)
    $ns = 'urn:schemas-microsoft-com:unattend'
    $nsm = [Xml.XmlNamespaceManager]::new($xml.NameTable)
    $nsm.AddNamespace('u', $ns)
    $specialize = $xml.SelectSingleNode("/u:unattend/u:settings[@pass='specialize']", $nsm)
    $specialize.SelectSingleNode("u:component[@name='Microsoft-Windows-Shell-Setup']/u:ComputerName", $nsm).InnerText = $Name
    $join = $specialize.AppendChild($xml.CreateElement('component', $ns))
    foreach ($a in ([ordered]@{ name = 'Microsoft-Windows-UnattendedJoin'; processorArchitecture = 'amd64'
        publicKeyToken = '31bf3856ad364e35'; language = 'neutral'; versionScope = 'nonSxS' }).GetEnumerator()) {
      $join.SetAttribute($a.Key, $a.Value)
    }
    $provisioning = $join.AppendChild($xml.CreateElement('Identification', $ns)).AppendChild($xml.CreateElement('Provisioning', $ns))
    $provisioning.AppendChild($xml.CreateElement('AccountData', $ns)).InnerText = $accountData
    $xml.Save($file)

    # Windows runs it as SYSTEM once setup is done, before anyone can log on
    New-Item -ItemType Directory -Force "$volume\Windows\Setup\Scripts" | Out-Null
    [IO.File]::WriteAllText("$volume\Windows\Setup\Scripts\SetupComplete.cmd", @(
        '@echo off'
        'rem Written by windows-scsi-boot clients/san/new-client.ps1: the answer file holds the domain join''s password'
        'del /f /q %WINDIR%\Panther\unattend.xml'
      ) -join "`r`n")
  }
} catch {
  if (Get-IscsiVirtualDisk -Path $path -ErrorAction SilentlyContinue) { Remove-IscsiVirtualDisk -Path $path }
  Remove-Item $path -Force -ErrorAction SilentlyContinue
  throw
}

Step "$Name`: target $Name, for $InitiatorIqn only"
New-IscsiServerTarget -TargetName $Name -InitiatorIds "IQN:$InitiatorIqn" | Out-Null
Add-IscsiVirtualDiskTargetMapping -TargetName $Name -Path $path
"$Name`: golden-v$Version, disk $([math]::Round((Get-Item $path).Length / 1MB)) MB"
"target-iqn: $((Get-IscsiServerTarget -TargetName $Name).TargetIqn)"
