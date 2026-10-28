## HW3 視訊掃描腳位檔（HDMI 輸出）
## 板子：e-elements EGO-XZ7（xc7z020clg484-1）
## 時脈、按鈕、開關、LED 取自 Vivado board file：data/boards/board_files/EGO-XZ7/1.1/part0_pins.xml
## board file 沒有 VGA 與 HDMI：HDMI 腳位取自《EGO-XZ7 硬體手冊》V1.2 表 14
## EGO-XZ7 沒有 VGA 接頭，HW_3 的 VGA 埠已註解掉；外接 VGA 時一起取消下方 [VGA] 區段的註解並填腳位

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
set_property -dict { PACKAGE_PIN U19 IOSTANDARD LVCMOS33 } [get_ports {led[6]}]   ;# LD6 ADV7511 設定成功
set_property -dict { PACKAGE_PIN U14 IOSTANDARD LVCMOS33 } [get_ports {led[7]}]   ;# LD7 心跳

## [VGA] 預設 R、G、B 各 1 bit（RED_BITS / GREEN_BITS / BLUE_BITS = 1）
## 螢幕端每色是 75 Ω、滿刻度 0.7 V：3.3 V 輸出串約 270 Ω 電阻，3.3 × 75 / (270 + 75) ≈ 0.72 V
## I/O 標準一定要設：沒設時 Vivado 預設 LVCMOS18，這塊板子沒有 1.8 V 的 bank，place_design 會失敗
# set_property IOSTANDARD LVCMOS33 [get_ports {vga_r[*] vga_g[*] vga_b[*] vga_hs vga_vs}]
## 腳位依外接線路填入；另外把下方 set_false_path -to 的埠清單加回 vga_*
# set_property PACKAGE_PIN ??? [get_ports {vga_r[0]}]
# set_property PACKAGE_PIN ??? [get_ports {vga_g[0]}]
# set_property PACKAGE_PIN ??? [get_ports {vga_b[0]}]
# set_property PACKAGE_PIN ??? [get_ports vga_hs]
# set_property PACKAGE_PIN ??? [get_ports vga_vs]

