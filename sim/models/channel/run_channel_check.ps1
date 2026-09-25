# =====================================================================
# run_channel_check.ps1 — S2 信道模型库 · 一键编译 + 跑场景 + 核验
#
# 步骤：xvlog → xelab → xsim（导出 dump/） → python check_channel_stats.py
# 判据取检查器的退出码与 [CHANNEL STATS] 行（xsim 批处理即使 $fatal 也返回 0，
# 不能靠它的退出码判成败）。
#
# 用法：.\run_channel_check.ps1
# 前置：xvlog/xelab/xsim 在 PATH，python 带 numpy 与 sim/golden_ref 依赖。
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

$svFiles = @('ch_pkg.sv', 'ch_awgn.sv', 'ch_cfo.sv', 'ch_sfo.sv',
             'ch_multipath.sv', 'ch_top.sv', 'tb_channel_stats.sv')

Write-Host '[1/4] xvlog'
& xvlog -sv -work work @svFiles *> (Join-Path $LogDir 'channel.xvlog.log')
if ($LASTEXITCODE -ne 0) { throw "xvlog failed, see $LogDir\channel.xvlog.log" }

Write-Host '[2/4] xelab'
& xelab -relax -timescale 1ns/1ps -snapshot sn_channel -debug typical work.tb_channel_stats *> (Join-Path $LogDir 'channel.xelab.log')
if ($LASTEXITCODE -ne 0) { throw "xelab failed, see $LogDir\channel.xelab.log" }

Write-Host '[3/4] xsim（七个场景，导出 dump/）'
& xsim sn_channel -runall *> (Join-Path $LogDir 'channel.xsim.log')
if ((Get-Content -LiteralPath (Join-Path $LogDir 'channel.xsim.log') -Raw) -match 'FATAL_ERROR') {
    throw "xsim reported a fatal error, see $LogDir\channel.xsim.log"
}

Write-Host '[4/4] python check_channel_stats.py'
$checkLog = Join-Path $LogDir 'channel.check.log'
& python (Join-Path $PSScriptRoot 'check_channel_stats.py') *> $checkLog
$checkExit = $LASTEXITCODE
Get-Content -LiteralPath $checkLog | Write-Host

$verdict = (Get-Content -LiteralPath $checkLog -Raw) -match '\[CHANNEL STATS\] PASS'
if ($checkExit -eq 0 -and $verdict) {
    Write-Host ''
    Write-Host '  [CHANNEL CHECK] PASS'
    exit 0
}
Write-Host ''
Write-Host '  [CHANNEL CHECK] FAIL'
exit 1
