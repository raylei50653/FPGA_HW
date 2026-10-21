set homework HW3
# EGO-XZ7 板（腳位見 constraints/HW_3.xdc，VGA 腳位待補）
set part xc7z020clg484-1
# HW_3_tb 以 VHDL-2008 external name 擷取視訊串流
set sim_vhdl2008 1
# HW_3_tb 跑約 9 幀 640×480@60（約 150 ms），預設 1000 ns 不夠
set sim_runtime 160ms
source [file join [file dirname [info script]] .. scripts Create-VivadoProject.tcl]
