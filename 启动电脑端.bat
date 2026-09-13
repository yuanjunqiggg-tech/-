@echo off
title Prism 电脑端 Agent
cd /d "%~dp0"

set "CWD=%~dp0"
set "CLI=auto"
set "PY="

REM 逐个试，必须是【真的能执行】的 python（WindowsApps 那个 stub 要排除）
for %%P in (
  "C:/Users/16650/.workbuddy-ai/binaries/python/versions/3.13.12/python.exe"
  "C:/Users/16650/AppData/Local/Programs/Python/Python313/python.exe"
  "py"
  "python"
) do (
  if not defined PY (
    %%~P -c "print(1)" >nul 2>nul
    if not errorlevel 1 set "PY=%%~P"
  )
)

if not defined PY goto :nopy

echo.
echo   ==========================================================
echo     电脑端 Agent 启动中
echo     Python   : %PY%
echo     工作目录 : %CWD%
echo     CLI      : %CLI%  (自动探测 codex / claude / gemini)
echo   ==========================================================
echo.
echo   启动后去手机控制台 -^> 「电脑」页开一个会话，这边立刻领活。
echo   关掉这个窗口就停止。
echo.

"%PY%" "%~dp0tools\pc_agent.py" --cli %CLI% --cwd "%CWD%"

echo.
echo   已退出。
pause
exit /b 0

:nopy
echo.
echo   没找到能用的 Python。
echo   装一个： https://www.python.org/downloads/
echo   装的时候务必勾上 "Add Python to PATH"
echo.
pause
exit /b 1
