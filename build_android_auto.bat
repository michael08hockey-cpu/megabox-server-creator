@echo off
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "tool\setup_and_build_android.ps1"
echo.
echo Done. See android_build_log.txt
pause
