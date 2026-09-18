Option Explicit

Dim shell, userProfile, installRoot, dataRoot, executable, command, exitCode
Set shell = CreateObject("WScript.Shell")

userProfile = shell.ExpandEnvironmentStrings("%USERPROFILE%")
installRoot = userProfile & "\Applications\AIUsageMonitor"
dataRoot = installRoot & "\Data"
executable = installRoot & "\AIUsageMonitor.exe"

' Keep monitor settings outside Codex Desktop's virtualized AppData tree.
shell.Environment("Process")("AI_USAGE_MONITOR_DATA_DIR") = dataRoot

command = Chr(34) & executable & Chr(34)
exitCode = shell.Run(command, 1, True)
WScript.Quit exitCode
