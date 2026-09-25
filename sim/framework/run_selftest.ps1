# =====================================================================
# run_selftest.ps1 — S2 比对框架 · 一键自测
#
# 四项检查，判据全部取日志里那一行纯 ASCII 的 [VEC-RESULT]：
#   1. 正路径 rand   → status=PASS，4096/4096，0 错误
#   2. 正路径 edge   → status=PASS，196/196，0 错误
#   3. 负路径 rand   → status=FAIL，errors=1，first_mismatch=1000（注入点）
#   4. 桩死 edge     → status=FAIL，timeout=1，compared=0（看门狗收口）
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

Write-Host '[1/5] Export golden vectors (golden_ref fixed-point model -> .hex)'
& python (Join-Path $PSScriptRoot 'export_vectors.py') | ForEach-Object { Write-Host "      $_" }
if ($LASTEXITCODE -ne 0) { throw 'export_vectors.py failed, vectors not generated' }

Write-Host '[2/5] Positive path: rand'
$log = Invoke-VectorSim -Tag 'pos_rand'
$checks += [pscustomobject]@{
    Name   = 'positive rand'
    Pass   = Test-Result -Log $log -Pattern 'status=PASS.*vectors=4096 compared=4096 errors=0'
    Detail = 'golden-consistent DUT must be judged PASS (4096 beats)'
}

Write-Host '[3/5] Positive path: edge'
$log = Invoke-VectorSim -Tag 'pos_edge' -Defines @('SELFTEST_CASE_EDGE')
$checks += [pscustomobject]@{
    Name   = 'positive edge'
    Pass   = Test-Result -Log $log -Pattern 'status=PASS.*vectors=196 compared=196 errors=0'
    Detail = 'edge-case vector must be judged PASS (196 beats)'
}

Write-Host '[4/5] Negative path: one injected bit error'
$log = Invoke-VectorSim -Tag 'neg_rand' -Defines @('SELF_TEST_NEGATIVE')
$checks += [pscustomobject]@{
    Name   = 'negative inject'
    Pass   = Test-Result -Log $log -Pattern 'status=FAIL.*errors=1 .*first_mismatch=1000'
    Detail = 'must FAIL and locate the injected beat 1000'
}

Write-Host '[5/5] Stalled DUT: dout_valid tied low'
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
