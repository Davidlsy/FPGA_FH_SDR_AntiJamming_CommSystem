# =====================================================================
# run_s4_acceptance.ps1 — S4 发射链 · 统一验收
#
# 任务卡 §S4 的出口门槛是「五模块位真比对全过」，本脚本把 P0+P1 已落地的三模块
# （frame_tx / conv_enc / qpsk_map）位真比对按依赖顺序串跑一遍，产出唯一判据行。
#
# 两类套件：
#   正例  = DUT 与 S1 定点参考逐拍比对，必须 status=PASS 且 compared == 期望行数
#   反例  = 故意把一个"看起来很像"的地方改错（I/Q 互换、位序颠倒、CRC 多项式换错），
#           必须 status=FAIL —— 反例跑不出 FAIL，说明向量没有鉴别力，正例的 PASS 也不值钱
#
# 判据口径与 run_s2/s3 一致：xsim 批处理即使 $fatal 也返回 0，所以判成败只看
# 日志里的 [VEC-RESULT] 行（纯 ASCII），退出码只作必要条件。
#
# 用法:
#   .\run_s4_acceptance.ps1           # 短用例（默认，几次 xsim，分钟级）
#   .\run_s4_acceptance.ps1 -Full     # 追加任务卡的两条长跑判据：
#                                     #   frame_tx 1000 随机帧 / conv_enc 10⁶ bit
# 前置：xvlog/xelab/xsim 在 PATH（call D:\software\vivado2021\Vivado\2021.2\settings64.bat）、
#       python 带 numpy。
# =====================================================================
param(
    [switch] $Full
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath (Join-Path $PSScriptRoot 'framework')

$RepoRoot     = Split-Path -Parent $PSScriptRoot
$FrameworkDir = $PSScriptRoot | Join-Path -ChildPath 'framework'
$SrcDir       = Join-Path $RepoRoot 'src'
$LogDir       = Join-Path $PSScriptRoot 'logs'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$AggLog = Join-Path $LogDir 's4_acceptance.log'

# blk_mem_gen（正式交付版存储）的仿真模型路径；由 build/gen_blk_mem_gen.tcl 生成
$IpDir   = Join-Path $RepoRoot 'build\ip\blk_mem_gen\blk_mem_gen_1w1r'
$IpModel = Join-Path $IpDir 'sim\blk_mem_gen_1w1r.v'
$IpPrim  = Join-Path $IpDir 'simulation\blk_mem_gen_v8_4.v'

foreach ($tool in @('xvlog', 'xelab', 'xsim', 'python')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "$tool not found in PATH. Run: call D:\software\vivado2021\Vivado\2021.2\settings64.bat"
    }
}

# ---------------------------------------------------------------------
# 1. 向量：判据的输入，先按固定种子确定性重生成
# ---------------------------------------------------------------------
Write-Host '[0] 导出位真向量（golden_ref → .hex）'
$exportArgs = @((Join-Path $FrameworkDir 'export_vectors.py'))
if ($Full) { $exportArgs += '--case'; $exportArgs += 'all' }   # all + --full 才带长跑用例
if ($Full) { $exportArgs += '--full' }
& python @exportArgs | ForEach-Object { Write-Host "      $_" }
if ($LASTEXITCODE -ne 0) { throw 'export_vectors.py failed' }

# ---------------------------------------------------------------------
# 1b. blk_inter 的正式版存储（blk_mem_gen）按需生成：产物不入库、可重建（约 40 s）
#     缺了就先建，之后 P2 的 IP 版套件才有东西可编译。
# ---------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $IpModel)) {
    Write-Host '[0b] 生成 blk_mem_gen IP（首次约 40 s，产物不入库）'
    & vivado -mode batch -nojournal -nolog -source (Join-Path $RepoRoot 'build\gen_blk_mem_gen.tcl') *> (Join-Path $LogDir 'gen_blk_mem_gen.log')
    if (-not (Test-Path -LiteralPath $IpModel)) {
        throw "blk_mem_gen IP 生成失败，见 $(Join-Path $LogDir 'gen_blk_mem_gen.log')"
    }
    Write-Host '      [BLK-MEM-GEN] OK'
}

