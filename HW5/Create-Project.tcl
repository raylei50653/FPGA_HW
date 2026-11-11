set homework HW5
# EGO-XZ7 板（腳位見 constraints/HW_5.xdc）
set part xc7z020clg484-1
# 測試檔以 VHDL-2008 external name 讀取內部訊號
set sim_vhdl2008 1
# 預設模擬 HW_5_tb（約 4 幀）；要跑 HW_5_game_tb 時在 Vivado 把 sim_1 的 top 改掉
set sim_runtime 80ms
source [file join [file dirname [info script]] .. scripts Create-VivadoProject.tcl]
