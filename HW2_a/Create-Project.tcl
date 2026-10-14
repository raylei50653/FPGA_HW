set homework HW2_a
# EGO-XZ7 板（腳位見 constraints/HW_2_a.xdc）
set part xc7z020clg484-1
# HW_2_a_tb 約 11.6 us 跑完三次呼吸，預設 1000 ns 不夠
set sim_runtime 11700ns
source [file join [file dirname [info script]] .. scripts Create-VivadoProject.tcl]
