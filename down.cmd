@echo off
rem Tear the whole link down (tunnel, WDA, port forwards) and stop the service.
cd /d "%~dp0"
set "PATH=%~dp0bin;%PATH%"
if exist ".venv\Scripts\python.exe" (
  ".venv\Scripts\python.exe" phone.py down
) else (
  python phone.py down
)
echo.
echo If the service window is still open, close it too.
pause
