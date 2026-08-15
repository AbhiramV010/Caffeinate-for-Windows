@echo off
:: batch version of caffeinate. can't touch the winapi directly from here,
:: so caffeinate.ps1 next to this file does that part
setlocal enabledelayedexpansion

set "WANT_DISPLAY=0"
set "WANT_IDLE=0"
set "WANT_SYSTEM=0"
set "WANT_USER=0"
set "TIMEOUT_SECS="
set "WAIT_PID="
set "CMD="

:parse
if "%~1"=="" goto afterparse
if /i "%~1"=="-d" (set "WANT_DISPLAY=1" & shift & goto parse)
if /i "%~1"=="-i" (set "WANT_IDLE=1" & shift & goto parse)
if /i "%~1"=="-s" (set "WANT_SYSTEM=1" & shift & goto parse)
if /i "%~1"=="-u" (set "WANT_USER=1" & shift & goto parse)
if /i "%~1"=="-t" (set "TIMEOUT_SECS=%~2" & shift & shift & goto parse)
if /i "%~1"=="-w" (set "WAIT_PID=%~2" & shift & shift & goto parse)
if /i "%~1"=="-h" goto usage
if /i "%~1"=="/?" goto usage
goto collectcmd

:collectcmd
set "CMD=%1"
shift
:collectcmd_loop
if "%~1"=="" goto afterparse
set "CMD=%CMD% %1"
shift
goto collectcmd_loop

:afterparse
:: didn't pass any flags, so just default to idle prevention
if "%WANT_DISPLAY%"=="0" if "%WANT_IDLE%"=="0" if "%WANT_SYSTEM%"=="0" set "WANT_IDLE=1"

set "PSARGS="
if "%WANT_DISPLAY%"=="1" set "PSARGS=%PSARGS% -Display"
if "%WANT_IDLE%"=="1" set "PSARGS=%PSARGS% -Idle"
if "%WANT_SYSTEM%"=="1" set "PSARGS=%PSARGS% -Idle"
if "%WANT_USER%"=="1" set "PSARGS=%PSARGS% -UserPresent"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0caffeinate.ps1" %PSARGS%

if defined CMD (
    echo caffeinate: running %CMD%
    call %CMD%
    goto reset
)

if defined WAIT_PID (
    echo caffeinate: waiting on pid %WAIT_PID%
    :waitloop
    tasklist /fi "PID eq %WAIT_PID%" 2>NUL | find /i "No tasks" >NUL
    if not errorlevel 1 goto reset
    timeout /t 2 >NUL
    goto waitloop
)

if defined TIMEOUT_SECS (
    echo caffeinate: holding for %TIMEOUT_SECS% seconds
    timeout /t %TIMEOUT_SECS% >NUL
    goto reset
)

echo caffeinate: running until Ctrl+C, close this window to stop
:idlewait
timeout /t 3600 >NUL
goto idlewait

:reset
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0caffeinate.ps1" -Reset
goto :eof

:usage
echo Usage: caffeinate.bat [-disu] [-t seconds] [-w pid] [command]
goto :eof
