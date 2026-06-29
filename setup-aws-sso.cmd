@echo off
setlocal

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup-aws-sso.ps1" %*
exit /b %ERRORLEVEL%
