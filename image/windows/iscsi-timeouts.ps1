# How long the golden image's Windows waits for its iSCSI disk while the storage server is away (docs/operations.md,
# The storage server). Windows' iSCSI initiator holds a disk's requests for 60 seconds by default while it reconnects
# (MaxRequestHoldTime), then fails them, which takes down a client that boots from the disk. At 10 minutes, clients
# pause while the storage server restarts, and carry on. (The disk's own timeout, TimeOutValue, didn't need changing:
# clients at 60 waited out 3.4 minutes.) Run in the image: by firstlogon.ps1 in a build, or as admin in a change
# (image/change.sh). Takes effect from the next boot.
$ErrorActionPreference = 'Stop'
$seconds = 600

# The initiator's settings are in its device's key in the SCSI adapter class. The class's Properties key is readable by
# SYSTEM only, and is skipped.
$class = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4D36E97B-E325-11CE-BFC1-08002BE10318}'
$initiator = Get-ChildItem $class -ErrorAction SilentlyContinue | Where-Object {
  (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).DriverDesc -eq 'Microsoft iSCSI Initiator'
}
if (@($initiator).Count -ne 1) { throw "expected one Microsoft iSCSI Initiator in $class, found $(@($initiator).Count)" }
Set-ItemProperty "$($initiator.PSPath)\Parameters" MaxRequestHoldTime $seconds -Type DWord
"iSCSI initiator ($($initiator.PSChildName)): MaxRequestHoldTime $((Get-ItemProperty "$($initiator.PSPath)\Parameters").MaxRequestHoldTime)"
