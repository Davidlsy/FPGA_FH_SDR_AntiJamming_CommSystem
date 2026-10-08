# =====================================================================
# run_selftest.ps1 — S2 比对框架 · 一键自测
#
# 九项检查，判据全部取日志里那一行纯 ASCII 的 [VEC-RESULT]：
#   1. 正路径 rand       → status=PASS，4096/4096，0 错误
#   2. 正路径 edge       → status=PASS，196/196，0 错误
#   3. 正路径 1:N ratio  → status=PASS，stim 3 拍 / 期望 9 拍，0 错误（S4-P0 扩展）
#   4. 正路径 节奏激励   → status=PASS，1/N 有效（多速率模块的形状）
#   5. 正路径 接收链形状 → status=PASS，4:1 抽取 + 跳过 5 拍前导，skipped=5（S5 新增）
#   6. 负路径 rand       → status=FAIL，errors=1，first_mismatch=1000（注入点）
#   7. 负路径 多吐输出   → status=FAIL，extra=3（1:N 契约下多余输出必须被抓）
#   8. 负路径 不跳前导   → status=FAIL，first_mismatch=1（证伪 SKIP_OUT，S5 新增）
#   9. 桩死 edge         → status=FAIL，timeout=1，compared=0（看门狗收口）
#
# 两条本机实测约束，脚本据此设计：
#   · xsim 批处理模式即使 $fatal 也返回退出码 0，不能靠 $LASTEXITCODE 判成败
#     （与 sim/models/ad9363/run_xsim.bat 同一口径，同样判日志）；
#   · 日志经重定向后中文编码不可靠，故判据只用 ASCII 字段，不 match 中文。
#
# 用法：.\run_selftest.ps1
# 前置：xvlog/xelab/xsim 在 PATH，python 带 numpy。
# =====================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot

foreach ($tool in 'xvlog', 'xelab', 'xsim', 'python') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "$tool not found in PATH. Run: call D:\software\vivado2021\Vivado\2021.2\settings64.bat"
    }
}

$LogDir = Join-Path $PSScriptRoot 'logs'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

function Invoke-VectorSim {
    param(
        [Parameter(Mandatory)][string] $Tag,
        [string[]] $Defines = @()
    )

    # 每次重编前清掉库与快照，避免上一组的 define 残留
    foreach ($dir in 'work', 'xsim.dir') {
        $path = Join-Path $PSScriptRoot $dir
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
    }

    $snapshot = "snap_$Tag"
    $xvlogLog = Join-Path $LogDir "$Tag.xvlog.log"
    $xelabLog = Join-Path $LogDir "$Tag.xelab.log"
    $xsimLog  = Join-Path $LogDir "$Tag.xsim.log"

    $xvlogArgs = @('-sv')
    foreach ($define in $Defines) { $xvlogArgs += @('-d', $define) }
    $xvlogArgs += @('-work', 'work', 'hdl/tb_vec_cmp.sv', 'tb/tb_vector_selftest.sv')

    & xvlog @xvlogArgs *> $xvlogLog
    if ($LASTEXITCODE -ne 0) { throw "xvlog failed ($Tag), see $xvlogLog" }

    & xelab -relax -timescale 1ns/1ps -snapshot $snapshot -debug typical work.tb_vector_selftest *> $xelabLog
    if ($LASTEXITCODE -ne 0) { throw "xelab failed ($Tag), see $xelabLog" }

    & xsim $snapshot -runall *> $xsimLog
    return (Get-Content -LiteralPath $xsimLog -Raw)
}

function Test-Result {
    param(
        [Parameter(Mandatory)][string] $Log,
        [Parameter(Mandatory)][string] $Pattern
    )
    return [bool]($Log -match '\[VEC-RESULT\].*' -and $Log -match $Pattern)
}

$checks = @()

# 只导 qpsk_map：自测要的是"框架可信"，不该被别的模块的向量生成拖累或牵连。
Write-Host '[1/10] Export golden vectors (golden_ref fixed-point model -> .hex)'
& python (Join-Path $PSScriptRoot 'export_vectors.py') --module qpsk_map | ForEach-Object { Write-Host "      $_" }
if ($LASTEXITCODE -ne 0) { throw 'export_vectors.py failed, vectors not generated' }

Write-Host '[2/10] Positive path: rand'
$log = Invoke-VectorSim -Tag 'pos_rand'
$checks += [pscustomobject]@{
    Name   = 'positive rand'
    Pass   = Test-Result -Log $log -Pattern 'status=PASS.*vectors=4096 compared=4096 errors=0'
    Detail = 'golden-consistent DUT must be judged PASS (4096 beats)'
}

