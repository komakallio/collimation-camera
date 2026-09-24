@echo off
rem Runs scripts\build-win.ps1 with stdout and stderr merged by cmd, not by
rem PowerShell 5.1, which otherwise wraps every stderr line in an ErrorRecord
rem and reports failure even when the build succeeded.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-win.ps1" %* 2>&1
