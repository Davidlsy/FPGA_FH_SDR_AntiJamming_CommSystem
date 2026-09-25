# =====================================================================
# run_jammer_check.ps1 — S2 干扰注入源 · 一键编译 + 跑场景 + 核验
#
# 步骤：xvlog → xelab → xsim（导出 dump/） → python check_jammer_stats.py
# 判据取检查器的退出码与 [JAMMER STATS] 行（xsim 批处理即使 $fatal 也返回 0）。
#
# 注意：本源复用 sim/models/channel/ch_pkg.sv（定点量化与高斯原语），编译时一并带上。
#
# 用法：.\run_jammer_check.ps1
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
New-Item -ItemType Directory -Force -Path (Join-Path $PSScriptRoot 'dump') | Out-Null

foreach ($dir in 'work', 'xsim.dir') {
    $path = Join-Path $PSScriptRoot $dir
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
}

$svFiles = @(
    (Join-Path $PSScriptRoot '..\channel\ch_pkg.sv'),
    (Join-Path $PSScriptRoot 'jm_dds.sv'),
    (Join-Path $PSScriptRoot 'jm_sweep.sv'),
    (Join-Path $PSScriptRoot 'jm_partial.sv'),
    (Join-Path $PSScriptRoot 'jm_top.sv'),
    (Join-Path $PSScriptRoot 'tb_jammer_stats.sv')
)

Write-Host '[1/4] xvlog'
& xvlog -sv -work work @svFiles *> (Join-Path $LogDir 'jammer.xvlog.log')
if ($LASTEXITCODE -ne 0) { throw "xvlog failed, see $LogDir\jammer.xvlog.log" }

Write-Host '[2/4] xelab'
& xelab -relax -timescale 1ns/1ps -snapshot sn_jammer -debug typical work.tb_jammer_stats *> (Join-Path $LogDir 'jammer.xelab.log')
if ($LASTEXITCODE -ne 0) { throw "xelab failed, see $LogDir\jammer.xelab.log" }

Write-Host '[3/4] xsim（七个场景，导出 dump/）'
& xsim sn_jammer -runall *> (Join-Path $LogDir 'jammer.xsim.log')
if ((Get-Content -LiteralPath (Join-Path $LogDir 'jammer.xsim.log') -Raw) -match 'FATAL_ERROR') {
    throw "xsim reported a fatal error, see $LogDir\jammer.xsim.log"
}

Write-Host '[4/4] python check_jammer_stats.py'
$checkLog = Join-Path $LogDir 'jammer.check.log'
& python (Join-Path $PSScriptRoot 'check_jammer_stats.py') *> $checkLog
$checkExit = $LASTEXITCODE
Get-Content -LiteralPath $checkLog | Write-Host

$verdict = (Get-Content -LiteralPath $checkLog -Raw) -match '\[JAMMER STATS\] PASS'
if ($checkExit -eq 0 -and $verdict) {
    Write-Host ''
    Write-Host '  [JAMMER CHECK] PASS'
    exit 0
}
Write-Host ''
Write-Host '  [JAMMER CHECK] FAIL'
exit 1
