@echo off
rem WinPE's startup (docs/image.md), put into WinPE by image\dc\prepare.ps1, which fills in @DC@. Once WinPE has started
rem its network, it fetches this machine's job, if it has one, from http://@DC@/boot/jobs/<mac>.cmd, and runs it: the
rem build's on the build VM, a test's on a test client. Without one, WinPE stops at a prompt, for recovery. The network
rem can take a minute to come up.
wpeinit
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "for ($i = 0; $i -lt 24; $i++) {" ^
  "  foreach ($mac in (Get-CimInstance Win32_NetworkAdapter -Filter 'PhysicalAdapter=TRUE').MACAddress) {" ^
  "    $url = 'http://@DC@/boot/jobs/' + $mac.ToLower().Replace(':', '-') + '.cmd';" ^
  "    try { Invoke-WebRequest $url -OutFile X:\job.cmd -UseBasicParsing; 'job: ' + $url; exit 0 }" ^
  "    catch { if ($_.Exception.Response.StatusCode -eq 'NotFound') { 'no job: ' + $url; exit 0 } };" ^
  "  };" ^
  "  Start-Sleep 5;" ^
  "}"
if exist X:\job.cmd call X:\job.cmd
