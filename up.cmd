@echo off
rem Start the PhoneKit service and keep this window open (minimize it).
rem While it runs, every "phone.cmd ..." call is fast (~1s). Close it to stop.
cd /d "%~dp0"
set "PATH=%~dp0bin;%PATH%"
echo ================================================================
echo  PhoneKit service — DO NOT CLOSE THIS WINDOW while driving iPhone
echo  Control API: http://127.0.0.1:8899/health
echo ================================================================
if exist ".venv\Scripts\python.exe" (
  ".venv\Scripts\python.exe" service.py
) else (
  python service.py
)
pause
