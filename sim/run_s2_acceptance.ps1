# =====================================================================
# run_s2_acceptance.ps1 — S2 验证基础设施 · 统一验收（五件套串跑）
#
# 计划书 §S2 的出口门槛是「四件套全部通过自测并写 README」。五项自测各有
# 自己的入口脚本，本脚本把它们串成一次运行，产出唯一一行判据与一份总日志，
# 让「四件套同时成立」这件事有可复现的证据，而不是靠五张截图。
#
# 五项（顺序 = 依赖顺序，argv 完全相同地复用各模块自己的入口）：
#   1 framework  自动比对框架        sim/framework/run_selftest.ps1          4 组
#   2 ad9363     AD9363 SPI 行为模型 sim/models/ad9363/run_xsim.bat
#   3 channel    信道模型库          sim/models/channel/run_channel_check.ps1
#   4 jammer     干扰注入源          sim/models/jammer/run_jammer_check.ps1
#   5 vip        PS/PL 协同仿真环境  sim/vip/run_vip_check.ps1
#
# 判据口径（与各子脚本一致，不另立一套）：
#   · 子脚本退出码必须为 0 —— 但这只是必要条件：xsim 批处理模式即使 $fatal
#     也返回 0，所以真正的判据是「它自己那一行判据行」；
#   · 判据行分别是 [FRAMEWORK SELFTEST] / ALL TESTS PASSED / [CHANNEL STATS] /
#     [JAMMER STATS] / [VIP-RESULT]，全部为纯 ASCII，不 match 中文（重定向后
#     中文编码不可靠）；
#   · 汇总判据行以 [S2 ACCEPTANCE] 开头，同为纯 ASCII，供 CI / 脚本 match。
#
# 设计约束：本脚本只做「调度 + 判据聚合」，不重复实现任何编译/仿真步骤——
# 每个模块保留自己的入口，验收跑的就是日常跑的那一条路径。任一项失败不影响
# 其余项继续跑完，一次运行给出完整画面。
#
# 用法：.\run_s2_acceptance.ps1
# 前置：xvlog/xelab/xsim/vivado 在 PATH，python 带 numpy（golden_ref 依赖）。
# =====================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot

$LogDir = Join-Path $PSScriptRoot 'logs'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$AggLog = Join-Path $LogDir 's2_acceptance.log'

foreach ($tool in @('xvlog', 'xelab', 'xsim', 'vivado', 'python')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "$tool not found in PATH. Run: call D:\software\vivado2021\Vivado\2021.2\settings64.bat"
    }
}

