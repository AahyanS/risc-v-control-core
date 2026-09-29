# program_flash.tcl
# Writes a flash image (.mcs from build.tcl: bitstream at 0x0, CPU
# program at 0x300000) into the Basys3's onboard 4 MB QSPI flash,
# erasing and verifying as it goes. Run from the repository root with
# the board plugged in and powered on:
#
#   vivado -mode batch -source fpga/program_flash.tcl -tclargs fpga/build/core/basys3_flash.mcs [fpga/build/core/basys3_top.bit] [flash_part]
#
# flash_part defaults to mx25l3273f-spi-x1_x2_x4 (Macronix MX25L3273F),
# which is what this project's board turned out to have - Digilent's
# documentation lists a Spansion S25FL032P, which older Basys3
# revisions use; pass s25fl032p-spi-x1_x2_x4 for those. If the part is
# wrong, Vivado reads the chip's ID and stops before writing anything.
#
# Vivado writes the flash through a temporary programming design it
# loads into the FPGA, so afterwards the FPGA is running that, not
# yours. Either:
#   - pass the .bit as the second argument, and it's loaded over JTAG
#     right after flashing (the CPU then runs from the program just
#     written to flash - works with JP1 in either position), or
#   - set JP1 to QSPI and power-cycle, and the board boots itself from
#     flash (the real standalone test).

set mcs [file normalize [lindex $argv 0]]
set bit [lindex $argv 1]
set flash_part [lindex $argv 2]
if {$flash_part eq ""} { set flash_part mx25l3273f-spi-x1_x2_x4 }
if {![file exists $mcs]} {
    puts "ERROR: flash image not found: $mcs"
    exit 1
}

open_hw_manager
connect_hw_server
open_hw_target

set dev [lindex [get_hw_devices xc7a35t*] 0]
if {$dev eq ""} {
    puts "ERROR: no XC7A35T found on the JTAG chain - is the Basys3 plugged in and switched on?"
    exit 1
}
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev

set part [lindex [get_cfgmem_parts $flash_part] 0]
create_hw_cfgmem -hw_device $dev $part
set cfg [get_property PROGRAM.HW_CFGMEM $dev]

set_property PROGRAM.ADDRESS_RANGE          {use_file}  $cfg
set_property PROGRAM.FILES                  [list $mcs] $cfg
set_property PROGRAM.PRM_FILE               {}          $cfg
set_property PROGRAM.UNUSED_PIN_TERMINATION {pull-none} $cfg
set_property PROGRAM.BLANK_CHECK            0           $cfg
set_property PROGRAM.ERASE                  1           $cfg
set_property PROGRAM.CFG_PROGRAM            1           $cfg
set_property PROGRAM.VERIFY                 1           $cfg
set_property PROGRAM.CHECKSUM               0           $cfg

# Load Vivado's flash-programming design into the FPGA, then write.
create_hw_bitstream -hw_device $dev [get_property PROGRAM.HW_CFGMEM_BITFILE $dev]
program_hw_devices $dev
refresh_hw_device -update_hw_probes false $dev
program_hw_cfgmem -hw_cfgmem $cfg
puts "Flash programmed and verified: [file tail $mcs]"

if {$bit ne ""} {
    set bit [file normalize $bit]
    set_property PROGRAM.FILE $bit $dev
    program_hw_devices $dev
    puts "Loaded [file tail $bit] over JTAG - the CPU is now running from flash"
}

close_hw_target
disconnect_hw_server
close_hw_manager
