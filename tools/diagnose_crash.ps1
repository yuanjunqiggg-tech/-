# ============================================================
#  崩溃诊断脚本 · 只读，不改任何设置
#  用法：powershell -ExecutionPolicy Bypass -File diagnose_crash.ps1
# ============================================================
#  输出内容：
#    1. 所有蓝屏记录与 bugcheck 码
#    2. 按 bugcheck 码统计（判断故障类型）
#    3. 内存诊断 / 页面退役事件
#    4. WHEA 硬件错误
#    5. 硬件配置
#    6. 磁盘健康
#    7. 崩溃前兆事件
# ============================================================

$ErrorActionPreference = 'SilentlyContinue'
function Head($t) { Write-Host ""; Write-Host ("=" * 62); Write-Host "  $t"; Write-Host ("=" * 62) }

Head "1. 蓝屏记录（全部）"

$bugchecks = @{}
$events = Get-WinEvent -FilterHashtable @{
    LogName      = 'System'
    ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'
    ID           = 1001
}

if (-not $events) {
    Write-Host "  未发现蓝屏记录（很好）"
} else {
    foreach ($e in ($events | Sort-Object TimeCreated)) {
        $code = '未知'
        if ($e.Message -match '0x([0-9a-fA-F]{8})') { $code = '0x' + $matches[1].ToUpper() }
        Write-Host ("  {0}   BugCheck={1}" -f $e.TimeCreated.ToString('yyyy-MM-dd HH:mm'), $code)

        $key = $code
        if ($bugchecks.ContainsKey($key)) { $bugchecks[$key]++ } else { $bugchecks[$key] = 1 }
    }
}

Head "2. 按蓝屏码统计"

$meanings = @{
    '0x0000001A' = 'MEMORY_MANAGEMENT —— 内存管理错误（内存故障典型）'
    '0x0000000A' = 'IRQL_NOT_LESS_OR_EQUAL —— 驱动/内存访问越界'
    '0x000000BE' = 'ATTEMPTED_WRITE_TO_READONLY_MEMORY —— 驱动写只读内存'
    '0x0000007E' = 'SYSTEM_THREAD_EXCEPTION_NOT_HANDLED —— 系统线程异常'
    '0x00000050' = 'PAGE_FAULT_IN_NONPAGED_AREA —— 访问无效内存'
    '0x0000012B' = 'FAULTY_HARDWARE_CORRUPTED_PAGE —— ★硬件损坏内存页'
    '0x00000154' = 'UNEXPECTED_STORE_EXCEPTION —— 存储/页面文件异常'
    '0x0000003B' = 'SYSTEM_SERVICE_EXCEPTION —— 系统服务异常'
    '0x00000124' = 'WHEA_UNCORRECTABLE_ERROR —— ★硬件不可纠正错误'
    '0x000000D1' = 'DRIVER_IRQL_NOT_LESS_OR_EQUAL —— 驱动问题'
    '0x000000EF' = 'CRITICAL_PROCESS_DIED —— 关键进程终止'
}

if ($bugchecks.Count -eq 0) {
    Write-Host "  无数据"
} else {
    foreach ($k in ($bugchecks.Keys | Sort-Object { -$bugchecks[$_] })) {
        $m = $meanings[$k]
        if (-not $m) { $m = '（未收录）' }
        Write-Host ("  {0,-12} x{1,-3} {2}" -f $k, $bugchecks[$k], $m)
    }

    Write-Host ""
    if ($bugchecks.ContainsKey('0x0000001A') -and $bugchecks['0x0000001A'] -ge 3) {
        Write-Host "  >>> 判断：0x1A 反复出现，强烈指向【内存硬件故障】" -ForegroundColor Red
    }
    if ($bugchecks.ContainsKey('0x0000012B') -or $bugchecks.ContainsKey('0x00000124')) {
        Write-Host "  >>> 判断：出现硬件级错误码，确认是硬件问题" -ForegroundColor Red
    }
}

Head "3. 内存诊断 / 页面退役"

$memEvents = Get-WinEvent -LogName System |
    Where-Object { $_.ProviderName -like '*Memory*' }

