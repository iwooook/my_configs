# Kill the running watch.py (pythonw) and the off-screen Edge that Playwright launched for it.
Get-CimInstance Win32_Process -Filter "Name='pythonw.exe' OR Name='python.exe'" |
    Where-Object CommandLine -like '*seatwatch*watch.py*' |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
# Playwright's Edge uses a temp profile 'playwright_chromiumdev_profile-*'; the user's own Edge is untouched.
Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" |
    Where-Object CommandLine -like '*playwright_chromiumdev_profile*' |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Write-Host 'Watcher stopped.'
