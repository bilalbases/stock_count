@echo off
REM Stock Count local server - installer. Right-click > Run as administrator.
REM Starts the server now and automatically every time Windows starts (no login needed).
setlocal
net session >nul 2>&1
if errorlevel 1 (
  echo Please right-click Install.cmd and choose "Run as administrator".
  pause
  exit /b 1
)
set "DIR=%~dp0"
set "DIR=%DIR:~0,-1%"

if not exist "%DIR%\key.txt" (
  echo.
  echo Enter the upload password. It must be the same password the app uses
  echo ^(the SHEET_KEY secret in GitHub^).
  set /p KEY=Password: 
  call :writekey
)

echo.
echo Opening port 8080 in the Windows firewall...
netsh advfirewall firewall delete rule name="Stock Count server" >nul 2>&1
netsh advfirewall firewall add rule name="Stock Count server" dir=in action=allow protocol=TCP localport=8080 >nul

echo Registering the server to start with Windows...
schtasks /end /tn "StockCountServer" >nul 2>&1
schtasks /create /f /tn "StockCountServer" /sc onstart /ru SYSTEM /rl highest ^
  /tr "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"%DIR%\StockCountServer.ps1\"" >nul
schtasks /run /tn "StockCountServer" >nul

timeout /t 5 >nul
echo.
echo Done. Open http://localhost:8080 in a browser on this PC to check it is running.
echo From other PCs: http://%COMPUTERNAME%:8080  (or http://192.168.11.162:8080)
echo Excel files are saved in: %DIR%\Output
start "" http://localhost:8080
pause
exit /b 0

:writekey
setlocal EnableDelayedExpansion
> "%DIR%\key.txt" echo(!KEY!
endlocal
exit /b 0
