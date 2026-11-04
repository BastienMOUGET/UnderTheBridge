@echo off
rem build.cmd - compile bridge.exe (toolchain de l'installeur Amalgame).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1" %*
pause
