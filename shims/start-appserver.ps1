$ErrorActionPreference = 'SilentlyContinue'
$ctrl = Join-Path $env:USERPROFILE '.codex\app-server-control'
New-Item -ItemType Directory -Force -Path $ctrl | Out-Null
$log = Join-Path $ctrl 'boot-server.log'

# Create via WMI so the process is parented by WmiPrvSE and survives the ssh session.
# stdin must be redirected from nul, otherwise codex exits immediately.
$inner = 'codex -c features.code_mode_host=true app-server --listen unix:// < nul > "' + $log + '" 2>&1'
$r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = ('cmd.exe /c "' + $inner + '"') }
Write-Output ('WMI ReturnValue=' + $r.ReturnValue + ' PID=' + $r.ProcessId)