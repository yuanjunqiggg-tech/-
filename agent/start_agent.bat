@echo off
REM ============================================================
REM  Prism Controlled Agent - Windows one-click launcher
REM
REM  Run this INSIDE the cloud Windows host (same machine as Prism).
REM  It connects OUT to the Cloudflare gateway - no public IP,
REM  no router config, no cloudflared needed.
REM
REM  Prism must already be running on 127.0.0.1:8080.
REM ============================================================
chcp 65001 >nul
setlocal

cd /d "%~dp0"

set PRISM_GATEWAY=https://ai-api.youyuanqi.dpdns.org
set PRISM_URL=http://127.0.0.1:8080
set AGENT_STATE=%~dp0agent_state.json

echo.
echo   Prism Controlled Agent
echo   ----------------------------------------
echo   Gateway : %PRISM_GATEWAY%
echo   Prism   : %PRISM_URL%
echo   State   : %AGENT_STATE%
echo.

if not defined AGENT_NAME set AGENT_NAME=WinHost-1

if exist "%~dp0prism-agent.exe" (
  echo   Starting prism-agent.exe ...
  "%~dp0prism-agent.exe" --name "%AGENT_NAME%"
) else (
  echo   prism-agent.exe not found, falling back to python ...
  python prism_agent.py --name "%AGENT_NAME%"
)

echo.
echo   Agent exited. Press any key to close.
pause >nul
endlocal
