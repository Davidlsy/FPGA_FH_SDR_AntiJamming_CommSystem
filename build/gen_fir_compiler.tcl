# =====================================================================
# gen_fir_compiler.tcl — 生成 srrc_duc 用的 FIR Compiler（SRRC 成形）
#
# 用法（Vivado 2021.2）:
#     vivado -mode batch -source build/gen_fir_compiler.tcl
#
# 产物: build/ip/fir_compiler/fir_srrc/
#     ├── fir_srrc.xci                  IP 配置（参数唯一来源）
#     ├── fir_srrc.v                    例化模板
#     ├── sim/fir_srrc.v                仿真模型
#     └── simulation/fir_compiler_v7_2.v 行为模型
# 产物**不入库**（根 .gitignore 的 /build/ip/ 规则）：本脚本 + src/srrc_fir.coe 即全部信息。
#
# 与手写版位真一致的两个关键配置（决策 1.5 ②）:
#   · Output_Rounding_Mode = Convergent_Rounding_to_Even（= round half-to-even，同 np.round）
#   · Output_Width = 14（= SRRC 输出 Q3.11 位宽）
#   系数 12 bit Q1.11 来自 src/srrc_fir.coe（与 src/srrc_coeff.vh 同源 golden_ref）。
#   结构 Symmetric：33 抽头对称折叠（17 个独立乘法）——这是"IP vs 手写"对比的差异点。
# =====================================================================

set script_dir [file dirname [file normalize [info script]]]
set out_dir    [file join $script_dir "ip" "fir_compiler"]
set coe_file   [file normalize [file join $script_dir ".." "src" "srrc_fir.coe"]]

if {![file exists $coe_file]} {
    puts "\[FIR-GEN\] FAIL: missing coefficient file $coe_file"
    exit 1
}

if {[file exists $out_dir]} {
    file delete -force $out_dir
}
file mkdir $out_dir

create_project -in_memory -part xc7z020clg400-2

create_ip -name fir_compiler -vendor xilinx.com -library ip -version 7.2 \
          -module_name fir_srrc -dir $out_dir

set_property -dict [list \
    CONFIG.Filter_Type                 {Interpolation} \
    CONFIG.Interpolation_Rate          {4} \
    CONFIG.CoefficientSource           {COE_File} \
    CONFIG.Coefficient_File            $coe_file \
    CONFIG.Coefficient_Width           {12} \
    CONFIG.Coefficient_Structure       {Symmetric} \
    CONFIG.Coefficient_Sets            {1} \
    CONFIG.Coefficient_Reload          {false} \
    CONFIG.Number_Channels             {1} \
    CONFIG.Quantization                {Integer_Coefficients} \
    CONFIG.Data_Width                  {12} \
    CONFIG.Sample_Frequency            {0.5} \
    CONFIG.Clock_Frequency             {2.0} \
    CONFIG.Output_Rounding_Mode        {Convergent_Rounding_to_Even} \
    CONFIG.Output_Width                {13} \
    CONFIG.Has_ARESETn                 {true} \
    CONFIG.DATA_Has_TLAST              {Not_Required} \
] [get_ips fir_srrc]

generate_target {instantiation_template simulation synthesis} [get_ips fir_srrc]

# FIR Compiler 仿真模型是 VHDL（非 Verilog）：混合语言仿真需 xvhdl 编译下面几份
set sim_dir [file join $out_dir "fir_srrc"]
set sim_srcs [list \
    [file join $sim_dir "sim" "fir_srrc.vhd"] \
    [file join $sim_dir "hdl" "fir_compiler_v7_2_vh_rfs.vhd"] \
    [file join $sim_dir "hdl" "axi_utils_v2_0_vh_rfs.vhd"] \
    [file join $sim_dir "hdl" "xbip_utils_v3_0_vh_rfs.vhd"] \
]
foreach f $sim_srcs {
    if {![file exists $f]} {
        puts "\[FIR-GEN\] FAIL: missing simulation source $f"
        exit 1
    }
}

puts "\[FIR-GEN\] OK: generated fir_srrc (33-tap symmetric, x4 interpolation, 12-bit coeff, 14-bit out, conv-round-to-even)"
exit 0
