# A client's disk on the storage server (docs/clients.md), for clients/san/new-client.ps1 and update-clients.ps1, which
# dot-source this after servers/common.ps1:
# - a differencing disk <data drive>:\iSCSI\clients\<name>.vhdx on a sealed golden image;
# - the client's identity in the answer file that sysprep left in it (Windows\Panther\unattend.xml): its computer name,
#   and its offline domain join;
# - SetupComplete.cmd, which deletes that answer file once Windows setup is done, as it holds the join's password.
# The client's first boot does the rest, with no prompts: WinPE from the image makes its NIC a boot NIC
# (image/winpe/firstboot.ps1) and restarts; then Windows finishes setup and joins the domain.

$images = "$($s.SanDataDrive):\iSCSI\images"
function Get-ClientDiskPath($Name) { "$($s.SanDataDrive):\iSCSI\clients\$Name.vhdx" }

# The client's new disk on golden-v<version>, with its identity, on no target. Deleted again if that fails.
function New-ClientDisk($Name, [int]$Version, $AccountData) {
  $path = Get-ClientDiskPath $Name
  Step "$Name`: a new disk on golden-v$Version"
  New-IscsiVirtualDisk -Path $path -ParentPath "$images\golden-v$Version.vhdx" | Out-Null
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
      $provisioning.AppendChild($xml.CreateElement('AccountData', $ns)).InnerText = $AccountData
      $xml.Save($file)

      # Windows runs it as SYSTEM once setup is done, before anyone can log on
      New-Item -ItemType Directory -Force "$volume\Windows\Setup\Scripts" | Out-Null
      [IO.File]::WriteAllText("$volume\Windows\Setup\Scripts\SetupComplete.cmd", @(
          '@echo off'
          'rem Written by windows-scsi-boot clients/san/disk.ps1: the answer file holds the domain join''s password'
          'del /f /q %WINDIR%\Panther\unattend.xml'
        ) -join "`r`n")
    }
  } catch {
    if (Get-IscsiVirtualDisk -Path $path -ErrorAction SilentlyContinue) { Remove-IscsiVirtualDisk -Path $path }
    Remove-Item $path -Force -ErrorAction SilentlyContinue
    throw
  }
}
