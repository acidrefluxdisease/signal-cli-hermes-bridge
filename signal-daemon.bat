@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0signal-daemon.ps1" %1
