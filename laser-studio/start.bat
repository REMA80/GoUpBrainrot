@echo off
REM Goose Village Laser Studio starten (Windows).
REM Benoetigt Python 3.10 oder neuer (https://www.python.org/downloads/).
chcp 65001 >nul
cd /d "%~dp0"

where py >nul 2>nul
if %errorlevel%==0 (
    py -3 run.py %*
    goto ende
)
where python >nul 2>nul
if %errorlevel%==0 (
    python run.py %*
    goto ende
)
echo Python wurde nicht gefunden.
echo Bitte Python 3.10 oder neuer von https://www.python.org/downloads/ installieren
echo und bei der Installation "Add python.exe to PATH" anhaken.

:ende
pause
