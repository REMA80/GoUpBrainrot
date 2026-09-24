@echo off
cd /d "%~dp0"
echo Installiere Pakete...
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
if not exist .env copy .env.example .env >nul
echo.
echo Fertig. Jetzt die Datei .env mit Notepad oeffnen und die Keys eintragen.
pause
