@echo off
rem PhoneKit entry point:  phone.cmd open com.apple.TestFlight
setlocal
set "HERE=%~dp0"
if exist "%HERE%.venv\Scripts\python.exe" (
  "%HERE%.venv\Scripts\python.exe" "%HERE%phone.py" %*
) else (
  python "%HERE%phone.py" %*
)
