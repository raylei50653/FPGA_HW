# 不用 SD 卡，直接經 JTAG 燒 bitstream、初始化 PS、載入並執行 usb_kbd（板子的開機模式設成 JTAG）
# 先跑 HW5/sw/Build-Software.tcl，再在儲存庫根目錄執行：
#   C:\Xilinx\SDK\2018.3\bin\xsct.bat HW5/sw/Run-JTAG.tcl
set repo_root [file normalize [file join [file dirname [info script]] .. ..]]
set ws  [file join $repo_root vivado HW5 sdk]
set bit [lindex [glob -directory [file join $ws hw] *.bit] 0]
set elf [file join $ws usb_kbd Debug usb_kbd.elf]

connect
targets -set -nocase -filter {name =~ "APU*"}
rst -system
after 1000
fpga -file $bit
source [file join $ws hw ps7_init.tcl]
ps7_init
ps7_post_config
targets -set -nocase -filter {name =~ "*A9*#0"}
dow $elf
con
puts "usb_kbd is running; open UART1 (USB-UART, 115200 8N1) to see the log"
