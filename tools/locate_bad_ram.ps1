# ============================================================
#  内存条定位 —— 读 SMBIOS 判断能否锁定故障条
# ============================================================
#  做法：解析 SMBIOS 原始表
#    Type 17「内存设备」  —— 每根条子的插槽名 / 容量 / 型号
#    Type 20「地址映射」  —— 每根条子占用的物理地址区间
#
#  用法（需 -ExecutionPolicy Bypass，不需要管理员）：
#    powershell -ExecutionPolicy Bypass -File locate_bad_ram.ps1
#
#  ★ 脚本不会编造答案。
#    如果内存是交错(interleave)的，它会明确告诉你「无法定位」，
#    并给出确定性的排查步骤。
# ============================================================

$ErrorActionPreference = 'Continue'

function W($s) { Write-Output $s }

W ""
W "============================================================"
W " 内存条定位"
W "============================================================"
W ""

# ---------- 读原始 SMBIOS ----------
$raw = Get-CimInstance -Namespace root\wmi -ClassName MSSMBios_RawSMBiosTables -ErrorAction SilentlyContinue
if (-not $raw) {
    W "  ✗ 读不到 SMBIOS 原始表。"
    W "    退而求其次 —— 物理内存清单："
    W ""
    Get-CimInstance Win32_PhysicalMemory | ForEach-Object {
        W ("    {0,-26} {1} GB  {2} MHz  {3}" -f $_.DeviceLocator,
            [math]::Round($_.Capacity / 1GB, 0), $_.ConfiguredClockSpeed, $_.PartNumber)
    }
    exit 1
}

$b = $raw.SMBiosData
W ("  读到 SMBIOS " + $b.Length + " 字节")
W ""

# ---------- 取结构体里的第 N 个字符串 ----------
function GS($buf, $start, $len, $idx) {
    if ($idx -le 0) { return '' }
    $p = $start + $len
    $n = 1
    $cur = ''
    while ($p -lt $buf.Length) {
        $ch = $buf[$p]
        if ($ch -eq 0) {
            if ($n -eq $idx) { return $cur }
            $n++
            $cur = ''
            if ($buf[$p + 1] -eq 0) { return '' }
        } else {
            $cur += [char]$ch
        }
        $p++
    }
    return ''
}

# ---------- 遍历结构体 ----------
$devs = @()
$map  = @()
$p = 0

while ($p -lt $b.Length - 3) {
    $t = $b[$p]
    $l = $b[$p + 1]
    if ($l -lt 4) { break }
    $h = [BitConverter]::ToUInt16($b, $p + 2)

    # Type 17 = 内存设备
    if ($t -eq 17 -and $l -ge 27) {
        $sw = [BitConverter]::ToUInt16($b, $p + 0x0C)
        if ($sw -eq 0x7FFF) { $mb = [BitConverter]::ToUInt32($b, $p + 0x1C) -band 0x7FFFFFFF }
        elseif ($sw -band 0x8000) { $mb = ($sw -band 0x7FFF) / 1024 }
        else { $mb = $sw }
        $devs += [pscustomobject]@{
            Handle = $h
            Loc    = (GS $b $p $l $b[$p + 0x10]).Trim()
            Bank   = (GS $b $p $l $b[$p + 0x11]).Trim()
            Mfr    = (GS $b $p $l $b[$p + 0x17]).Trim()
            Part   = (GS $b $p $l $b[$p + 0x1A]).Trim()
            MB     = $mb
        }
    }

    # Type 20 = 地址映射
    if ($t -eq 20 -and $l -ge 0x13) {
        $map += [pscustomobject]@{
            DevH  = [BitConverter]::ToUInt16($b, $p + 0x0C)
            Start = [BitConverter]::ToUInt32($b, $p + 0x04)
            End   = [BitConverter]::ToUInt32($b, $p + 0x08)
            IlPos = $b[$p + 0x11]
            IlDep = $b[$p + 0x12]
        }
    }

    # 跳到下一结构体
    $q = $p + $l
    while ($q -lt $b.Length - 1) {
        if ($b[$q] -eq 0 -and $b[$q + 1] -eq 0) { $q += 2; break }
        $q++
    }
    $p = $q
}

# ---------- 输出内存清单 ----------
W "------------------------------------------------------------"
W " 内存条清单"
W "------------------------------------------------------------"
foreach ($d in $devs) {
    W ("  {0,-26} {1,3} GB   {2}  {3}" -f $d.Loc, [math]::Round($d.MB / 1024, 0), $d.Mfr, $d.Part)
}