if (-not $memEvents) {
    Write-Host "  无内存诊断事件"
} else {
    foreach ($e in ($memEvents | Sort-Object TimeCreated -Descending | Select-Object -First 10)) {
        Write-Host ("  [{0}] {1}" -f $e.TimeCreated, ($e.Message -replace '\s+', ' '))
    }
    Write-Host ""
    Write-Host "  >>> 若出现「已删除错误的内存区域」= Windows 已确认内存坏页" -ForegroundColor Red
}

Head "4. WHEA 硬件错误"

$whea = Get-WinEvent -FilterHashtable @{LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'}
if (-not $whea) {
    Write-Host "  无 WHEA 记录"
} else {
    foreach ($e in ($whea | Sort-Object TimeCreated -Descending | Select-Object -First 10)) {
        Write-Host ("  [{0}] ID={1} {2}" -f $e.TimeCreated, $e.Id, ($e.Message -replace '\s+', ' ').Substring(0, [Math]::Min(180, $e.Message.Length)))
    }
}

Head "5. 硬件配置"

$cs = Get-CimInstance Win32_ComputerSystem
$bios = Get-CimInstance Win32_BIOS
$cpu = Get-CimInstance Win32_Processor
Write-Host ("  机型     : {0} {1}" -f $cs.Manufacturer, $cs.Model)
Write-Host ("  BIOS     : {0} {1} ({2})" -f $bios.Manufacturer, $bios.SMBIOSBIOSVersion, $bios.ReleaseDate.ToString('yyyy-MM-dd'))
Write-Host ("  CPU      : {0} ({1}核{2}线程)" -f $cpu.Name, $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors)
Write-Host ("  内存总量 : {0} GB" -f [math]::Round($cs.TotalPhysicalMemory / 1GB, 1))
Write-Host ""
Write-Host "  内存条明细："
Get-CimInstance Win32_PhysicalMemory | ForEach-Object {
    Write-Host ("    {0,-22} {1,-10} {2} GB  {3} MHz (实际 {4})" -f `
            $_.DeviceLocator, $_.Manufacturer, [math]::Round($_.Capacity / 1GB, 0), $_.Speed, $_.ConfiguredClockSpeed)
}

Head "6. 磁盘健康"

Get-PhysicalDisk | ForEach-Object {
    $d = $_
    Write-Host ("  {0}  {1}  {2} GB  健康={3}  状态={4}" -f `
            $d.DeviceId, $d.FriendlyName, [math]::Round($d.Size / 1GB, 0), $d.HealthStatus, $d.OperationalStatus)
}
Write-Host ""
Get-Volume | Where-Object DriveLetter | ForEach-Object {
    Write-Host ("  {0}:  剩余 {1} GB / 共 {2} GB" -f $_.DriveLetter, [math]::Round($_.SizeRemaining / 1GB, 1), [math]::Round($_.Size / 1GB, 1))
}

Head "7. 最近一次崩溃前 3 分钟的事件（找前兆）"

$last = Get-WinEvent -FilterHashtable @{
    LogName      = 'System'
    ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'
    ID           = 1001
} | Sort-Object TimeCreated -Descending | Select-Object -First 1

if ($last) {
    $t1 = $last.TimeCreated
    $t0 = $t1.AddMinutes(-3)
    Write-Host ("  崩溃时间：{0}，检查 {1} ~ {2}" -f $t1, $t0.ToString('HH:mm:ss'), $t1.ToString('HH:mm:ss'))
    Write-Host ""
    $pre = Get-WinEvent -FilterHashtable @{LogName = 'System'; StartTime = $t0; EndTime = $t1; Level = 1, 2, 3 }
    if (-not $pre) {
        Write-Host "  >>> 崩溃前无任何软件错误 —— 印证是【硬件级】故障，不是驱动问题" -ForegroundColor Yellow
    } else {
        foreach ($e in ($pre | Sort-Object TimeCreated)) {
            Write-Host ("  [{0}] {1} {2}" -f $e.TimeCreated.ToString('HH:mm:ss'), $e.ProviderName, ($e.Message -replace '\s+', ' ').Substring(0, [Math]::Min(120, $e.Message.Length)))
        }
    }
} else {
    Write-Host "  无崩溃记录"
}

Head "诊断完成"
Write-Host "  下一步：运行 fix_crash_mitigations.ps1（需管理员）做临时缓解"
Write-Host "  根治：用 MemTest86 测内存，定位并更换坏的内存条"
Write-Host ""
