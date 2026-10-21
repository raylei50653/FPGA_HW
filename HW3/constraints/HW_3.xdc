## HW3 VGA 掃描腳位檔
## 板子：e-elements EGO-XZ7（xc7z020clg484-1）
## 時脈、按鈕、開關、LED 取自 Vivado board file：data/boards/board_files/EGO-XZ7/1.1/part0_pins.xml
## board file 沒有 VGA，VGA 腳位需依板子手冊（或外接的 VGA 轉接線路）填入下方 TODO 區段

## 系統時脈 100 MHz；像素率 = 100 MHz / PIX_DIV（預設 4，25 MHz）
set_property -dict { PACKAGE_PIN Y9  IOSTANDARD LVCMOS33 } [get_ports clk]
create_clock -period 10.000 -name sys_clk -waveform {0.000 5.000} [get_ports clk]

## 按鈕：按下為高電位（BTN_ACTIVE_LOW = false）
set_property -dict { PACKAGE_PIN P16 IOSTANDARD LVCMOS25 } [get_ports reset]      ;# BTNC
set_property -dict { PACKAGE_PIN T18 IOSTANDARD LVCMOS25 } [get_ports btn_mode]   ;# BTNU 基本色塊 / 旋轉多面體
set_property -dict { PACKAGE_PIN N15 IOSTANDARD LVCMOS25 } [get_ports btn_speed]  ;# BTNL
set_property -dict { PACKAGE_PIN R18 IOSTANDARD LVCMOS25 } [get_ports btn_dir]    ;# BTNR
set_property -dict { PACKAGE_PIN R16 IOSTANDARD LVCMOS25 } [get_ports btn_style]  ;# BTND（board file 第 5 顆按鈕）

## 開關：撥上為高電位
set_property -dict { PACKAGE_PIN F22 IOSTANDARD LVCMOS25 } [get_ports sw_pause]   ;# SW0 暫停旋轉

## LED：高電位點亮（LED_ACTIVE_LOW = false）
set_property -dict { PACKAGE_PIN T22 IOSTANDARD LVCMOS33 } [get_ports {led[0]}]   ;# LD0 旋轉多面體模式
set_property -dict { PACKAGE_PIN T21 IOSTANDARD LVCMOS33 } [get_ports {led[1]}]   ;# LD1 轉動中
set_property -dict { PACKAGE_PIN U22 IOSTANDARD LVCMOS33 } [get_ports {led[2]}]   ;# LD2 反轉
set_property -dict { PACKAGE_PIN U21 IOSTANDARD LVCMOS33 } [get_ports {led[3]}]   ;# LD3 轉速 bit 0
set_property -dict { PACKAGE_PIN V22 IOSTANDARD LVCMOS33 } [get_ports {led[4]}]   ;# LD4 轉速 bit 1
set_property -dict { PACKAGE_PIN W22 IOSTANDARD LVCMOS33 } [get_ports {led[5]}]   ;# LD5 樣式 bit 0
set_property -dict { PACKAGE_PIN U19 IOSTANDARD LVCMOS33 } [get_ports {led[6]}]   ;# LD6 樣式 bit 1
set_property -dict { PACKAGE_PIN U14 IOSTANDARD LVCMOS33 } [get_ports {led[7]}]   ;# LD7 心跳

## TODO VGA：填入腳位後取消註解；預設 R、G、B 各 1 bit（RED_BITS / GREEN_BITS / BLUE_BITS = 1）
## 螢幕端每色是 75 Ω、滿刻度 0.7 V：3.3 V 輸出串約 270 Ω 電阻，3.3 × 75 / (270 + 75) ≈ 0.72 V
## 未填之前可以綜合，但 implementation 的 DRC（UCIO-1、NSTD-1）會擋下 bitstream
# set_property -dict { PACKAGE_PIN ??? IOSTANDARD LVCMOS33 } [get_ports {vga_r[0]}]
# set_property -dict { PACKAGE_PIN ??? IOSTANDARD LVCMOS33 } [get_ports {vga_g[0]}]
# set_property -dict { PACKAGE_PIN ??? IOSTANDARD LVCMOS33 } [get_ports {vga_b[0]}]
# set_property -dict { PACKAGE_PIN ??? IOSTANDARD LVCMOS33 } [get_ports vga_hs]
# set_property -dict { PACKAGE_PIN ??? IOSTANDARD LVCMOS33 } [get_ports vga_vs]

## 按鈕、開關對時脈非同步；LED 與 VGA 輸出皆由暫存器直接驅動，螢幕端不需要 I/O 時序分析
set_false_path -from [get_ports {reset btn_* sw_*}]
set_false_path -to   [get_ports {led[*] vga_*}]
