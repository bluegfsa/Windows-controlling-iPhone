' PhoneKit — optional "no console window" launcher for the service.
' Double-click it. The service runs hidden; close it with Task Manager
' (pythonw.exe) or by running down.cmd first.
'
' up.cmd is the recommended way (you can see the log); this file exists for
' people who do not want a console window sitting in the taskbar.
Dim fso, here, py, svc, sh
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)

If fso.FileExists(here & "\.venv\Scripts\pythonw.exe") Then
  py = here & "\.venv\Scripts\pythonw.exe"
Else
  py = "pythonw.exe"
End If
svc = here & "\service.py"

Set sh = CreateObject("WScript.Shell")
sh.CurrentDirectory = here
sh.Run """" & py & """ """ & svc & """", 0, False
