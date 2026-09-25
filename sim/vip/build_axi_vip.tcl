# =====================================================================
# build_axi_vip.tcl — 生成 PS/PL 协同仿真环境所需的 AXI VIP
#
# 要点：AXI VIP **不需要 Block Design**，在普通 RTL 工程里 create_ip + 生成
# 仿真目标即可（本机 2021.2 实测）。生成物：
#     gen/axi_vip_mst_1/sim/axi_vip_mst_pkg.sv   per-instance 包（agent 类型）
#     gen/axi_vip_mst_1/sim/axi_vip_mst.sv       per-instance wrapper（可直接例化）
#     gen/axi_vip_mst_1/hdl/axi_vip_v1_1_vl_rfs.sv   实现（亦可由预编译库提供）
#
# 用法：vivado -mode batch -nojournal -nolog -source build_axi_vip.tcl
# 产物不入版本控制，由 run_vip_check.ps1 一键重建。
# =====================================================================

set gen_dir [file normalize [file join [pwd] gen]]
file mkdir $gen_dir

create_project -in_memory -part xc7z020clg400-2
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

# AXI4-Lite 主端：地址 32 位、数据 32 位、无 ID、无 ACLKEN
create_ip -vlnv xilinx.com:ip:axi_vip:1.1 -module_name axi_vip_mst -dir $gen_dir
set_property -dict [list \
    CONFIG.PROTOCOL         {AXI4LITE} \
    CONFIG.INTERFACE_MODE   {MASTER} \
    CONFIG.READ_WRITE_MODE  {READ_WRITE} \
    CONFIG.ADDR_WIDTH       {32} \
    CONFIG.DATA_WIDTH       {32} \
    CONFIG.ID_WIDTH         {0} \
    CONFIG.HAS_ACLKEN       {0} \
    CONFIG.HAS_ARESETN      {1} \
    CONFIG.HAS_BRESP        {1} \
    CONFIG.HAS_RRESP        {1} \
] [get_ips axi_vip_mst]

generate_target {instantiation_template simulation} [get_ips axi_vip_mst]

puts "===AXI VIP generated files==="
foreach f [get_files -of [get_ips axi_vip_mst]] {
    puts "  $f"
}
puts "===DONE==="
