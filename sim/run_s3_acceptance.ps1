# =====================================================================
# run_s3_acceptance.ps1 — S3 射频配置模块 · 统一验收
#
# 计划书 §S3 的交付物是「两模块 RTL、仿真日志、异常注入覆盖报告」，出口门槛是
# 「仿真报告评审通过」。本脚本把 S3 的四项自测按依赖顺序串跑一遍，产出唯一一行
# 判据与一份总日志，让「S3 的结论成立」有可复现的证据。
#
# 四项（顺序 = 依赖顺序）：
#   1 gen       初始化表一致性       gen_init_table.py --check      表产物 vs CSV
#   2 spi-smoke spi_master 时序冒烟  models/ad9363/run_spi_master.bat        36 项
#   3 spi-rand  spi_master 随机+异常 models/ad9363/run_spi_master_rand.bat  1200 向量
#   4 cfg       cfg 全链路+异常注入  models/ad9363/run_ad9363_cfg.bat       101 项
#
# 判据口径（与 run_s2_acceptance.ps1 一致，不另立一套）：
#   · 子脚本退出码必须为 0 —— 但只是必要条件：xsim 批处理模式下即使 $fatal 也
#     返回 0，所以真正的判据是「它自己那一行判据行」；
#   · 判据行分别是 [GEN-INIT] OK / SPI-MASTER SMOKE PASS / SPI-MASTER RAND PASS /
#     AD9363-CFG PASS，全部为纯 ASCII，不 match 中文（重定向后中文编码不可靠）；
#   · 汇总判据行为 [S3 ACCEPTANCE]，同为纯 ASCII。
#
# 用法：.\run_s3_acceptance.ps1
# 前置：xvlog/xelab/xsim 在 PATH，python 在 PATH。
# =====================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot

$LogDir = Join-Path $PSScriptRoot 'logs'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$AggLog = Join-Path $LogDir 's3_acceptance.log'

foreach ($tool in @('xvlog', 'xelab', 'xsim', 'python')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "$tool not found in PATH. Run: call D:\software\vivado2021\Vivado\2021.2\settings64.bat"
    }
}

$Suites = @(
    [pscustomobject]@{
        Name    = 'gen'
        Title   = '初始化表一致性'
        Kind    = 'py'
        Entry   = 'models\ad9363\gen_init_table.py'
        Args    = @('--check')
        Verdict = '\[GEN-INIT\] OK'
        OneLine = 'CSV 单一来源 -> .mem + expect 两条独立编码路径的产物一致性'
    },
    [pscustomobject]@{
        Name    = 'spi-smoke'
        Title   = 'spi_master 时序冒烟'
        Kind    = 'bat'
        Entry   = 'models\ad9363\run_spi_master.bat'
        Verdict = 'SPI-MASTER SMOKE PASS'
        OneLine = '36 项：单/多字节读写、位序、看门狗超时与恢复'
    },
    [pscustomobject]@{
        Name    = 'spi-rand'
        Title   = 'spi_master 随机向量 + 异常注入'
        Kind    = 'bat'
        Entry   = 'models\ad9363\run_spi_master_rand.bat'
        Verdict = 'SPI-MASTER RAND PASS'
        OneLine = '1200 向量 / 4580 项：随机读写、CPOL/CPHA 包络、F1-F5 五类异常'
    },
    [pscustomobject]@{
        Name    = 'cfg'
        Title   = 'ad9363_cfg 全链路 + 异常注入'
        Kind    = 'bat'
        Entry   = 'models\ad9363\run_ad9363_cfg.bat'
        Verdict = 'AD9363-CFG PASS'
        OneLine = 'R1-R9：正常/回读失配/恢复/暂停恢复/逐条比对/无应答/表项损坏/中途复位/重复上电'
    }
)

function Invoke-Suite {
    param([pscustomobject] $Suite)

    $path = Join-Path $PSScriptRoot $Suite.Entry
    $result = [pscustomobject]@{ Exit = 127; Text = ''; Error = $null }
    if (-not (Test-Path -LiteralPath $path)) {
        $result.Error = "entry not found: $($Suite.Entry)"
        return $result
    }

    # 子进程 stderr 归并进输出流：EAP=Stop 会把 native command 的 stderr 当终止错误
    # 抛出，故调用期间临时降级为 Continue，由退出码与判据行收口。
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        Push-Location (Split-Path -Parent $path)
        try {
            if ($Suite.Kind -eq 'bat') {
                $text = (& cmd.exe /c (Split-Path -Leaf $path) 2>&1 | Out-String)
            } else {
                $fileName = Split-Path -Leaf $path
                $text = (& python $fileName @($Suite.Args) 2>&1 | Out-String)
            }
        } finally {
            Pop-Location
        }
        $result.Text = $text
        $result.Exit = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
    } catch {
        $result.Error = $_.Exception.Message
    } finally {
        $ErrorActionPreference = $saved
    }
    return $result
}

