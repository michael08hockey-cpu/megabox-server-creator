# Полная автосборка MegaBox.apk без Android Studio:
#  1) Microsoft OpenJDK 17 (portable, в C:\Android\jdk17)
#  2) Android command-line tools + SDK (в C:\Android\sdk)
#  3) flutter create (android), настройка, flutter build apk --release
# Лог: android_build_log.txt в папке проекта. Админ-права не нужны.

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$proj = Split-Path -Parent $PSScriptRoot
$log = Join-Path $proj 'android_build_log.txt'
Start-Transcript -Path $log -Force | Out-Null

function Step($m) { Write-Host ''; Write-Host "=== $m === $(Get-Date -Format HH:mm:ss)" }
function Fail($m) { Write-Host "MBX_BUILD_FAIL: $m"; Stop-Transcript | Out-Null; exit 1 }
function Run($exe, [string[]]$argv) {
    & $exe @argv 2>&1 | ForEach-Object { "$_" } | Out-Host
    if ($LASTEXITCODE -ne 0) { Fail "$exe $($argv -join ' ') -> код $LASTEXITCODE" }
}

$base = 'C:\Android'
$sdk = "$base\sdk"
$jdk = "$base\jdk17"

$free = (Get-PSDrive C).Free / 1GB
Write-Host ("Свободно на C: {0:N1} ГБ" -f $free)
if ($free -lt 6) { Fail 'на диске C: меньше 6 ГБ' }

New-Item -ItemType Directory -Force $base, $sdk | Out-Null

# ---------- JDK 17 ----------
if (-not (Test-Path "$jdk\bin\java.exe")) {
    Step 'Скачиваю JDK 17 (Microsoft OpenJDK)'
    $z = "$base\jdk.zip"
    try { Invoke-WebRequest 'https://aka.ms/download-jdk/microsoft-jdk-17-windows-x64.zip' -OutFile $z -UseBasicParsing }
    catch { Fail "не скачался JDK: $_" }
    $tmp = "$base\jdk_tmp"
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive $z $tmp -Force
    $inner = Get-ChildItem $tmp -Directory | Select-Object -First 1
    Move-Item $inner.FullName $jdk
    Remove-Item $tmp, $z -Recurse -Force -ErrorAction SilentlyContinue
}
$env:JAVA_HOME = $jdk
$env:Path = "$jdk\bin;$env:Path"
Run "$jdk\bin\java.exe" @('-version')

# ---------- Android command-line tools ----------
$sm = "$sdk\cmdline-tools\latest\bin\sdkmanager.bat"
if (-not (Test-Path $sm)) {
    Step 'Скачиваю Android command-line tools'
    $z = "$base\clt.zip"
    try { Invoke-WebRequest 'https://dl.google.com/android/repository/commandlinetools-win-11076708_latest.zip' -OutFile $z -UseBasicParsing }
    catch { Fail "не скачались command-line tools: $_" }
    $tmp = "$base\clt_tmp"
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive $z $tmp -Force
    New-Item -ItemType Directory -Force "$sdk\cmdline-tools" | Out-Null
    Move-Item "$tmp\cmdline-tools" "$sdk\cmdline-tools\latest"
    Remove-Item $tmp, $z -Recurse -Force -ErrorAction SilentlyContinue
}
$env:ANDROID_HOME = $sdk
$env:ANDROID_SDK_ROOT = $sdk

# В имени пользователя Windows кириллица: нативная сборка (CMake/ninja)
# падает на путях вида C:\Users\<имя>\... Держим кэш пакетов и временные
# файлы в C:\Android, где путь только латиницей.
$env:PUB_CACHE = "$base\pub-cache"
$env:TEMP = "$base\tmp"
$env:TMP = "$base\tmp"
New-Item -ItemType Directory -Force $env:PUB_CACHE, $env:TEMP | Out-Null

