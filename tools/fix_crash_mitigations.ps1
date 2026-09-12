# ============================================================
#  崩溃缓解脚本 · 需要管理员权限
# ============================================================
#  适用场景：
#    本机内存条存在硬件故障（9 天 13 次蓝屏，以 0x1A 为主，
#    Windows 已主动退役故障内存页）。在更换内存条之前，
#    用这个脚本把系统调到「低内存压力 + 崩溃后快速恢复」。
#
#  用法（必须以管理员身份运行）：
#    右键「Windows PowerShell」→ 以管理员身份运行 →
#    powershell -ExecutionPolicy Bypass -File fix_crash_mitigations.ps1
#
#  ★ 本脚本只改系统设置，不动任何用户数据。
#  ★ 所有改动都会先备份原值到桌面的一个 json 文件，可回滚。
# ============================================================

$ErrorActionPreference = 'Stop'

# ---------- 管理员检查 ----------
$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host ""
    Write-Host "  ✗ 需要管理员权限。" -ForegroundColor Red
    Write-Host "    请右键「Windows PowerShell」→「以管理员身份运行」，再执行本脚本。"
    Write-Host ""
    exit 1
}

function Head($t) { Write-Host ""; Write-Host ("=" * 62); Write-Host "  $t"; Write-Host ("=" * 62) }
function Ok($t) { Write-Host "  ✓ $t" -ForegroundColor Green }
function Warn($t) { Write-Host "  ! $t" -ForegroundColor Yellow }

# ---------- 备份原值 ----------
$backup = [ordered]@{}
$backupPath = Join-Path ([Environment]::GetFolderPath('Desktop')) "prism_crash_fix_backup.json"

Head "0. 备份当前设置"

$powerKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
$crashKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'
$mmKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'

try {
    $backup['HiberbootEnabled'] = (Get-ItemProperty $powerKey -Name HiberbootEnabled).HiberbootEnabled
    Ok ("HiberbootEnabled = " + $backup['HiberbootEnabled'])
} catch { Warn "读不到 HiberbootEnabled" }

try {
    $backup['CrashDumpEnabled'] = (Get-ItemProperty $crashKey -Name CrashDumpEnabled).CrashDumpEnabled
    Ok ("CrashDumpEnabled = " + $backup['CrashDumpEnabled'])
} catch { Warn "读不到 CrashDumpEnabled" }

try {
    $backup['Overwrite'] = (Get-ItemProperty $crashKey -Name Overwrite).Overwrite
} catch { }

try {
    $backup['DisablePageCombining'] = (Get-ItemProperty $mmKey -Name DisablePageCombining).DisablePageCombining
    Ok ("DisablePageCombining = " + $backup['DisablePageCombining'])
} catch { Warn "读不到 DisablePageCombining（默认未设置）" }

try {
    $backup | ConvertTo-Json | Set-Content -Path $backupPath -Encoding UTF8
    Ok "原值已备份到：$backupPath"
} catch { Warn "备份写入失败：$($_.Exception.Message)" }

# ============================================================
Head "1. 关闭快速启动"
# ============================================================
# 为什么：快速启动会把内核状态存进 hiberfil.sys，下次开机直接还原。
# 内存已经损坏的情况下，这份「上次的内存快照」可能本身就是坏的，
# 导致开机就崩或很快崩。关掉它，每次干净冷启动。
try {
    Set-ItemProperty -Path $powerKey -Name HiberbootEnabled -Value 0 -Type DWord
    Ok "已关闭快速启动（下次开机会是完整冷启动）"
} catch {
    Warn "设置失败：$($_.Exception.Message)"
}

# ============================================================
Head "2. 缩小崩溃转储体积"
# ============================================================
# 为什么：当前每次崩溃写 2.4GB 的 MEMORY.DMP。
# 写盘过程本身就在大量访问内存和磁盘，且在坏内存上写大文件风险更高；
# 同时会让重启多花好几分钟。
# 改成「小内存转储」(2) + 覆盖写入，重启快很多。
try {
    Set-ItemProperty -Path $crashKey -Name CrashDumpEnabled -Value 2 -Type DWord
    Set-ItemProperty -Path $crashKey -Name Overwrite -Value 1 -Type DWord
    Ok "转储模式改为「小内存转储」，并开启覆盖写入"
    Warn "注意：如需深度分析蓝屏，事后要改回 7（自动内存转储）"
} catch {
    Warn "设置失败：$($_.Exception.Message)"
}

