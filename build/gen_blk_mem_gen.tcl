# =====================================================================
# gen_blk_mem_gen.tcl — 生成 blk_inter 用的 blk_mem_gen（BRAM 存储）
#
# 用法（Vivado 2021.2）:
#     vivado -mode batch -nojournal -nolog -tempDir build/vivado_tmp/gen_blk_mem_gen -source build/gen_blk_mem_gen.tcl
# （-tempDir 见 build/p4_compare.tcl 头注释：不给它 Vivado 会在启动目录即仓库根目录建 .Xil/）
#
# 产物: build/ip/blk_mem_gen/blk_mem_gen_1w1r/
#     ├── blk_mem_gen_1w1r.xci            IP 配置（参数唯一来源，可重建）
#     ├── blk_mem_gen_1w1r.v              例化模板
#     ├── sim/blk_mem_gen_1w1r.v          仿真模型（xsim 编译这一份 + 下面那份）
#     └── simulation/blk_mem_gen_v8_4.v   仿真模型依赖的原语行为模型
# 产物**不入库**（根 .gitignore 的 /build/ip/ 规则）：本脚本即全部信息，重建约 40 s。
#
# 为什么是"简单双口"（1 写 1 读）而不是真双口：blk_inter 双缓冲稳态下每拍要
# 1 写 + 2 读 = 3 次访问，单块 BRAM 只有 2 个端口，所以用**两个 1 写 1 读副本**
# （写广播、读分流）——每个副本正好是简单双口 RAM 的能力上限。见
# src/blk_mem_1w1r.v 头注释与 docs/spec/s4_tx_interface.md §4.3。
#
# 参数与 RTL 推断版必须逐项对齐（否则两版位真结果不一致）:
#   · 位宽 2 bit、深度 8192（实际用到 4339）
#   · 端口 B 输出寄存器**关闭** → 读延迟 1 拍，与 RTL 版 `rdata <= mem[raddr]` 一致。
#     7 系列 BRAM 的输出寄存器会再叠一拍（开了就是 2 拍），本机两种配置都实测过：
#     开 = 2 拍、关 = 1 拍，正是"IP 版与 RTL 版输出整体错一位"的根因。
#   · 写模式 READ_FIRST：本设计读写永不撞同址（双缓冲分 bank），选它只为行为确定。
# =====================================================================

set script_dir [file dirname [file normalize [info script]]]
set out_dir    [file join $script_dir "ip" "blk_mem_gen"]

if {[file exists $out_dir]} {
    file delete -force $out_dir
}
file mkdir $out_dir

create_project -in_memory -part xc7z020clg400-2

create_ip -name blk_mem_gen -vendor xilinx.com -library ip -version 8.4 \
          -module_name blk_mem_gen_1w1r -dir $out_dir

set_property -dict [list \
    CONFIG.Memory_Type                                  {Simple_Dual_Port_RAM} \
    CONFIG.Write_Width_A                                {2} \
    CONFIG.Write_Depth_A                                {8192} \
    CONFIG.Read_Width_B                                 {2} \
    CONFIG.Operating_Mode_A                             {READ_FIRST} \
    CONFIG.Register_PortB_Output_of_Memory_Primitives   {false} \
    CONFIG.Enable_A                                     {Always_Enabled} \
    CONFIG.Enable_B                                     {Always_Enabled} \
    CONFIG.Enable_32bit_Address                         {false} \
    CONFIG.Load_Init_File                               {false} \
] [get_ips blk_mem_gen_1w1r]

generate_target {instantiation_template simulation synthesis} [get_ips blk_mem_gen_1w1r]

set sim_model [file join $out_dir "blk_mem_gen_1w1r" "sim" "blk_mem_gen_1w1r.v"]
set sim_prim  [file join $out_dir "blk_mem_gen_1w1r" "simulation" "blk_mem_gen_v8_4.v"]
foreach f [list $sim_model $sim_prim] {
    if {![file exists $f]} {
        puts "\[BLK-MEM-GEN\] FAIL: missing simulation source $f"
        exit 1
    }
}

# 判据行纯 ASCII：Vivado 控制台对中文的编码不可靠（实测 puts 中文会变乱码）
puts "\[BLK-MEM-GEN\] OK: generated blk_mem_gen_1w1r (2-bit x 8192, SDP, 1-cycle read)"
exit 0