# ---------------------------------------------------------------------
# 2. 套件表：Name / Testbench / 源文件清单 / define / 期望判据 / 说明
#    正例要求 status=PASS，反例要求 status=FAIL（反例若 PASS 说明向量抓不住这个错）
# ---------------------------------------------------------------------
$src = $SrcDir
$suites = @(
    [pscustomobject]@{ Name = 'qpsk-rand'; Tb = 'tb_qpsk_map_compare';
        Sources = @("$src\qpsk_map.v");
        Defines = @(); Expect = 'status=PASS.*vectors=4096 compared=4096 errors=0';
        ExpectFail = $false; Note = 'qpsk_map 4096 随机符号 1:1 位真' },
    [pscustomobject]@{ Name = 'qpsk-edge'; Tb = 'tb_qpsk_map_compare';
        Sources = @("$src\qpsk_map.v");
        Defines = @('QPSK_CASE_EDGE'); Expect = 'status=PASS.*vectors=196 compared=196 errors=0';
        ExpectFail = $false; Note = 'qpsk_map 四星座点 + 全 0/全 1 + 最坏码型' },
    [pscustomobject]@{ Name = 'conv-frame'; Tb = 'tb_conv_enc_compare';
        Sources = @("$src\conv_enc.v");
        Defines = @(); Expect = 'status=PASS.*vectors=2166 compared=2166 errors=0';
        ExpectFail = $false; Note = 'conv_enc 1 块 2160 bit → 2166 拍（含 6 尾码字）' },
    [pscustomobject]@{ Name = 'conv-rand'; Tb = 'tb_conv_enc_compare';
        Sources = @("$src\conv_enc.v");
        Defines = @('CONV_CASE_RAND'); Expect = 'status=PASS.*vectors=17328 compared=17328 errors=0';
        ExpectFail = $false; Note = 'conv_enc 8 块背靠背：块边界、尾比特与弹性缓冲' },
    [pscustomobject]@{ Name = 'conv-edge'; Tb = 'tb_conv_enc_compare';
        Sources = @("$src\conv_enc.v");
        Defines = @('CONV_CASE_EDGE'); Expect = 'status=PASS.*vectors=8664 compared=8664 errors=0';
        ExpectFail = $false; Note = 'conv_enc 全 0 / 全 1 / 交替 / 首位单 1' },
    [pscustomobject]@{ Name = 'frame-single'; Tb = 'tb_frame_tx_compare';
        Sources = @("$src\frame_tx.v");
        Defines = @(); Expect = 'status=PASS.*vectors=2160 compared=2160 errors=0';
        ExpectFail = $false; Note = 'frame_tx 1 帧：256 拍载荷 → 2160 拍比特流' },
    [pscustomobject]@{ Name = 'frame-multi'; Tb = 'tb_frame_tx_compare';
        Sources = @("$src\frame_tx.v");
        Defines = @('FRAME_CASE_MULTI'); Expect = 'status=PASS.*vectors=17280 compared=17280 errors=0';
        ExpectFail = $false; Note = 'frame_tx 8 帧背靠背：帧号递增 + 双缓冲 + CRC 每帧重算' },
    [pscustomobject]@{ Name = 'frame-edge'; Tb = 'tb_frame_tx_compare';
        Sources = @("$src\frame_tx.v");
        Defines = @('FRAME_CASE_EDGE'); Expect = 'status=PASS.*vectors=8640 compared=8640 errors=0';
        ExpectFail = $false; Note = 'frame_tx 载荷全 0 / 全 0xFF / 0xAA-0x55 / 单比特' },
    [pscustomobject]@{ Name = 'blk-frame'; Tb = 'tb_blk_inter_compare';
        Sources = @("$src\blk_inter.v", "$src\blk_mem_1w1r.v");
        Defines = @(); Expect = 'status=PASS.*vectors=2170 compared=2170 errors=0';
        ExpectFail = $false; Note = 'blk_inter 1 块（真实编码帧激励）：2166 → 2170 拍' },
    [pscustomobject]@{ Name = 'blk-rand'; Tb = 'tb_blk_inter_compare';
        Sources = @("$src\blk_inter.v", "$src\blk_mem_1w1r.v");
        Defines = @('BLK_CASE_RAND'); Expect = 'status=PASS.*vectors=17360 compared=17360 errors=0';
        ExpectFail = $false; Note = 'blk_inter 8 块背靠背：双缓冲 + 补零 + 速率约束（节奏 1/2）' },
    [pscustomobject]@{ Name = 'blk-edge'; Tb = 'tb_blk_inter_compare';
        Sources = @("$src\blk_inter.v", "$src\blk_mem_1w1r.v");
        Defines = @('BLK_CASE_EDGE'); Expect = 'status=PASS.*vectors=8680 compared=8680 errors=0';
        ExpectFail = $false; Note = 'blk_inter 边界块：全 0 / 全 1 / 交替 / 首位单 1' },
    [pscustomobject]@{ Name = 'blk-burst'; Tb = 'tb_blk_inter_burst';
        Sources = @("$src\blk_inter.v", "$src\blk_mem_1w1r.v");
        Defines = @(); Expect = '\[BURST-RESULT\].*restore=1 errors=10 rows=10 .*status=PASS';
        ExpectFail = $false; Note = 'blk_inter 突发 10 bit → 打散到 10 个码字行（无交织 1 行）' },
    [pscustomobject]@{ Name = 'neg-qpsk'; Tb = 'tb_qpsk_map_compare';
        Sources = @("$src\qpsk_map.v");
        Defines = @('QPSK_NEG_SWAP'); Expect = 'status=FAIL';
        ExpectFail = $true; Note = '证伪：qpsk_map I/Q 互换必须被判 FAIL' },
    [pscustomobject]@{ Name = 'neg-conv'; Tb = 'tb_conv_enc_compare';
        Sources = @("$src\conv_enc.v");
        Defines = @('CONV_NEG_ORDER'); Expect = 'status=FAIL';
        ExpectFail = $true; Note = '证伪：conv_enc {g1,g2} 位序颠倒必须被判 FAIL' },
    [pscustomobject]@{ Name = 'neg-frame'; Tb = 'tb_frame_tx_compare';
        Sources = @("$src\frame_tx.v");
        Defines = @('FRAME_NEG_CRC'); Expect = 'status=FAIL';
        ExpectFail = $true; Note = '证伪：frame_tx CRC 多项式换错必须被判 FAIL' },
    [pscustomobject]@{ Name = 'neg-blk'; Tb = 'tb_blk_inter_compare';
        Sources = @("$src\blk_inter.v", "$src\blk_mem_1w1r.v");
        Defines = @('BLK_NEG_SWAP'); Expect = 'status=FAIL';
        ExpectFail = $true; Note = '证伪：blk_inter 输出 {I,Q} 互换必须被判 FAIL' },
    # 正式交付版存储：blk_mem_gen IP。跑同一套向量，位真结果必须与 RTL 推断版一致。
    [pscustomobject]@{ Name = 'blk-ip-frame'; Tb = 'tb_blk_inter_compare';
        Sources = @("$src\blk_inter.v", "$src\blk_mem_1w1r.v", $IpModel, $IpPrim);
        Defines = @('BLK_INTER_USE_BRAM_IP'); Expect = 'status=PASS.*vectors=2170 compared=2170 errors=0';
        ExpectFail = $false; Note = 'blk_inter（blk_mem_gen 版）1 块：与 RTL 推断版同向量同位真' },
    [pscustomobject]@{ Name = 'blk-ip-burst'; Tb = 'tb_blk_inter_burst';
        Sources = @("$src\blk_inter.v", "$src\blk_mem_1w1r.v", $IpModel, $IpPrim);
        Defines = @('BLK_INTER_USE_BRAM_IP'); Expect = '\[BURST-RESULT\].*restore=1 errors=10 rows=10 .*status=PASS';
        ExpectFail = $false; Note = 'blk_inter（blk_mem_gen 版）突发打散量化：同样 10 行' },
    # P3：srrc_duc = SRRC 多相滤波 + NCO 上变频 + DUC 混频（2170 符号 → 8712 采样 full 卷积）
    [pscustomobject]@{ Name = 'srrc-frame'; Tb = 'tb_srrc_duc_compare';
        Sources = @("$src\srrc_duc.v");
        Defines = @(); Expect = 'status=PASS.*vectors=8712 compared=8712 errors=0';
        ExpectFail = $false; Note = 'srrc_duc 2170 符号 → 8712 采样（full 卷积 4N+32 + NCO 混频）位真' },
    [pscustomobject]@{ Name = 'srrc-edge'; Tb = 'tb_srrc_duc_compare';
        Sources = @("$src\srrc_duc.v");
        Defines = @('SRRC_CASE_EDGE'); Expect = 'status=PASS.*vectors=8712 compared=8712 errors=0';
        ExpectFail = $false; Note = 'srrc_duc 边界符号：四星座点 + 全 0/全 1 连续段' }
)

