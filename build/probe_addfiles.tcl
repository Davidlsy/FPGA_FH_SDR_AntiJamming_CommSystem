set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir ..]]
set proj_dir   [file join $script_dir vivado_probe]
create_project probe $proj_dir -part xc7z020clg400-2 -force
add_files -norecurse [file join $repo_root src fhss_top.v]
puts "=== files in sources_1: [get_files -of_objects [get_filesets sources_1]] ==="
if {[catch {update_compile_order -fileset sources_1} err]} { puts "update_compile_order err: $err" }
puts "=== top: [get_property top [current_fileset]] ==="
exit 0
