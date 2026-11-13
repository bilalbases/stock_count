@echo off
REM Stops the Stock Count server and removes the auto-start. Your data and Excel files stay.
net session >nul 2>&1
if errorlevel 1 (
  echo Please right-click Uninstall.cmd and choose "Run as administrator".
  pause
  exit /b 1
)
schtasks /end /tn "StockCountServer" >nul 2>&1
schtasks /delete /f /tn "StockCountServer" >nul 2>&1
netsh advfirewall firewall delete rule name="Stock Count server" >nul 2>&1
echo Stock Count server removed. The data and Output folders were kept.
pause