Step 'Принимаю лицензии Android SDK'
(1..40 | ForEach-Object { 'y' }) | & $sm "--sdk_root=$sdk" --licenses 2>&1 | Select-Object -Last 5 | ForEach-Object { "$_" } | Out-Host

Step 'Ставлю platform-tools, platform и build-tools'
Run $sm @("--sdk_root=$sdk", 'platform-tools', 'platforms;android-36', 'build-tools;36.0.0')

# NDK (~1 ГБ). С серверов Google из РФ качается медленно и обрывается,
# поэтому, если запущен v2rayN, качаем через его локальный прокси.
$ndkVer = '28.2.13676358'
if (-not (Test-Path "$sdk\ndk\$ndkVer\source.properties")) {
    $proxyArgs = @()
    try {
        $tcp = New-Object Net.Sockets.TcpClient
        if ($tcp.ConnectAsync('127.0.0.1', 10808).Wait(1500) -and $tcp.Connected) {
            $proxyArgs = @('--proxy=http', '--proxy_host=127.0.0.1', '--proxy_port=10808')
            Write-Host 'NDK качаю через прокси v2rayN (127.0.0.1:10808)'
        }
        $tcp.Close()
    } catch {}
    $ok = $false
    for ($i = 1; $i -le 4 -and -not $ok; $i++) {
        Step "Скачиваю NDK $ndkVer, попытка $i"
        & $sm "--sdk_root=$sdk" @proxyArgs "ndk;$ndkVer" 2>&1 | ForEach-Object { "$_" } | Where-Object { $_ -notmatch '^\[' } | Out-Host
        $ok = Test-Path "$sdk\ndk\$ndkVer\source.properties"
    }
    if (-not $ok) { Fail 'NDK так и не скачался' }
}

# ---------- Flutter ----------
$flutter = (Get-Command flutter -ErrorAction SilentlyContinue).Source
if (-not $flutter) { $flutter = 'C:\src\flutter\bin\flutter.bat' }
if (-not (Test-Path $flutter)) { Fail 'не найден flutter' }
Write-Host "flutter: $flutter"

Step 'Настраиваю Flutter на этот SDK и JDK'
Run $flutter @('config', '--android-sdk', $sdk, '--jdk-dir', $jdk)

Set-Location $proj
if (-not (Test-Path 'android\app\src\main\AndroidManifest.xml')) {
    Step 'Создаю Android-часть проекта'
    Run $flutter @('create', '--platforms=android', '--org', 'com.megabox', '--project-name', 'megabox_server_creator', '.')
}

Step 'Разрешения, название, иконка'
& (Join-Path $PSScriptRoot 'android_setup.ps1')
if ($LASTEXITCODE -ne 0) { Fail 'android_setup.ps1' }

Step 'Очистка старой сборки (пути с кириллицей)'
if (Test-Path 'android\gradlew.bat') {
    Push-Location android
    & .\gradlew.bat --stop 2>&1 | ForEach-Object { "$_" } | Out-Host
    Pop-Location
}
Run $flutter @('clean')
Remove-Item 'build' -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item 'android\.gradle', 'android\app\.cxx' -Recurse -Force -ErrorAction SilentlyContinue

Step 'flutter pub get'
Run $flutter @('pub', 'get')

Step 'Сборка APK (долго в первый раз)'
Run $flutter @('build', 'apk', '--release', '--split-per-abi', '--target-platform', 'android-arm64')

$apk = Join-Path $proj 'build\app\outputs\flutter-apk\app-arm64-v8a-release.apk'
if (-not (Test-Path $apk)) { Fail 'APK не найден после сборки' }
Copy-Item $apk (Join-Path $proj 'MegaBox.apk') -Force
Copy-Item $apk (Join-Path ([Environment]::GetFolderPath('Desktop')) 'MegaBox.apk') -Force
Write-Host ("APK: {0:N1} МБ" -f ((Get-Item $apk).Length / 1MB))
Write-Host 'MBX_BUILD_OK'
Stop-Transcript | Out-Null
