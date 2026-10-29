' No-console launcher for the quota widget.
' Started by WMI, then launches the widget script with a hidden console (window style 0).
' Avoids the brief command-prompt flash that a directly spawned powershell.exe causes.
Option Explicit

Dim sh, fso, baseDir, psExe, psScript, cmd, f, folder

Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

baseDir = fso.GetParentFolderName(WScript.ScriptFullName)
Set folder = fso.GetFolder(baseDir)

psScript = ""
For Each f In folder.Files
  If LCase(fso.GetExtensionName(f.Name)) = "ps1" And LCase(f.Name) <> "widget-core.ps1" Then
    psScript = f.Path
    Exit For
  End If
Next

If psScript = "" Then
  WScript.Quit 1
End If

psExe = sh.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
cmd = """" & psExe & """ -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & psScript & """"

sh.Run cmd, 0, False
