@echo off
rem Lance Chrome a travers amalgame-bridge (profil separe).
rem Usage : chrome-bridge.cmd [url]
rem Ex.   : chrome-bridge.cmd "https://claude.ai/oauth/authorize?..."
setlocal
set "CHROME=%ProgramFiles%\Google\Chrome\Application\chrome.exe"
if not exist "%CHROME%" set "CHROME=%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe"
if not exist "%CHROME%" set "CHROME=%LOCALAPPDATA%\Google\Chrome\Application\chrome.exe"
if not exist "%CHROME%" (
    echo Chrome introuvable.
    exit /b 1
)
start "" "%CHROME%" ^
  --proxy-server="socks5://127.0.0.1:1080" ^
  --host-resolver-rules="MAP * ~NOTFOUND , EXCLUDE 127.0.0.1 , EXCLUDE localhost , EXCLUDE [::1]" ^
  --user-data-dir="%LOCALAPPDATA%\ChromeBridge" ^
  %*
