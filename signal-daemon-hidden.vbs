' Signal-cli Hermes Daemon - hidden (windowless) launcher
' Starts run-daemon.bat with window style 0 (invisible) so no
' cmd window pops up on the desktop. Run via: wscript.exe //B //Nologo <this file>
Option Explicit
Dim sh, scriptDir, bat
Set sh = CreateObject("WScript.Shell")
scriptDir = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
bat = scriptDir & "\run-daemon.bat"
' 0 = SW_HIDE, False = do not wait for process to exit
sh.Run "cmd /c """ & bat & """", 0, False