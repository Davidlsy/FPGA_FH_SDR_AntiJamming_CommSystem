# Non-project smoke validation of board/fhss_zynq_pins.xdc
# (project mode filemgmt is blocked by the sandbox; this flow avoids it)
set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir ..]]

read_verilog [file join $repo_root src fhss_top.v]
synth_design -top fhss_top -part xc7z020clg400-2

puts "=== reading timing xdc ==="
read_xdc [file join $repo_root src constraints fhss_zynq_timing.xdc]
puts "=== reading pins xdc ==="
read_xdc [file join $repo_root board fhss_zynq_pins.xdc]

opt_design
place_design
route_design

report_timing_summary -file [file join $script_dir probe_timing.rpt]
report_drc           -file [file join $script_dir probe_drc.rpt]
write_bitstream -force [file join $script_dir probe_smoke.bit]
puts "=== PROBE RESULT: bitstream written OK ==="
exit 0
