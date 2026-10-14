@echo off
REM Goose Village Laser Studio starten (Windows).
REM Benoetigt Python 3.10 oder neuer (https://www.python.org/downloads/).
chcp 65001 >nul
cd /d "%~dp0"

if exist "run.py" goto python_suchen
echo Die Datei run.py wurde nicht gefunden.
echo start.bat liegt in: "%~dp0"
echo.
echo start.bat funktioniert nur im Ordner "laser-studio" zusammen mit den
echo uebrigen Dateien. Bitte das komplette ZIP von GitHub entpacken und
echo start.bat im Ordner "laser-studio" doppelklicken.
goto ende

:python_suchen

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
