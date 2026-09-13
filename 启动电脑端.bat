@echo off
chcp 65001 >nul
title Prism 电脑端 Agent —— 手机遥控这台电脑

REM ============================================================
REM  双击这个就能让手机遥控这台电脑跑 Codex / Claude
REM
REM  想改默认工作目录就改下面这行（Codex 会在这个目录里干活）
REM ============================================================

set "CWD=%~dp0"
set "CLI=auto"
set "PY="

REM 找一个能用的 python
where python >nul 2>nul && set "PY=python" && goto :found
where py      >nul 2>nul && set "PY=py"      && goto :found
if exist "C:\Users\16650\.workbuddy-ai\binaries\python\versions\3.13.12\python.exe" (
  set "PY=C:\Users\16650\.workbuddy-ai\binaries\python\versions\3.13.12\python.exe"
  goto :found
)
echo.
echo   [!] 没找到 Python。先装一个：https://www.python.org/downloads/
echo       装的时候记得勾上 "Add Python to PATH"
echo.
pause
exit /b 1

:found
echo.
echo   Python  : %PY%
echo   工作目录: %CWD%
echo   CLI     : %CLI%  (自动探测 codex / claude / gemini)
echo.
echo   启动后去手机控制台 ^-^> 「电脑」页开一个会话，这边会立刻领活。
echo   关掉这个窗口就停止。Ctrl+C 也能退。
echo.
echo ============================================================
echo.

"%PY%" "%~dp0tools\pc_agent.py" --cli %CLI% --cwd "%CWD%"

echo.
echo   已退出。
pause
