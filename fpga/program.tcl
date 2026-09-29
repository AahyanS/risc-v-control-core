# program.tcl
# Loads a bitstream into the Basys3 over USB/JTAG. This is volatile -
# the board forgets it at power-off - and it doesn't touch the flash,
# so a program already stored in flash stays put. Run from the
# repository root with the board plugged in, powered on, and JP1 set
# to JTAG:
#
#   vivado -mode batch -source fpga/program.tcl -tclargs fpga/build/bringup/bringup_top.bit

set bit [file normalize [lindex $argv 0]]
if {![file exists $bit]} {
    puts "ERROR: bitstream not found: $bit"
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
set_property PROGRAM.FILE $bit $dev
program_hw_devices $dev
puts "Programmed [file tail $bit] into $dev"

close_hw_target
disconnect_hw_server
close_hw_manager
