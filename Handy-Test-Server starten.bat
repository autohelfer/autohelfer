@echo off
cd /d "%~dp0"
echo.
echo  autohelfer.ch - Test-Server fuer iPhone/iPad
echo  =============================================
echo  1. iPhone ins GLEICHE WLAN wie dieser PC
echo  2. In Safari diese Adresse oeffnen (aktuelle IPv4 unten):
echo.
for /f "tokens=2 delims=:" %%a in ('ipconfig ^| findstr /c:"IPv4"') do echo     http://%%a:8127   (Leerzeichen vor der Zahl weglassen)
echo.
echo  Beenden: dieses Fenster schliessen oder Ctrl+C
echo  =============================================
echo.
npx -y http-server -p 8127 -a 0.0.0.0 -c-1
pause
