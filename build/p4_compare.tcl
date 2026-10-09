# =====================================================================
# p4_compare.tcl — S4-P4 资源 / Fmax 对比
#   对比对象：srrc_duc（手写多相 SRRC）vs srrc_duc_fir（FIR Compiler IP 版）
#
# 运行（在仓库根目录执行，Vivado 2021.2 batch，OOC 模式，固定 Explore 指令）：
#   vivado -mode batch -nojournal -nolog -tempDir build/vivado_tmp/p4 -source build/p4_compare.tcl -tclargs hand > build/p4_compare/hand.log 2>&1
#   vivado -mode batch -nojournal -nolog -tempDir build/vivado_tmp/p4 -source build/p4_compare.tcl -tclargs fir  > build/p4_compare/fir.log  2>&1
#
# -tempDir 把 Vivado 的 session scratch 从启动目录挪到 build/ 下：不给这个参数它会往启动目录
# （= 仓库根目录）建 .Xil/——正常退出留个空目录，被中断就留下整棵 Vivado-<pid> 树。
# 取值须与下面 $scratch_base 一致：ensure_rt_run_dirs 靠它找到 Vivado 生成的 run tcl。
#
# 前置依赖：FIR 版必须先运行 build/gen_fir_compiler.tcl 生成 fir_srrc IP。
# 产物：build/p4_compare/<top>/<top>_util.rpt   分层资源报告
#        build/p4_compare/<top>/<top>_timing.rpt 时序报告（WNS / Fmax）
#        控制台末尾 [P4-RESULT] 摘要行（可直接回贴）
# =====================================================================

set root     [file normalize [file join [file dirname [file normalize [info script]]] ".."]]
set part     xc7z020clg400-2
set T        16.276
set outroot  [file join $root "build" "p4_compare"]
# 与启动参数 -tempDir 一致的 scratch 根（见文件头）：改了启动参数，这里要跟着改
set scratch_base [file join $root "build" "vivado_tmp" "p4"]
set lut_file [file join $root "src" "nco_lut.mem"]
set fir_xci  [file join $root "build" "ip" "fir_compiler" "fir_srrc" "fir_srrc.xci"]

if {![file exists $lut_file]} { puts "\[P4\] FAIL: 找不到 $lut_file"; exit 1 }

# 本机 Vivado 2021.2 会漏建综合 scratch 目录 <scratch>/Vivado-<pid>-<host>/realtime，而它自己
# 生成的 run tcl 就放在那里并被 source，于是报 "couldn't read file ... No error" 直接综合失败。
# 该目录在流程中途还会被重建清掉，所以每个综合类命令前都补建一次（幂等）。
#
# scratch 根按启动方式二选一（见文件头）：
#   · 传了 -tempDir → Vivado 建在 <tempDir>/.Xil_SYSTEM/Vivado-<pid>-<host>（create_project 后即可见）
#   · 没传          → <cwd>/.Xil/Vivado-<pid>-<host>
# 只补已存在的那一支。特别地：-tempDir 生效时**不能**再去 mkdir 启动目录的 .Xil——那正是
# 本脚本要避免的（跑一次就在启动目录留一个 .Xil/，而启动目录就是仓库根）。
proc ensure_rt_run_dirs {} {
    global scratch_base
    set dirs {}
    if {[file isdirectory $scratch_base]} {
        foreach d [glob -nocomplain [file join $scratch_base "Vivado-*"] [file join $scratch_base "*" "Vivado-*"]] {
            lappend dirs $d
        }
    } else {
        set legacy [file join [pwd] ".Xil"]
        lappend dirs [file join $legacy "Vivado-[pid]-[string toupper [info hostname]]"]
        foreach d [glob -nocomplain [file join $legacy "Vivado-*"]] { lappend dirs $d }
    }
    foreach d $dirs { file mkdir [file join $d "realtime"] }
}

proc run_one {top is_fir} {
    global root part T outroot lut_file fir_xci
    set out [file join $outroot $top]
    file mkdir $out

    # 非工程模式默认器件是 xc7vx485t，与 IP 定制器件不符会导致 IP 被锁、synthesis target stale。
    # 建一个 in-memory 工程把器件上下文对齐（gen_fir_compiler.tcl 生成 IP 时用的也是同一器件）。
    create_project -in_memory -part $part
    ensure_rt_run_dirs

    # 切到 src 目录，保证 `include "srrc_coeff.vh" 能被预处理器找到
    set cwd [pwd]
    cd [file join $root "src"]
    read_verilog -sv [file join $root "src" "${top}.v"]
    cd $cwd

    if {$is_fir} {
        if {![file exists $fir_xci]} {
            puts "\[P4\] FAIL: 找不到 $fir_xci，请先运行 build/gen_fir_compiler.tcl"
            exit 1
        }
        read_ip $fir_xci
        # read_ip 只是登记 IP，必须先 OOC 综合出网表，synth_design 才链接得到 fir_srrc 模块
        ensure_rt_run_dirs
        synth_ip [get_ips fir_srrc]
    }

    # out_of_context：端口不插 IOB，聚焦内部寄存器→寄存器路径（即模块级 Fmax）
    # 时钟必须在综合前就位（否则综合阶段无时序约束 = 非时序驱动，两个变体的综合待遇就不对等）；
    # 但 create_clock 直接写在 synth_design 之前会因 get_ports 没有展开设计而报 "No open design"，
    # 故写成 XDC 由 read_xdc 交给 synth_design 应用。
    set xdc [file join $out "${top}_ooc.xdc"]
    set fh [open $xdc w]
    puts $fh "create_clock -period $T -name clk \[get_ports clk\]"
    close $fh
    read_xdc $xdc

    ensure_rt_run_dirs
    synth_design -top $top -part $part -mode out_of_context -generic "LUT_FILE=$lut_file"

    opt_design   -directive Explore
    place_design -directive Explore
    route_design -directive Explore

    report_utilization    -hierarchical -file [file join $out "${top}_util.rpt"]
    report_timing_summary -delay_type max -max_paths 10 -file [file join $out "${top}_timing.rpt"]
    write_checkpoint -force [file join $out "${top}.dcp"]

    # ---- 控制台摘要（可直接回贴给我） ----
    set wns 0.0
    set tp [get_timing_paths -delay_type max -max_paths 1]
    if {[llength $tp] > 0} { set wns [get_property SLACK [lindex $tp 0]] }
    set fmax [expr {1000.0 / ($T - $wns)}]

    set dsp  [llength [get_cells -hier -quiet -filter {REF_NAME == DSP48E1}]]
    set lut  [llength [get_cells -hier -quiet -filter {REF_NAME =~ LUT*}]]
    set ff   [llength [get_cells -hier -quiet -filter {REF_NAME =~ FD*}]]
    set bram [llength [get_cells -hier -quiet -filter {REF_NAME =~ RAMB*}]]

    puts "\[P4-RESULT\] top=$top  WNS=${wns}ns  Fmax=${fmax}MHz  LUT=$lut  FF=$ff  DSP=$dsp  BRAM=$bram"
    puts "\[P4-RESULT\] reports: ${out}/${top}_util.rpt , ${out}/${top}_timing.rpt"
}

set which [lindex $argv 0]
switch -- $which {
    "hand"  { run_one srrc_duc     0 }
    "fir"   { run_one srrc_duc_fir 1 }
    default {
        puts "\[P4\] 用法: vivado -mode batch -nojournal -nolog -tempDir build/vivado_tmp/p4 -source build/p4_compare.tcl -tclargs {hand|fir}"
        exit 1
    }
}

puts "\[P4\] done"
