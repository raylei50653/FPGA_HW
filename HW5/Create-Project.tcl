set homework HW5
# EGO-XZ7 板（腳位見 constraints/HW_5.xdc）
set part xc7z020clg484-1
# 測試檔以 VHDL-2008 external name 讀取內部訊號
set sim_vhdl2008 1
# 預設模擬 HW_5_tb（約 3 幀）；要跑 HW_5_game_tb 時在 Vivado 把 sim_1 的 top 改掉
set sim_runtime 80ms
source [file join [file dirname [info script]] .. scripts Create-VivadoProject.tcl]

# HW5 另外有 PS 的 block design（USB 鍵盤由 PS 讀取），共用腳本不處理 block design，在這裡補上
open_project $project_file
set_property board_part e-elements:ego-xz7:part0:1.1 [current_project]
source [file join $homework_dir bd HW_5_ps.tcl]
set bd_file [get_files HW_5_ps.bd]
generate_target all $bd_file
add_files -norecurse [make_wrapper -files $bd_file -top]
# 測試檔只測 PL（HW_5_pong），PS 與 top 不放進模擬
set_property used_in_simulation false [get_files [file join $source_dir HW_5.vhd]]
set_property used_in_simulation false $bd_file
set_property top HW_5 [get_filesets sources_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
close_project
puts "Added block design HW_5_ps to $project_file"
