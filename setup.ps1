# setup.ps1 — одноразовая настройка ai-syslog на Windows.
# Идемпотентно создаёт правило брандмауэра для входящего syslog (UDP 514),
# если его ещё нет. Требует прав администратора (само повышает привилегии).
#
#   Запуск:  powershell -ExecutionPolicy Bypass -File setup.ps1
#   Опции:   -Port 514  -RemoteAddress LocalSubnet   (или конкретный IP роутера)

param(
    [string]$RuleName = "ai-syslog UDP 514",
    [int]$Port = 514,
    [string]$RemoteAddress = "LocalSubnet"  # сузить до IP роутера, напр. 192.168.6.1
)

# Самоповышение прав, если не админ
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Нужны права администратора — перезапускаю с повышением..." -ForegroundColor Yellow
    $args = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" " +
            "-RuleName `"$RuleName`" -Port $Port -RemoteAddress $RemoteAddress"
    Start-Process powershell.exe $args -Verb RunAs
    exit
}

$existing = Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "OK: правило '$RuleName' уже есть (Enabled=$($existing.Enabled))." -ForegroundColor Green
} else {
    New-NetFirewallRule -DisplayName $RuleName -Direction Inbound -Protocol UDP `
        -LocalPort $Port -RemoteAddress $RemoteAddress -Action Allow -Profile Any | Out-Null
    Write-Host "OK: создано правило '$RuleName' (входящий UDP $Port от $RemoteAddress)." -ForegroundColor Green
}

Write-Host "`nГотово. Теперь запускайте коллектор:  .\.venv\Scripts\python.exe main.py" -ForegroundColor Cyan