# 取数只碰 ASCII 段：# 后缀的中文在重定向后可能已是乱码，不能作为判据。
function Get-SuiteDigest {
    param([pscustomobject] $Suite, [string] $Text)

    switch ($Suite.Name) {
        'gen' {
            $m = [regex]::Matches($Text, '\[GEN-INIT\] OK:[^\r\n]*words=(\d+) txns=(\d+)')
            if ($m.Count -eq 0) { return [pscustomobject]@{ Checks = 0; Errors = 1; Note = 'no digest' } }
            $g = $m[$m.Count - 1]
            return [pscustomobject]@{ Checks = 1; Errors = 0; Note = "words=$($g.Groups[1].Value) txns=$($g.Groups[2].Value)" }
        }
        default {
            $m = [regex]::Matches($Text, 'checks=(\d+) failed=(\d+)')
            if ($m.Count -eq 0) { return [pscustomobject]@{ Checks = 0; Errors = 1; Note = 'no digest' } }
            $g = $m[$m.Count - 1]
            $c = [int]$g.Groups[1].Value
            $e = [int]$g.Groups[2].Value
            return [pscustomobject]@{ Checks = $c; Errors = $e; Note = "checks=$c failed=$e" }
        }
    }
}

$records = @()
$index = 0
$totalWatch = [Diagnostics.Stopwatch]::StartNew()
foreach ($suite in $Suites) {
    $index++
    Write-Host ("[{0}/{1}] {2}  ({3})" -f $index, $Suites.Count, $suite.Title, $suite.Entry)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $run = Invoke-Suite -Suite $suite
    $watch.Stop()
    $seconds = [math]::Round($watch.Elapsed.TotalSeconds, 1)

    $digest = [pscustomobject]@{ Checks = 0; Errors = 1; Note = 'n/a' }
    if ($null -eq $run.Error) { $digest = Get-SuiteDigest -Suite $suite -Text $run.Text }

    $verdictHit = ($null -eq $run.Error) -and ($run.Text -match $suite.Verdict)
    $pass = ($null -eq $run.Error) -and ($run.Exit -eq 0) -and $verdictHit -and ($digest.Errors -eq 0)

    $reason = 'ok'
    if ($null -ne $run.Error) { $reason = $run.Error }
    elseif (-not $verdictHit) { $reason = 'verdict line missing' }
    elseif ($digest.Errors -ne 0) { $reason = "errors=$($digest.Errors)" }
    elseif ($run.Exit -ne 0) { $reason = "exit=$($run.Exit)" }

    Write-Host ("      -> {0}  {1}  ({2} s)" -f $(if ($pass) { 'PASS' } else { 'FAIL' }), $digest.Note, $seconds)
    if (-not $pass) { Write-Host "      reason: $reason" }

    $records += [pscustomobject]@{
        Title   = $suite.Title
        Name    = $suite.Name
        Entry   = $suite.Entry
        Pass    = $pass
        Note    = $digest.Note
        Checks  = $digest.Checks
        Errors  = $digest.Errors
        Seconds = $seconds
        Reason  = $reason
        Run     = $run
    }
}
$totalWatch.Stop()
$totalSeconds = [math]::Round($totalWatch.Elapsed.TotalSeconds, 1)

# 总日志：各项完整 stdout 顺序拼接，作为一次验收的原始证据
$stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
$buffer = New-Object System.Text.StringBuilder
[void]$buffer.AppendLine("S3 acceptance run @ $stamp")
[void]$buffer.AppendLine("host: $env:COMPUTERNAME   pwd: $PSScriptRoot")
[void]$buffer.AppendLine('')
[void]$buffer.AppendLine("suite                     entry                                  verdict          checks  errors   secs")
foreach ($r in $records) {
    [void]$buffer.AppendLine(("{0,-26}{1,-39}{2,-17}{3,-8}{4,-9}{5}" -f `
        $r.Name, $r.Entry, $(if ($r.Pass) { 'PASS' } else { 'FAIL' }), $r.Checks, $r.Errors, $r.Seconds))
}
foreach ($r in $records) {
    [void]$buffer.AppendLine('')
    [void]$buffer.AppendLine(('=' * 72))
    [void]$buffer.AppendLine("suite: $($r.Name)  ($($r.Title))  entry: $($r.Entry)")
    [void]$buffer.AppendLine(('=' * 72))
    if ($null -ne $r.Run.Error) { [void]$buffer.AppendLine("ERROR: $($r.Run.Error)") }
    [void]$buffer.AppendLine($r.Run.Text)
}
[IO.File]::WriteAllText($AggLog, $buffer.ToString(), [Text.UTF8Encoding]::new($false))

$failed = @($records | Where-Object { -not $_.Pass })
$totalChecks = ($records | Measure-Object -Property Checks -Sum).Sum
$totalErrors = ($records | Measure-Object -Property Errors -Sum).Sum

Write-Host ''
Write-Host '====================== S3 acceptance ======================'
foreach ($r in $records) {
    $mark = if ($r.Pass) { 'PASS' } else { 'FAIL' }
    Write-Host ("  [{0}] {1,-32} {2,-22} {3,6} s  {4}" -f $mark, $r.Title, $r.Note, $r.Seconds, $r.Reason)
}
Write-Host '=========================================================='
Write-Host ("  suites  : {0}/{1}" -f ($records.Count - $failed.Count), $records.Count)
Write-Host ("  checks  : {0}   errors : {1}" -f $totalChecks, $totalErrors)
Write-Host ("  elapsed : {0} s" -f $totalSeconds)
Write-Host ("  log     : {0}" -f $AggLog)

$status = if ($failed.Count -eq 0) { 'PASS' } else { 'FAIL' }
Write-Host ("[S3 ACCEPTANCE] suites={0} failed={1} checks={2} errors={3} status={4}" -f `
    $records.Count, $failed.Count, $totalChecks, $totalErrors, $status)

if ($failed.Count -eq 0) { exit 0 }
exit 1