## HDMI：板子上的 ADV7511（HDMI 發送晶片）負責 TMDS 編碼，FPGA 送影像資料、同步與像素時脈，並以 I2C 設定它
## 腳位取自《EGO-XZ7 硬體手冊》V1.2 表 14（電路圖網路名稱 HDMI_Dn 與 ADV7511 的 Dn 編號不同，以 ADV7511 的編號為準）
## ADV7511 的輸入匯流排有 36 bit（24 bit RGB 的 R 在 D35..28），板子只接了 D23..D0，所以和 ZedBoard 一樣送
## 16 bit YCbCr 4:2:2（輸入 ID 1）：D23..D16 = Cb / Cr 輪流、D15..D8 = Y、D7..D0 不用（輸出 0）；
## 板子沒有接 DE，用 ADV7511 的 DE 產生器
set_property -dict { PACKAGE_PIN W18  IOSTANDARD LVCMOS33 } [get_ports hdmi_clk]        ;# HDMI_CLK   -> ADV7511 CLK
set_property -dict { PACKAGE_PIN V17  IOSTANDARD LVCMOS33 } [get_ports hdmi_hs]         ;# HDMI_HSYNC -> ADV7511 HSYNC
set_property -dict { PACKAGE_PIN W17  IOSTANDARD LVCMOS33 } [get_ports hdmi_vs]         ;# HDMI_VSYNC -> ADV7511 VSYNC
set_property -dict { PACKAGE_PIN V13  IOSTANDARD LVCMOS33 } [get_ports {hdmi_d[23]}  ] ;# HDMI_D15 -> ADV7511 D23 C7
set_property -dict { PACKAGE_PIN V14  IOSTANDARD LVCMOS33 } [get_ports {hdmi_d[22]}  ] ;# HDMI_D14 -> ADV7511 D22 C6
set_property -dict { PACKAGE_PIN U17  IOSTANDARD LVCMOS33 } [get_ports {hdmi_d[21]}  ] ;# HDMI_D13 -> ADV7511 D21 C5
set_property -dict { PACKAGE_PIN V15  IOSTANDARD LVCMOS33 } [get_ports {hdmi_d[20]}  ] ;# HDMI_D12 -> ADV7511 D20 C4
set_property -dict { PACKAGE_PIN W15  IOSTANDARD LVCMOS33 } [get_ports {hdmi_d[19]}  ] ;# HDMI_D11 -> ADV7511 D19 C3
set_property -dict { PACKAGE_PIN W13  IOSTANDARD LVCMOS33 } [get_ports {hdmi_d[18]}  ] ;# HDMI_D10 -> ADV7511 D18 C2
set_property -dict { PACKAGE_PIN Y15  IOSTANDARD LVCMOS33 } [get_ports {hdmi_d[17]}  ] ;# HDMI_D9  -> ADV7511 D17 C1
set_property -dict { PACKAGE_PIN AA17 IOSTANDARD LVCMOS33 } [get_ports {hdmi_d[16]}  ] ;# HDMI_D8  -> ADV7511 D16 C0
set_property -dict { PACKAGE_PIN AB17 IOSTANDARD LVCMOS33 } [get_ports {hdmi_d[15]}  ] ;# HDMI_D7  -> ADV7511 D15 Y7
set_property -dict { PACKAGE_PIN AA16 IOSTANDARD LVCMOS33 } [get_ports {hdmi_d[14]}  ] ;# HDMI_D6  -> ADV7511 D14 Y6
set_property -dict { PACKAGE_PIN AB16 IOSTANDARD LVCMOS33 } [get_ports {hdmi_d[13]}  ] ;# HDMI_D5  -> ADV7511 D13 Y5
set_property -dict { PACKAGE_PIN AB15 IOSTANDARD LVCMOS33 } [get_ports {hdmi_d[12]}  ] ;# HDMI_D4  -> ADV7511 D12 Y4
set_property -dict { PACKAGE_PIN Y14  IOSTANDARD LVCMOS33 } [get_ports {hdmi_d[11]}  ] ;# HDMI_D3  -> ADV7511 D11 Y3
set_property -dict { PACKAGE_PIN AA14 IOSTANDARD LVCMOS33 } [get_ports {hdmi_d[10]}  ] ;# HDMI_D2  -> ADV7511 D10 Y2
set_property -dict { PACKAGE_PIN AA13 IOSTANDARD LVCMOS33 } [get_ports {hdmi_d[9]}   ] ;# HDMI_D1  -> ADV7511 D9  Y1
set_property -dict { PACKAGE_PIN Y13  IOSTANDARD LVCMOS33 } [get_ports {hdmi_d[8]}   ] ;# HDMI_D0  -> ADV7511 D8  Y0
set_property -dict { PACKAGE_PIN AA19 IOSTANDARD LVCMOS33 } [get_ports {hdmi_d[7]}   ] ;# HDMI_D23 -> ADV7511 D7  （不用）
set_property -dict { PACKAGE_PIN Y19  IOSTANDARD LVCMOS33 } [get_ports {hdmi_d[6]}   ] ;# HDMI_D22 -> ADV7511 D6  （不用）
set_property -dict { PACKAGE_PIN AB20 IOSTANDARD LVCMOS33 } [get_ports {hdmi_d[5]}   ] ;# HDMI_D21 -> ADV7511 D5  （不用）
set_property -dict { PACKAGE_PIN AB19 IOSTANDARD LVCMOS33 } [get_ports {hdmi_d[4]}   ] ;# HDMI_D20 -> ADV7511 D4  （不用）
set_property -dict { PACKAGE_PIN Y21  IOSTANDARD LVCMOS33 } [get_ports {hdmi_d[3]}   ] ;# HDMI_D19 -> ADV7511 D3  （不用）
set_property -dict { PACKAGE_PIN Y20  IOSTANDARD LVCMOS33 } [get_ports {hdmi_d[2]}   ] ;# HDMI_D18 -> ADV7511 D2  （不用）
set_property -dict { PACKAGE_PIN AB21 IOSTANDARD LVCMOS33 } [get_ports {hdmi_d[1]}   ] ;# HDMI_D17 -> ADV7511 D1  （不用）
set_property -dict { PACKAGE_PIN AA21 IOSTANDARD LVCMOS33 } [get_ports {hdmi_d[0]}   ] ;# HDMI_D16 -> ADV7511 D0  （不用）
## I2C：開汲極，板上應有上拉電阻，再開 FPGA 內部上拉以防萬一
set_property -dict { PACKAGE_PIN AA18 IOSTANDARD LVCMOS33 PULLUP true } [get_ports hdmi_scl]   ;# HDMI_SCL
set_property -dict { PACKAGE_PIN Y16  IOSTANDARD LVCMOS33 PULLUP true } [get_ports hdmi_sda]   ;# HDMI_SDA
## 未使用：HDMI_INT（W16）、HDMI_SPDIFO（Y18）
## 資料（D23..D8）、同步與像素時脈的暫存器放進 IOB，輸出時間一致；像素時脈在資料換值後 20 ns 才上升，不需要 I/O 時序約束
set_property IOB TRUE [get_ports {hdmi_d[8] hdmi_d[9] hdmi_d[10] hdmi_d[11] hdmi_d[12] hdmi_d[13] hdmi_d[14] hdmi_d[15] hdmi_d[16] hdmi_d[17] hdmi_d[18] hdmi_d[19] hdmi_d[20] hdmi_d[21] hdmi_d[22] hdmi_d[23] hdmi_hs hdmi_vs hdmi_clk}]

## 按鈕、開關對時脈非同步；LED 由暫存器直接驅動，不需要 I/O 時序分析
## HDMI 的資料與時脈都由 IOB 暫存器送出，相位關係由設計保證（§6.5）；I2C 很慢，也不需要分析
set_false_path -from [get_ports {reset btn_* sw_*}]
set_false_path -to   [get_ports {led[*] hdmi_*}]
set_false_path -from [get_ports {hdmi_sda}]
