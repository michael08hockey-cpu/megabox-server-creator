# Готовит Android-часть проекта после `flutter create --platforms=android .`
# - разрешение INTERNET (без него в release-сборке не работает SSH и пинг);
# - название приложения «MegaBox»;
# - иконка (щит с молнией).
# Запускается из build_android.bat, повторный запуск ничего не ломает.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$utf8 = New-Object System.Text.UTF8Encoding $false

$manifest = Join-Path $root 'android\app\src\main\AndroidManifest.xml'
if (-not (Test-Path $manifest)) {
    Write-Host 'AndroidManifest.xml not found - run flutter create first' -ForegroundColor Red
    exit 1
}

$xml = [IO.File]::ReadAllText($manifest)

if ($xml -notmatch 'android\.permission\.INTERNET') {
    $xml = $xml -replace '(<application)', "<uses-permission android:name=`"android.permission.INTERNET`" />`r`n    `$1"
    Write-Host '+ INTERNET permission'
}

$xml = $xml -replace 'android:label="[^"]*"', 'android:label="MegaBox"'

[IO.File]::WriteAllText($manifest, $xml, $utf8)

$icons = Join-Path $PSScriptRoot 'android_icons'
$res = Join-Path $root 'android\app\src\main\res'
Get-ChildItem $icons -Directory | ForEach-Object {
    $dst = Join-Path $res $_.Name
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    Copy-Item (Join-Path $_.FullName 'ic_launcher.png') (Join-Path $dst 'ic_launcher.png') -Force
}
Write-Host '+ icon and label MegaBox'
