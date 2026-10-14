## HW2_a 呼吸燈腳位檔
## 板子：e-elements EGO-XZ7（xc7z020clg484-1）
## 腳位與電壓取自 Vivado board file：data/boards/board_files/EGO-XZ7/1.1/part0_pins.xml

## 系統時脈 100 MHz（CLK_FREQ_HZ 預設值）
set_property -dict { PACKAGE_PIN Y9  IOSTANDARD LVCMOS33 } [get_ports clk]
create_clock -period 10.000 -name sys_clk -waveform {0.000 5.000} [get_ports clk]

## reset：中間按鈕 BTNC，按下為高電位（同步、高電位有效）
set_property -dict { PACKAGE_PIN P16 IOSTANDARD LVCMOS25 } [get_ports reset]

## led：LD0，高電位點亮（LED_ACTIVE_LOW = false）
set_property -dict { PACKAGE_PIN T22 IOSTANDARD LVCMOS33 } [get_ports led]

## 按鈕與 LED 對時脈非同步，不做 I/O 時序分析
set_false_path -from [get_ports reset]
set_false_path -to   [get_ports led]
