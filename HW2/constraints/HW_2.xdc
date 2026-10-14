## HW2 8 顆 LED 呼吸燈腳位檔
## 板子：e-elements EGO-XZ7（xc7z020clg484-1）
## 腳位與電壓取自 Vivado board file：data/boards/board_files/EGO-XZ7/1.1/part0_pins.xml

## 系統時脈 100 MHz（CLK_FREQ_HZ 預設值）
set_property -dict { PACKAGE_PIN Y9  IOSTANDARD LVCMOS33 } [get_ports clk]
create_clock -period 10.000 -name sys_clk -waveform {0.000 5.000} [get_ports clk]

## 按鈕：按下為高電位（BTN_ACTIVE_LOW = false）
set_property -dict { PACKAGE_PIN P16 IOSTANDARD LVCMOS25 } [get_ports reset]      ;# BTNC
set_property -dict { PACKAGE_PIN T18 IOSTANDARD LVCMOS25 } [get_ports btn_mode]   ;# BTNU
set_property -dict { PACKAGE_PIN N15 IOSTANDARD LVCMOS25 } [get_ports btn_hold]   ;# BTNL
set_property -dict { PACKAGE_PIN R18 IOSTANDARD LVCMOS25 } [get_ports btn_breath] ;# BTNR

## LED：高電位點亮（LED_ACTIVE_LOW = false）
set_property -dict { PACKAGE_PIN T22 IOSTANDARD LVCMOS33 } [get_ports {led[0]}]   ;# LD0
set_property -dict { PACKAGE_PIN T21 IOSTANDARD LVCMOS33 } [get_ports {led[1]}]   ;# LD1
set_property -dict { PACKAGE_PIN U22 IOSTANDARD LVCMOS33 } [get_ports {led[2]}]   ;# LD2
set_property -dict { PACKAGE_PIN U21 IOSTANDARD LVCMOS33 } [get_ports {led[3]}]   ;# LD3
set_property -dict { PACKAGE_PIN V22 IOSTANDARD LVCMOS33 } [get_ports {led[4]}]   ;# LD4
set_property -dict { PACKAGE_PIN W22 IOSTANDARD LVCMOS33 } [get_ports {led[5]}]   ;# LD5
set_property -dict { PACKAGE_PIN U19 IOSTANDARD LVCMOS33 } [get_ports {led[6]}]   ;# LD6
set_property -dict { PACKAGE_PIN U14 IOSTANDARD LVCMOS33 } [get_ports {led[7]}]   ;# LD7

## 按鈕與 LED 對時脈非同步，不做 I/O 時序分析
set_false_path -from [get_ports {reset btn_*}]
set_false_path -to   [get_ports {led[*]}]
