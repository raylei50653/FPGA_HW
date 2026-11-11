# 用 SDK 2018.3 的 xsct 建置 PS 程式，並包成 SD 卡開機用的 BOOT.bin（規格見 HW5/SPEC.md §12.5）
# 先跑 HW5/Build-Hardware.tcl 產生 vivado/HW5/HW_5.hdf，再在儲存庫根目錄執行：
#   C:\Xilinx\SDK\2018.3\bin\xsct.bat HW5/sw/Build-Software.tcl
# 產生（都在 vivado/HW5/sdk/，Git 不追蹤）：
#   usb_kbd/Debug/usb_kbd.elf   PS 程式
#   fsbl/Debug/fsbl.elf         first stage boot loader
#   BOOT.bin                    FSBL + bitstream + usb_kbd，複製到 SD 卡根目錄即可開機
set repo_root [file normalize [file join [file dirname [info script]] .. ..]]
set ws  [file join $repo_root vivado HW5 sdk]
set hdf [file join $repo_root vivado HW5 HW_5.hdf]
set src [file join $repo_root HW5 sw usb_kbd src]

if {![file exists $hdf]} {
    error "Missing $hdf. Run HW5/Build-Hardware.tcl first."
}
file delete -force $ws
file mkdir $ws
setws $ws

createhw  -name hw -hwspec $hdf
createbsp -name bsp -hwproject hw -proc ps7_cortexa9_0 -os standalone
createapp -name usb_kbd -hwproject hw -bsp bsp -proc ps7_cortexa9_0 -os standalone -lang C -app {Empty Application}
importsources -name usb_kbd -path $src
createapp -name fsbl -hwproject hw -proc ps7_cortexa9_0 -os standalone -lang C -app {Zynq FSBL}
projects -build

set bit [lindex [glob -directory [file join $ws hw] *.bit] 0]
set bif [file join $ws boot.bif]
set f [open $bif w]
puts $f "the_ROM_image:"
puts $f "\{"
puts $f "  \[bootloader\] [file join $ws fsbl Debug fsbl.elf]"
puts $f "  $bit"
puts $f "  [file join $ws usb_kbd Debug usb_kbd.elf]"
puts $f "\}"
close $f
exec bootgen -image $bif -arch zynq -o [file join $ws BOOT.bin] -w on
puts "Wrote [file join $ws BOOT.bin]"