$Suites = @(
    [pscustomobject]@{
        Name    = 'framework'
        Title   = '自动比对框架'
        Entry   = 'framework\run_selftest.ps1'
        Kind    = 'ps1'
        Verdict = '\[FRAMEWORK SELFTEST\] PASS'
        OneLine = '4 组：正路径 rand / edge、负路径注入、桩死看门狗'
    },
    [pscustomobject]@{
        Name    = 'ad9363'
        Title   = 'AD9363 SPI 行为模型'
        Entry   = 'models\ad9363\run_xsim.bat'
        Kind    = 'bat'
        Verdict = 'ALL TESTS PASSED'
        OneLine = '6 项：默认值全扫描、突发读写、超时、错误回读、复位、随机压力'
    },
    [pscustomobject]@{
        Name    = 'channel'
        Title   = '信道模型库'
        Entry   = 'models\channel\run_channel_check.ps1'
        Kind    = 'ps1'
        Verdict = '\[CHANNEL STATS\] PASS'
        OneLine = 'AWGN / CFO / SFO / 多径，七场景统计核验'
    },
    [pscustomobject]@{
        Name    = 'jammer'
        Title   = '干扰注入源'
        Entry   = 'models\jammer\run_jammer_check.ps1'
        Kind    = 'ps1'
        Verdict = '\[JAMMER STATS\] PASS'
        OneLine = '单音 / 多音 / 扫频 / 部分频带 + JSR 标定'
    },
    [pscustomobject]@{
        Name    = 'vip'
        Title   = 'PS/PL 协同仿真环境'
        Entry   = 'vip\run_vip_check.ps1'
        Kind    = 'ps1'
        Verdict = '\[VIP-RESULT\].*status=PASS'
        OneLine = '7 组：上电初始化 / 复位值 / 读写 / RO 保护 / DECERR / 控制序列 / 回显'
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

    # 子进程 stderr 归并进输出流：EAP=Stop 会把 native command 的 stderr 当
    # 终止错误抛出，故调用期间临时降级为 Continue，由退出码与判据行收口。
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($Suite.Kind -eq 'bat') {
            Push-Location (Split-Path -Parent $path)
            try {
                $text = (& cmd.exe /c (Split-Path -Leaf $path) 2>&1 | Out-String)
            } finally { Pop-Location }
        } else {
            $text = (& powershell -NoProfile -ExecutionPolicy Bypass -File $path 2>&1 | Out-String)
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

function Get-Count {
    param([string] $Text, [string] $Pattern)
    $m = [regex]::Matches($Text, $Pattern)
    if ($m.Count -eq 0) { return -1 }
    return [int]$m[$m.Count - 1].Groups[1].Value
}

# 取数只碰 ASCII 段：# 后缀的中文在重定向后可能已是乱码，不能作为判据。
function Get-SuiteDigest {
    param([pscustomobject] $Suite, [string] $Text)

    switch ($Suite.Name) {
        'framework' {
            $ok = [regex]::Matches($Text, '\[PASS\]\s').Count
            $bad = [regex]::Matches($Text, '\[FAIL\]\s').Count
            return [pscustomobject]@{ Checks = ($ok + $bad); Errors = $bad; Note = "$ok/$($ok + $bad) 组" }
        }
        'ad9363' {
            # 行首锚定：model_report 还会打印 "timeout errors : N"，不加 ^ 会取错行
            $c = Get-Count -Text $Text -Pattern '(?m)^\s*checks\s*:\s*(\d+)'
            $e = Get-Count -Text $Text -Pattern '(?m)^\s*errors\s*:\s*(\d+)'
            return [pscustomobject]@{ Checks = $c; Errors = $e; Note = "checks=$c errors=$e" }
        }
        'channel' {
            $c = Get-Count -Text $Text -Pattern '\[CHANNEL STATS\] PASS \((\d+)'
            return [pscustomobject]@{ Checks = $c; Errors = 0; Note = "$c 项" }
        }
        'jammer' {
            $c = Get-Count -Text $Text -Pattern '\[JAMMER STATS\] PASS \((\d+)'
            return [pscustomobject]@{ Checks = $c; Errors = 0; Note = "$c 项" }
        }
        'vip' {
            $c = Get-Count -Text $Text -Pattern '\[VIP-RESULT\][^\r\n]*checks=(\d+) errors=(\d+)'
            $e = -1
            $m = [regex]::Matches($Text, '\[VIP-RESULT\][^\r\n]*checks=\d+ errors=(\d+)')
            if ($m.Count -gt 0) { $e = [int]$m[$m.Count - 1].Groups[1].Value }
            return [pscustomobject]@{ Checks = $c; Errors = $e; Note = "checks=$c errors=$e" }
        }
        default {
            return [pscustomobject]@{ Checks = -1; Errors = -1; Note = 'n/a' }
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

    $digest = [pscustomobject]@{ Checks = -1; Errors = -1; Note = 'n/a' }
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
        Checks  = $(if ($digest.Checks -ge 0) { $digest.Checks } else { 0 })
        Errors  = $(if ($digest.Errors -ge 0) { $digest.Errors } else { 0 })
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
[void]$buffer.AppendLine("S2 acceptance run @ $stamp")
[void]$buffer.AppendLine("host: $env:COMPUTERNAME   pwd: $PSScriptRoot")
[void]$buffer.AppendLine('')
[void]$buffer.AppendLine("suite                     entry                              verdict              checks  errors   secs")
foreach ($r in $records) {
    [void]$buffer.AppendLine(("{0,-26}{1,-35}{2,-21}{3,-8}{4,-9}{5}" -f `
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
Write-Host '====================== S2 acceptance ======================'
foreach ($r in $records) {
    $mark = if ($r.Pass) { 'PASS' } else { 'FAIL' }
    Write-Host ("  [{0}] {1,-22} {2,-22} {3,6} s  {4}" -f $mark, $r.Title, $r.Note, $r.Seconds, $r.Reason)
}
Write-Host '=========================================================='
Write-Host ("  suites  : {0}/{1}" -f ($records.Count - $failed.Count), $records.Count)
Write-Host ("  checks  : {0}   errors : {1}" -f $totalChecks, $totalErrors)
Write-Host ("  elapsed : {0} s" -f $totalSeconds)
Write-Host ("  log     : {0}" -f $AggLog)

$status = if ($failed.Count -eq 0) { 'PASS' } else { 'FAIL' }
Write-Host ("[S2 ACCEPTANCE] suites={0} failed={1} checks={2} errors={3} status={4}" -f `
    $records.Count, $failed.Count, $totalChecks, $totalErrors, $status)

if ($failed.Count -eq 0) { exit 0 }
exit 1
