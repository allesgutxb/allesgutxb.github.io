@echo off
setlocal
cd /d "%~dp0.."
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0publish_schedule_data.ps1" %*
exit /b %ERRORLEVEL%
