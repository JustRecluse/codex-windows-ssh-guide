$ErrorActionPreference = 'SilentlyContinue'
$procs = Get-CimInstance Win32_Process -Filter "Name='codex.exe'" |
  Where-Object { $_.CommandLine -like '*app-server*--listen*' }
foreach ($p in $procs) { Stop-Process -Id $p.ProcessId -Force }
if (@($procs).Count -gt 0) { exit 0 } else { exit 1 }