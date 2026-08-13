@echo off
setlocal
set SCRIPT_DIR=%~dp0
call "%SCRIPT_DIR%signal-config.local.bat"

if not "%SIGNAL_ACCOUNT_NUMBER%"=="" goto :haveaccount
echo FEHLER: signal-config.local.bat fehlt oder SIGNAL_ACCOUNT_NUMBER ist leer. Bitte install.ps1 ausfuehren. >> "%SCRIPT_DIR%logs\daemon-err.log"
exit /b 1

:haveaccount
if "%SIGNAL_JAVA_HOME%"=="" goto :skipjava
set "JAVA_HOME=%SIGNAL_JAVA_HOME%"
set "PATH=%SIGNAL_JAVA_HOME%\bin;%PATH%"
:skipjava

if not exist "%SCRIPT_DIR%logs" mkdir "%SCRIPT_DIR%logs"

cd /d "%SCRIPT_DIR%signal-cli\build\install\signal-cli\bin"
signal-cli.bat --account %SIGNAL_ACCOUNT_NUMBER% daemon --http %SIGNAL_HTTP_BIND% --receive-mode on-start >> "%SCRIPT_DIR%logs\daemon-out.log" 2>> "%SCRIPT_DIR%logs\daemon-err.log"