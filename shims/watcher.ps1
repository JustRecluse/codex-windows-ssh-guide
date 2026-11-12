$ErrorActionPreference = 'SilentlyContinue'
$ctrl = Join-Path $env:USERPROFILE '.codex\app-server-control'
$req  = Join-Path $ctrl 'start-request'
$log  = Join-Path $ctrl 'boot-server.log'
$wlog = Join-Path $ctrl 'watcher.log'

Add-Content -Path $wlog -Value ((Get-Date -Format s) + ' watcher v2 started')

$lastStart = Get-Date '2000-01-01'
while ($true) {
  Start-Sleep -Milliseconds 700
  if (Test-Path -LiteralPath $req) { Remove-Item -LiteralPath $req -Force -ErrorAction SilentlyContinue }

  $has = @(Get-CimInstance Win32_Process -Filter "Name='codex.exe'" | Where-Object { $_.CommandLine -like '*app-server*--listen*' }).Count
  if ($has -gt 0) { continue }

  # 限流：最多每 5 秒补起一次，避免疯狂重启
  if (((Get-Date) - $lastStart).TotalSeconds -lt 5) { continue }
  $lastStart = Get-Date

  $inner = 'codex -c features.code_mode_host=true app-server --listen unix:// < nul > "' + $log + '" 2>&1'
  $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = ('cmd.exe /c "' + $inner + '"') }
  Add-Content -Path $wlog -Value ((Get-Date -Format s) + ' auto-start rv=' + $r.ReturnValue + ' pid=' + $r.ProcessId)
}