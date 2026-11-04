## HW4 LED 乒乓球腳位檔
## 板子：e-elements EGO-XZ7（xc7z020clg484-1）
## 腳位與電壓取自 Vivado board file：data/boards/board_files/EGO-XZ7/1.1/part0_pins.xml

## 系統時脈 100 MHz（CLK_FREQ_HZ 預設值）
set_property -dict { PACKAGE_PIN Y9  IOSTANDARD LVCMOS33 } [get_ports clk]
create_clock -period 10.000 -name sys_clk -waveform {0.000 5.000} [get_ports clk]

## 按鈕：按下為高電位（BTN_ACTIVE_LOW = false）
## LED 實際左右順序若與 LD7 = 左相反，對調 btn_l / btn_r 的腳位即可
set_property -dict { PACKAGE_PIN P16 IOSTANDARD LVCMOS25 } [get_ports reset]    ;# BTNC
set_property -dict { PACKAGE_PIN N15 IOSTANDARD LVCMOS25 } [get_ports btn_l]    ;# BTNL 左玩家
set_property -dict { PACKAGE_PIN R18 IOSTANDARD LVCMOS25 } [get_ports btn_r]    ;# BTNR 右玩家

## 開關：撥上為高電位
set_property -dict { PACKAGE_PIN F22 IOSTANDARD LVCMOS25 } [get_ports sw_speed] ;# SW0 球速：撥下 500 ms、撥上 250 ms

## LED：高電位點亮（LED_ACTIVE_LOW = false）；LD7 = 左端、LD0 = 右端
set_property -dict { PACKAGE_PIN T22 IOSTANDARD LVCMOS33 } [get_ports {led[0]}] ;# LD0
set_property -dict { PACKAGE_PIN T21 IOSTANDARD LVCMOS33 } [get_ports {led[1]}] ;# LD1
set_property -dict { PACKAGE_PIN U22 IOSTANDARD LVCMOS33 } [get_ports {led[2]}] ;# LD2
set_property -dict { PACKAGE_PIN U21 IOSTANDARD LVCMOS33 } [get_ports {led[3]}] ;# LD3
set_property -dict { PACKAGE_PIN V22 IOSTANDARD LVCMOS33 } [get_ports {led[4]}] ;# LD4
set_property -dict { PACKAGE_PIN W22 IOSTANDARD LVCMOS33 } [get_ports {led[5]}] ;# LD5
set_property -dict { PACKAGE_PIN U19 IOSTANDARD LVCMOS33 } [get_ports {led[6]}] ;# LD6
set_property -dict { PACKAGE_PIN U14 IOSTANDARD LVCMOS33 } [get_ports {led[7]}] ;# LD7

## 按鈕、開關與 LED 對時脈非同步，不做 I/O 時序分析
set_false_path -from [get_ports {reset btn_* sw_speed}]
set_false_path -to   [get_ports {led[*]}]
