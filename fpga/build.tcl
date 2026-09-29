# build.tcl
# Vivado batch build for the Basys3 (XC7A35T). Run from the repository
# root:
#
#   vivado -mode batch -source fpga/build.tcl -tclargs bringup
#       switches-to-LEDs test; produces fpga/build/bringup/bringup_top.bit
#
#   vivado -mode batch -source fpga/build.tcl -tclargs core sw/hw_hello.bin
#       the full CPU design; produces fpga/build/core/basys3_top.bit and,
#       with a program given, fpga/build/core/basys3_flash.mcs: one flash
#       image with the bitstream at 0x0 and the program at 0x300000
#       (basys3_top.v's FLASH_BASE)
#
# Reports land next to the outputs. The core build also prints the
# achievable clock frequency from the worst timing path, which answers
# PROJECT.md's open question about whether the MAC multiplier limits
# the clock.

set target  [lindex $argv 0]
set program [lindex $argv 1]

set root [file normalize [file join [file dirname [info script]] ..]]
set part xc7a35tcpg236-1

if {$target eq "bringup"} {
    set top bringup_top
    read_verilog [file join $root fpga bringup_top.v]
    read_xdc     [file join $root fpga bringup.xdc]
} elseif {$target eq "core"} {
    set top basys3_top
    foreach f {alu.v regfile.v control.v pc.v dmem.v spi_flash_ctrl.v
               icache.v quad_decoder.v pwm.v timer.v uart_tx.v motor_dir_guard.v
               cpu_pipeline_cache_locked.v fpga/basys3_top.v} {
        read_verilog [file join $root $f]
    }
    read_xdc [file join $root fpga basys3.xdc]
} else {
    puts "usage: vivado -mode batch -source fpga/build.tcl -tclargs bringup"
    puts "       vivado -mode batch -source fpga/build.tcl -tclargs core \[program.bin\]"
    exit 1
}

set out [file join $root fpga build $target]
file mkdir $out

synth_design -top $top -part $part
report_utilization -file [file join $out utilization_synth.rpt]

opt_design
place_design
phys_opt_design
route_design

report_utilization                -file [file join $out utilization.rpt]
report_utilization -hierarchical  -file [file join $out utilization_hierarchical.rpt]
report_timing_summary             -file [file join $out timing_summary.rpt]
report_timing -max_paths 20 -nworst 1 -path_type summary \
                                  -file [file join $out timing_worst_20_paths.rpt]
report_timing -max_paths 1        -file [file join $out timing_critical_path.rpt]

write_bitstream -force [file join $out $top.bit]

# ---- Achievable clock from the worst setup path ----
set worst [get_timing_paths -max_paths 1 -nworst 1 -setup]
set wns    [get_property SLACK $worst]
set clk    [get_property ENDPOINT_CLOCK $worst]
set period [get_property PERIOD [get_clocks $clk]]
set fmax   [expr {1000.0 / ($period - $wns)}]
puts ""
puts "================================================================"
puts [format "Clock %s: period %.2f ns, worst slack %.3f ns" $clk $period $wns]
puts [format "Achievable frequency on the worst path: %.1f MHz" $fmax]
puts "Worst path: [get_property STARTPOINT_PIN $worst] -> [get_property ENDPOINT_PIN $worst]"
puts "Full list: [file join $out timing_worst_20_paths.rpt]"
puts "================================================================"

# ---- Flash image: bitstream + program ----
if {$target eq "core" && $program ne ""} {
    set bin [file normalize [file join $root $program]]
    write_cfgmem -force -format mcs -size 4 -interface SPIx4 \
        -loadbit  "up 0x00000000 [file join $out $top.bit]" \
        -loaddata "up 0x00300000 $bin" \
        -file [file join $out basys3_flash.mcs]
    puts "Flash image: [file join $out basys3_flash.mcs] (program: $program at 0x300000)"
}