Write-Host '[3/10] Positive path: edge'
$log = Invoke-VectorSim -Tag 'pos_edge' -Defines @('SELFTEST_CASE_EDGE')
$checks += [pscustomobject]@{
    Name   = 'positive edge'
    Pass   = Test-Result -Log $log -Pattern 'status=PASS.*vectors=196 compared=196 errors=0'
    Detail = 'edge-case vector must be judged PASS (196 beats)'
}

Write-Host '[4/10] Positive path: 1:N (3 stim beats -> 9 expect beats)'
$log = Invoke-VectorSim -Tag 'pos_ratio' -Defines @('SELFTEST_CASE_RATIO')
$checks += [pscustomobject]@{
    Name   = 'positive ratio'
    Pass   = Test-Result -Log $log -Pattern 'status=PASS.*vectors=9 compared=9 errors=0 .*stim_rows=3'
    Detail = 'uncoupled stim/expect lengths must work (N:M modules)'
}

Write-Host '[5/10] Positive path: stimulus cadence (1 valid stim beat per 4 clocks)'
$log = Invoke-VectorSim -Tag 'pos_ratio_cadence' -Defines @('SELFTEST_CASE_RATIO', 'SELF_TEST_STIM_PERIOD')
$checks += [pscustomobject]@{
    Name   = 'positive cadence'
    Pass   = Test-Result -Log $log -Pattern 'status=PASS.*vectors=9 compared=9 errors=0 .*stim_rows=3 stim_period=4'
    Detail = 'gapped stimulus must work (multi-rate modules: framer / DUC)'
}

Write-Host '[6/10] Positive path: RX shape (4:1 decimation + skip 5 warmup beats)'
$log = Invoke-VectorSim -Tag 'pos_rx' -Defines @('SELFTEST_CASE_RX')
$checks += [pscustomobject]@{
    Name   = 'positive rx skip'
    Pass   = Test-Result -Log $log -Pattern 'status=PASS.*vectors=3 compared=3 errors=0 .*skipped=5'
    Detail = 'RX shape: decimated output + uncomparable warmup must be skipped'
}

Write-Host '[7/10] Negative path: one injected bit error'
$log = Invoke-VectorSim -Tag 'neg_rand' -Defines @('SELF_TEST_NEGATIVE')
$checks += [pscustomobject]@{
    Name   = 'negative inject'
    Pass   = Test-Result -Log $log -Pattern 'status=FAIL.*errors=1 .*first_mismatch=1000'
    Detail = 'must FAIL and locate the injected beat 1000'
}

Write-Host '[8/10] Negative path: extra outputs beyond expect length'
$log = Invoke-VectorSim -Tag 'neg_extra' -Defines @('SELFTEST_CASE_RATIO', 'SELF_TEST_EXTRA_OUT')
$checks += [pscustomobject]@{
    Name   = 'negative extra'
    Pass   = Test-Result -Log $log -Pattern 'status=FAIL.*compared=9 errors=3 .*extra=3'
    Detail = 'surplus valid beats must count as errors, not be ignored'
}

Write-Host '[9/10] Negative path: RX shape without skipping the warmup'
$log = Invoke-VectorSim -Tag 'neg_rx_noskip' -Defines @('SELFTEST_CASE_RX', 'SELF_TEST_SKIP_OFF')
$checks += [pscustomobject]@{
    Name   = 'negative rx noskip'
    Pass   = Test-Result -Log $log -Pattern 'status=FAIL.*first_mismatch=1 .*skipped=0'
    Detail = 'warmup beats must FAIL when not skipped (falsifies SKIP_OUT)'
}

Write-Host '[10/10] Stalled DUT: dout_valid tied low'
$log = Invoke-VectorSim -Tag 'stall_edge' -Defines @('SELF_TEST_STALL', 'SELFTEST_CASE_EDGE')
$checks += [pscustomobject]@{
    Name   = 'stall watchdog'
    Pass   = Test-Result -Log $log -Pattern 'status=FAIL.*compared=0 .*timeout=1'
    Detail = 'watchdog must close out instead of hanging silently'
}

Write-Host ''
Write-Host '==================== S2 framework selftest ===================='
foreach ($check in $checks) {
    $mark = if ($check.Pass) { 'PASS' } else { 'FAIL' }
    Write-Host ("  [{0}] {1,-16} {2}" -f $mark, $check.Name, $check.Detail)
}
Write-Host '==============================================================='
Write-Host ("  logs: {0}" -f $LogDir)

$failed = @($checks | Where-Object { -not $_.Pass })
if ($failed.Count -eq 0) {
    Write-Host '  [FRAMEWORK SELFTEST] PASS'
    exit 0
}
Write-Host ("  [FRAMEWORK SELFTEST] FAIL ({0} check(s) failed)" -f $failed.Count)
exit 1
