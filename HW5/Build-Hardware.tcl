# 由 vivado/HW5/HW5.xpr 跑合成、實作、產生 bitstream，並匯出給 SDK 的硬體描述檔
# 用法（在儲存庫根目錄）：vivado -mode batch -source HW5/Build-Hardware.tcl
#   產生 vivado/HW5/HW5.runs/impl_1/HW_5.bit 與 vivado/HW5/HW_5.hdf（含 bitstream，HW5/sw/Build-Software.tcl 會用到）
set repo_root [file normalize [file join [file dirname [info script]] ..]]
set project_dir [file join $repo_root vivado HW5]
open_project [file join $project_dir HW5.xpr]
reset_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    error "impl_1 did not finish"
}
# 有 PS 的設計，write_bitstream 會一併產生 HW_5.sysdef（就是 SDK 用的 .hdf，內含 bitstream）
set impl_dir [get_property DIRECTORY [get_runs impl_1]]
file copy -force [file join $impl_dir HW_5.sysdef] [file join $project_dir HW_5.hdf]
puts "Wrote [file join $project_dir HW_5.hdf]"
close_project