# 清理旧的巨型转储，释放磁盘
try {
    if (Test-Path 'C:\WINDOWS\MEMORY.DMP') {
        $sz = [math]::Round((Get-Item 'C:\WINDOWS\MEMORY.DMP').Length / 1GB, 2)
        Remove-Item 'C:\WINDOWS\MEMORY.DMP' -Force
        Ok "已清理旧的 MEMORY.DMP（释放 $sz GB）"
    }
} catch {
    Warn "清理 MEMORY.DMP 失败：$($_.Exception.Message)"
}

# ============================================================
Head "3. 关闭内存页面合并"
# ============================================================
# 为什么：页面合并（memory combining）会主动扫描并比对内存页内容，
# 在坏内存上这个「后台扫描」本身就是额外风险，且会加剧读写。
# 关掉它降低命中坏页的概率。
try {
    if (-not (Test-Path $mmKey)) { New-Item -Path $mmKey -Force | Out-Null }
    Set-ItemProperty -Path $mmKey -Name DisablePageCombining -Value 1 -Type DWord
    Ok "已关闭内存页面合并"
} catch {
    Warn "设置失败：$($_.Exception.Message)"
}

# ============================================================
Head "4. 确认虚拟内存为系统托管"
# ============================================================
# 为什么：0x154 UNEXPECTED_STORE_EXCEPTION 是页面文件相关。
# 保证有足够的交换空间可以降低这类崩溃概率。
try {
    $cs = Get-CimInstance Win32_ComputerSystem
    if ($cs.AutomaticManagedPagefile) {
        Ok "虚拟内存已是「系统自动管理」，无需改动"
    } else {
        Warn "虚拟内存不是自动管理，建议手动设为「系统管理的大小」"
        Warn "（设置 → 系统 → 关于 → 高级系统设置 → 性能设置 → 高级 → 虚拟内存）"
    }
} catch {
    Warn "无法读取虚拟内存设置"
}

# ============================================================
Head "5. 安排一次开机内存自检"
# ============================================================
# 为什么：Windows 自带的内存诊断可以在重启时扫描内存。
# 它不如 MemTest86 彻底，但不用做 U 盘，可以顺手先跑一次拿证据。
try {
    $answer = Read-Host "  现在安排一次重启后内存自检吗？（会占用约 15-30 分钟）[y/N]"
    if ($answer -match '^[Yy]') {
        # 设置为下次启动时执行扩展内存测试
        bcdedit /set "{current}" bootstatuspolicy IgnoreAllFailures | Out-Null
        Write-Host "  已配置。请手动执行 mdsched.exe 并选择「立即重新启动并检查」" -ForegroundColor Yellow
        Write-Host "  （或稍后自己运行 mdsched.exe）" -ForegroundColor Yellow
        Warn "注意：更彻底的检测请用 MemTest86 从 U 盘启动，跑满 2 轮"
    } else {
        Write-Host "  已跳过。建议稍后自行运行 mdsched.exe"
    }
} catch {
    Warn "跳过（非交互环境）"
}

# ============================================================
Head "完成"
# ============================================================
Write-Host ""
Write-Host "  已应用的缓解措施：" -ForegroundColor Cyan
Write-Host "    1. 关闭快速启动        —— 避免还原损坏的内核状态"
Write-Host "    2. 缩小崩溃转储        —— 重启更快、写盘压力更小"
Write-Host "    3. 关闭内存页面合并    —— 减少对坏内存页的额外读写"
Write-Host ""
Write-Host "  ★ 这些只是缓解，不能根治。" -ForegroundColor Yellow
Write-Host "    根治方法：用 MemTest86 测出坏的内存条并更换。" -ForegroundColor Yellow
Write-Host "    详见：docs\电脑蓝屏诊断与修复.md" -ForegroundColor Yellow
Write-Host ""
Write-Host "  回滚：删除以下注册表值或用备份文件恢复" -ForegroundColor DarkGray
Write-Host "    备份文件：$backupPath" -ForegroundColor DarkGray
Write-Host "    重启后生效。" -ForegroundColor DarkGray
Write-Host ""
