set homework HW2
# EGO-XZ7 板（腳位見 constraints/HW_2.xdc）
set part xc7z020clg484-1
# HW_2_tb 以 VHDL-2008 external name 讀取設定暫存器
set sim_vhdl2008 1
# HW_2_tb 約 2.61 ms 跑完全部項目，預設 1000 ns 不夠
set sim_runtime 2700us
source [file join [file dirname [info script]] .. scripts Create-VivadoProject.tcl]
