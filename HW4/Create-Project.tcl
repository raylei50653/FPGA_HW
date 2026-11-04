set homework HW4
# EGO-XZ7 板（腳位見 constraints/HW_4.xdc）
set part xc7z020clg484-1
# HW_4_tb 以 VHDL-2008 external name 讀取內部訊號
set sim_vhdl2008 1
# HW_4_tb 縮短後約 70 µs 跑完
set sim_runtime 1ms
source [file join [file dirname [info script]] .. scripts Create-VivadoProject.tcl]