if ($Full) {
    $suites += [pscustomobject]@{ Name = 'conv-long'; Tb = 'tb_conv_enc_compare';
        Sources = @("$src\conv_enc.v");
        Defines = @('CONV_CASE_LONG'); Expect = 'status=PASS.*vectors=1002858 compared=1002858 errors=0';
        ExpectFail = $false; Note = '任务卡判据：conv_enc 463 块 = 1,000,080 bit 逐拍 0 错误' }
    $suites += [pscustomobject]@{ Name = 'frame-long'; Tb = 'tb_frame_tx_compare';
        Sources = @("$src\frame_tx.v");
        Defines = @('FRAME_CASE_LONG'); Expect = 'status=PASS.*vectors=2160000 compared=2160000 errors=0';
        ExpectFail = $false; Note = '任务卡判据：frame_tx 1000 随机帧逐拍 0 错误' }
}

# ---------------------------------------------------------------------
# 3. 单套件：编译 → 精化 → 仿真 → 取 [VEC-RESULT]
# ---------------------------------------------------------------------
function Invoke-Suite {
    param([pscustomobject] $Suite)

    foreach ($dir in 'work', 'xsim.dir') {
        $path = Join-Path $FrameworkDir $dir
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
    }

    $xvlogLog = Join-Path $LogDir "$($Suite.Name).xvlog.log"
    $xelabLog = Join-Path $LogDir "$($Suite.Name).xelab.log"
    $xsimLog  = Join-Path $LogDir "$($Suite.Name).xsim.log"

    $xvlogArgs = @('-sv', '-i', $SrcDir)
    foreach ($define in $Suite.Defines) { $xvlogArgs += @('-d', $define) }
    $xvlogArgs += @('-work', 'work', 'hdl/tb_vec_cmp.sv', "tb/$($Suite.Tb).sv")
    foreach ($source in $Suite.Sources) { $xvlogArgs += $source }

    $result = [pscustomobject]@{ Exit = 127; Text = ''; Error = $null }
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & xvlog @xvlogArgs *> $xvlogLog
        if ($LASTEXITCODE -ne 0) { $result.Error = "xvlog failed -> $xvlogLog"; return $result }

        & xelab -relax -timescale 1ns/1ps -snapshot "snap_$($Suite.Name)" -debug typical `
                "work.$($Suite.Tb)" *> $xelabLog
        if ($LASTEXITCODE -ne 0) { $result.Error = "xelab failed -> $xelabLog"; return $result }

        & xsim "snap_$($Suite.Name)" -runall *> $xsimLog
        if (-not (Test-Path -LiteralPath $xsimLog)) { $result.Error = "xsim produced no log -> $xsimLog"; return $result }
        $result.Text = Get-Content -LiteralPath $xsimLog -Raw
        $result.Exit = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
    } catch {
        $result.Error = $_.Exception.Message
    } finally {
        $ErrorActionPreference = $saved
    }
    return $result
}

# ---------------------------------------------------------------------
# 4. 串跑 + 汇总
# ---------------------------------------------------------------------
$records = @()
$index = 0
$totalWatch = [Diagnostics.Stopwatch]::StartNew()

foreach ($suite in $suites) {
    $index++
    Write-Host ("[{0}/{1}] {2}  ({3})" -f $index, $suites.Count, $suite.Name, $suite.Note)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $run = Invoke-Suite -Suite $suite
    $watch.Stop()
    $seconds = [math]::Round($watch.Elapsed.TotalSeconds, 1)

    $line = ''
    if ($null -eq $run.Error) {
        # 判据行有两类：逐拍比对器的 [VEC-RESULT] 与模块专属检查的 [BURST-RESULT]
        $m = [regex]::Matches($run.Text, '\[(?:VEC|BURST)-RESULT\][^\r\n]*')
        if ($m.Count -gt 0) { $line = $m[$m.Count - 1].Value }
    }

    $hit = ($line -match $suite.Expect)
    # 正例要求 status=PASS，反例要求 status=FAIL（反例若 PASS 说明向量抓不住这个错）
    $pass = ($null -eq $run.Error) -and $hit
    if ($suite.ExpectFail -and $line -notmatch 'status=FAIL') { $pass = $false }
    if ((-not $suite.ExpectFail) -and $line -notmatch 'status=PASS') { $pass = $false }

    $reason = 'ok'
    if ($null -ne $run.Error) { $reason = $run.Error }
    elseif (-not $hit) { $reason = "verdict mismatch: $line" }

    Write-Host ("      -> {0}  {1} s" -f $(if ($pass) { 'PASS' } else { 'FAIL' }), $seconds)
    if (-not $pass) { Write-Host "      reason: $reason" }
    if ($line) { Write-Host "      $line" }

    $records += [pscustomobject]@{
        Name    = $suite.Name
        Note    = $suite.Note
        Pass    = $pass
        Line    = $line
        Seconds = $seconds
        Reason  = $reason
        Run     = $run
    }
}
$totalWatch.Stop()

# 总日志：各项完整 stdout 顺序拼接，作为一次验收的原始证据
$stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
$buffer = New-Object System.Text.StringBuilder
[void]$buffer.AppendLine("S4 acceptance run @ $stamp   full=$Full")
[void]$buffer.AppendLine("host: $env:COMPUTERNAME   pwd: $FrameworkDir")
[void]$buffer.AppendLine('')
[void]$buffer.AppendLine("suite            verdict   secs   note")
foreach ($r in $records) {
    [void]$buffer.AppendLine(("{0,-17}{1,-10}{2,-7}{3}" -f $r.Name, $(if ($r.Pass) { 'PASS' } else { 'FAIL' }), $r.Seconds, $r.Note))
}
foreach ($r in $records) {
    [void]$buffer.AppendLine('')
    [void]$buffer.AppendLine(('=' * 72))
    [void]$buffer.AppendLine("suite: $($r.Name)   ($($r.Note))")
    [void]$buffer.AppendLine(('=' * 72))
    if ($null -ne $r.Run.Error) { [void]$buffer.AppendLine("ERROR: $($r.Run.Error)") }
    [void]$buffer.AppendLine($r.Run.Text)
}
[IO.File]::WriteAllText($AggLog, $buffer.ToString(), [Text.UTF8Encoding]::new($false))

$failed = @($records | Where-Object { -not $_.Pass })
$positives = @($records | Where-Object { $_.Line -match 'status=PASS' })

Write-Host ''
Write-Host '====================== S4 acceptance ======================'
foreach ($r in $records) {
    $mark = if ($r.Pass) { 'PASS' } else { 'FAIL' }
    Write-Host ("  [{0}] {1,-14} {2,6} s  {3}" -f $mark, $r.Name, $r.Seconds, $r.Note)
}
Write-Host '=========================================================='
Write-Host ("  suites  : {0}/{1}" -f ($records.Count - $failed.Count), $records.Count)
Write-Host ("  elapsed : {0} s" -f [math]::Round($totalWatch.Elapsed.TotalSeconds, 1))
Write-Host ("  log     : {0}" -f $AggLog)

$status = if ($failed.Count -eq 0) { 'PASS' } else { 'FAIL' }
Write-Host ("[S4 ACCEPTANCE] suites={0} failed={1} positives={2} full={3} status={4}" -f `
    $records.Count, $failed.Count, $positives.Count, $Full, $status)

if ($failed.Count -eq 0) { exit 0 }
exit 1
