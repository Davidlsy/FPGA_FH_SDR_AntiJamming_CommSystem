# =============================================================================
# create_smoke_project.tcl
# One-shot smoke project rebuild: create -> synth -> impl -> bitstream
# Optional: behavioral sim for [SMOKE] PASS
# Tool   : Vivado ML 2021.2
# Part   : xc7z020clg400-2 (AX7Z020B)
# Usage  :
#   cd FPGA_FH_SDR_AntiJamming_CommSystem
#   vivado -mode batch -source build/create_smoke_project.tcl
#   Optional sim only after project exists:
#     vivado -mode batch -source build/create_smoke_project.tcl -tclargs sim
# =============================================================================

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir ..]]
set proj_dir   [file join $script_dir vivado_smoke]
set proj_name  fhss_smoke
set part       xc7z020clg400-2
set top        fhss_top

# mode: build (default) | sim
set mode build
if {[llength $argv] > 0} {
    set mode [lindex $argv 0]
}

# ---- Close any open project, then wipe previous smoke dir ----
# Avoids Coretcl 2-101 "Project is already open" on re-run
if {[catch {current_project} cur_proj] == 0 && $cur_proj ne ""} {
    puts "INFO: closing currently open project: $cur_proj"
    close_project
}
set xpr_path [file join $proj_dir ${proj_name}.xpr]
if {[file exists $proj_dir]} {
    puts "INFO: removing previous smoke project dir: $proj_dir"
    file delete -force $proj_dir
}
file mkdir $proj_dir

# ---- Create project ----
create_project $proj_name $proj_dir -part $part -force
set_property target_language Verilog [current_project]
set_property default_lib work [current_project]

# ---- Sources ----
add_files -norecurse [file join $repo_root src fhss_top.v]
set_property top $top [current_fileset]
update_compile_order -fileset sources_1

# ---- Constraints: timing + pins (single source of truth) ----
add_files -fileset constrs_1 -norecurse [file join $repo_root src constraints fhss_zynq_timing.xdc]
add_files -fileset constrs_1 -norecurse [file join $repo_root board fhss_zynq_pins.xdc]

# ---- Simulation sources ----
add_files -fileset sim_1 -norecurse [file join $repo_root sim tb_fhss_top.v]
set_property top tb_fhss_top [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {1000ns} -objects [get_filesets sim_1]

# Project already created/saved at $proj_dir by create_project; no save_project(_as) here
# (save_project is not a valid standalone cmd in Vivado 2021.2; save_project_as to same
#  open path triggers Coretcl 2-101)

if {$mode eq "sim"} {
    puts "INFO: launching behavioral simulation ..."
    launch_simulation
    # In batch mode, xsim log is under proj .sim / sim_1
    puts "INFO: simulation launched. Check console for \[SMOKE\] PASS/FAIL."
    exit 0
}

# ---- Synthesis ----
puts "INFO: launching synthesis ..."
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    error "ERROR: synthesis failed"
}

# ---- Implementation through bitstream ----
puts "INFO: launching implementation + bitstream ..."
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    error "ERROR: implementation/bitstream failed"
}

# ---- Reports ----
set impl_dir [file join $proj_dir ${proj_name}.runs impl_1]
open_run impl_1
report_timing_summary -file [file join $impl_dir smoke_timing_summary.rpt]
report_utilization    -file [file join $impl_dir smoke_utilization.rpt]
report_drc            -file [file join $impl_dir smoke_drc.rpt]

set bit [file join $impl_dir ${top}.bit]
if {[file exists $bit]} {
    puts "INFO: bitstream OK -> $bit"
} else {
    error "ERROR: bitstream not found at $bit"
}

puts "INFO: smoke build finished. Project: $proj_dir/${proj_name}.xpr"
exit 0