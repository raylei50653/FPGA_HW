# HW5 的 PS 部分（block design HW_5_ps，規格見 HW5/SPEC.md §12）
#   Zynq PS7（套用 EGO-XZ7 board preset：DDR、UART1、USB0 等）+ 一個 AXI GPIO（8 bit 輸出）
#   PS 上的裸機程式（HW5/sw/usb_kbd）讀 USB 鍵盤，把按鍵狀態寫進 AXI GPIO，從 kbd[7:0] 交給 PL
#   AXI 與 GPIO 都跑在 PL 的 100 MHz 系統時脈（pl_clk，接板上 Y9），kbd 和遊戲邏輯同一個時脈域
#   MIO 46 接 USB3320 的 RESET#（《EGO-XZ7 硬體手冊》V1.2 表 10），開 MIO GPIO 讓程式控制它
# 由 HW5/Create-Project.tcl 在專案開著時 source

create_bd_design HW_5_ps

set ps7 [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7]
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {make_external "FIXED_IO, DDR" apply_board_preset "1" Master "Disable" Slave "Disable"} $ps7
set_property -dict [list \
    CONFIG.PCW_USE_M_AXI_GP0 {1} \
    CONFIG.PCW_EN_CLK0_PORT {0} \
    CONFIG.PCW_EN_RST0_PORT {1} \
    CONFIG.PCW_GPIO_MIO_GPIO_ENABLE {1} \
    CONFIG.PCW_GPIO_MIO_GPIO_IO {MIO} \
] $ps7

set gpio [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 kbd_gpio]
set_property -dict [list CONFIG.C_GPIO_WIDTH {8} CONFIG.C_ALL_OUTPUTS {1} CONFIG.C_DOUT_DEFAULT {0x00000000}] $gpio

set ic [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_ic]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] $ic

set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_pl]

# 時脈：PL 的 100 MHz（Y9）
set pl_clk [create_bd_port -dir I -type clk pl_clk]
set_property CONFIG.FREQ_HZ 100000000 $pl_clk
connect_bd_net $pl_clk \
    [get_bd_pins ps7/M_AXI_GP0_ACLK] [get_bd_pins kbd_gpio/s_axi_aclk] \
    [get_bd_pins axi_ic/ACLK] [get_bd_pins axi_ic/S00_ACLK] [get_bd_pins axi_ic/M00_ACLK] \
    [get_bd_pins rst_pl/slowest_sync_clk]

# reset：PS 的 FCLK_RESET0_N 同步到 pl_clk
connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N] [get_bd_pins rst_pl/ext_reset_in]
connect_bd_net [get_bd_pins rst_pl/interconnect_aresetn] [get_bd_pins axi_ic/ARESETN]
connect_bd_net [get_bd_pins rst_pl/peripheral_aresetn] \
    [get_bd_pins axi_ic/S00_ARESETN] [get_bd_pins axi_ic/M00_ARESETN] [get_bd_pins kbd_gpio/s_axi_aresetn]

# AXI：PS M_AXI_GP0 → interconnect → GPIO
connect_bd_intf_net [get_bd_intf_pins ps7/M_AXI_GP0] [get_bd_intf_pins axi_ic/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_ic/M00_AXI] [get_bd_intf_pins kbd_gpio/S_AXI]

# 按鍵狀態輸出給 PL
set kbd [create_bd_port -dir O -from 7 -to 0 kbd]
connect_bd_net [get_bd_pins kbd_gpio/gpio_io_o] $kbd

assign_bd_address
validate_bd_design
save_bd_design
