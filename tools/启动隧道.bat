@echo off
chcp 65001 >nul 2>&1
setlocal

REM ============================================================
REM  Prism 远程操控 —— 一键启动隧道
REM
REM  作用：把本机 Prism(:8080) 暴露到 prism.youyuanqi.dpdns.org
REM
REM  ★ 注意：Prism 本体是窗口程序，这个脚本拉不起来，
REM    请自己双击 桌面\prism工具箱.exe，然后再跑本脚本。
REM
REM  ★ 隧道进程笔记本休眠后会被掐断 —— 醒了再跑一次即可。
REM    想彻底省心就装成服务：
REM      cloudflared service install
REM ============================================================

set "CF=C:\Program Files (x86)\cloudflared\cloudflared.exe"
set "CFG=C:\Users\16650\WorkBuddy AI\2026-09-13-00-20-42\ds-platform-ai-assist\tunnel\config.yml"

echo.
echo ============================================================
echo   Prism 远程操控 - 启动隧道
echo ============================================================
echo.

if not exist "%CF%" (
    echo   [X] 找不到 cloudflared: %CF%
    echo       请先安装：https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/
    goto :end
)

if not exist "%CFG%" (
    echo   [X] 找不到配置文件: %CFG%
    goto :end
)

echo   [1/3] 检查是否已在运行...
tasklist /FI "IMAGENAME eq cloudflared.exe" 2>nul | find /I "cloudflared.exe" >nul
if %ERRORLEVEL%==0 (
    echo        隧道已在运行，先停掉旧的...
    taskkill /F /IM cloudflared.exe >nul 2>&1
    timeout /t 2 /nobreak >nul
)

echo   [2/3] 检查 Prism 是否已在 8080 监听...
netstat -ano | findstr ":8080" | findstr "LISTENING" >nul
if %ERRORLEVEL%==0 (
    echo        [OK] Prism 已就绪
) else (
    echo        [!] 8080 没在监听 —— Prism 还没开
    echo            请先双击 桌面\prism工具箱.exe，等它启动后再来
    echo            现在仍然继续开隧道，等 Prism 起来就能连上
)

echo   [3/3] 启动隧道...
echo.
echo   日志：
echo     prism.youyuanqi.dpdns.org  -^> 127.0.0.1:8080
echo     api.youyuanqi.dpdns.org    -^> 127.0.0.1:3000
echo     tunnel.youyuanqi.dpdns.org -^> 127.0.0.1:11434
echo.
echo   看到 "Registered tunnel connection" 就是成功了。
echo   按 Ctrl+C 停止。
echo   ----------------------------------------------------------

"%CF%" tunnel --config "%CFG%" run ds-platform

:end
echo.
pause