W ""
W "------------------------------------------------------------"
W " 物理地址映射"
W "------------------------------------------------------------"
foreach ($m in $map) {
    $d = $devs | Where-Object { $_.Handle -eq $m.DevH }
    $loc = if ($d) { $d.Loc } else { '(未知 0x{0:X4})' -f $m.DevH }
    # Interleaved Data Depth: 0=不交错 1=2路 2=4路 3=8路
    $ilTxt = switch ($m.IlDep) {
        0 { '不交错' }
        1 { '2 路交错' }
        2 { '4 路交错' }
        3 { '8 路交错' }
        default { "未知($($m.IlDep))" }
    }
    W ("  {0,-26} {1,6} GB ~ {2,6} GB   交错位置={3}  {4}" -f $loc,
        [math]::Round($m.Start / 1MB, 2), [math]::Round($m.End / 1MB, 2), $m.IlPos, $ilTxt)
}

# ---------- 判断能否定位 ----------
W ""
W "------------------------------------------------------------"
W " 结论"
W "------------------------------------------------------------"
W ""

# 多条映射指向同一段区间 = 交错
$ranges = $map | Group-Object { "$($_.Start)-$($_.End)" }
$isInterleaved = $false
foreach ($g in $ranges) {
    if ($g.Count -gt 1) { $isInterleaved = $true }
}
if (-not $isInterleaved) {
    foreach ($m in $map) { if ($m.IlDep -gt 0) { $isInterleaved = $true } }
}

if ($isInterleaved) {
    W "  ✗ 无法用软件定位到具体某一根。"
    W ""
    W "  原因：本机是【双通道交错】模式。"
    W "    两根条子映射到同一段物理地址区间，地址在两者之间交替分布。"
    W "    所以蓝屏报告里的那个出错地址，"
    W "    没法反推出它落在哪一根上 —— 这是内存控制器的工作方式决定的，"
    W "    不是工具不够好。"
    W ""
    W "  ── 确定性的排查步骤 ────────────────────────────────"
    W ""
    W "  单条测试法（比跑满 MemTest86 快得多）："
    W ""
    W "    1. 关机断电，拆后盖，拔掉其中一根（建议先拔右侧"
    W "       Bottom-Slot 2，多数机型这根更好拆）"
    W "    2. 只留一根开机，跑 MemTest86 至少 2 轮"
    W "       单条 8GB 一轮约 10 分钟，两轮 20 分钟"
    W "    3. 无报错 → 拔下来那根是好的，坏的是现在这根"
    W "       有报错 → 现在这根就是坏的"
    W "    4. 确认后买同型号换上即可："
    W "       DDR4-3200 SODIMM，SK Hynix HMA81GS6CJR8N-XN 或同规格"
    W ""
    W "  不想拆机的话：先跑 mdsched.exe（Windows 自带内存诊断），"
    W "    它能确认有没有问题，但同样不会告诉你是哪一根。"
} else {
    W "  ✓ 内存未交错，可以靠报错地址定位。"
    W ""
    W "  把蓝屏参数里的页帧号(PFN) 乘以 4096 得到物理地址，"
    W "  对照上面的区间表即可知道是哪一根。"
    W "  蓝屏记录："
    W ""
    $bs = Get-WinEvent -FilterHashtable @{
        LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; ID = 1001
    } | Sort-Object TimeCreated -Descending | Select-Object -First 10
    foreach ($e in $bs) {
        if ($e.Message -match '0x([0-9a-fA-F]{8})\s*\(([^)]*)\)') {
            $code = '0x' + $matches[1].ToUpper()
            $a = $matches[2] -split ',' | ForEach-Object { $_.Trim() }
            if ($a.Count -ge 2 -and $a[1] -match '^0x([0-9a-fA-F]+)$') {
                $v = [Convert]::ToUInt64($matches[1], 16)
                $pa = $v * 4096
                $kb = [math]::Round($pa / 1KB, 0)
                $hit = $map | Where-Object { $kb -ge $_.Start -and $kb -le $_.End }
                $who = if ($hit) { ($devs | Where-Object { $_.Handle -eq $hit[0].DevH }).Loc } else { '(区间外)' }
                W ("    {0}  {1}  PFN=0x{2:X} → {3} GB  >> {4}" -f
                    $e.TimeCreated.ToString('yyyy-MM-dd HH:mm'), $code, $v,
                    [math]::Round($pa / 1GB, 2), $who)
            }
        }
    }
}

W ""
W "============================================================"
W ""
