#!/bin/bash
# build_programs.sh
# Builds the hardware test programs two ways:
#   sw/<name>.bin     - raw binary for the hardware flash image
#                       (fpga/build.tcl stores it at FLASH_BASE)
#   sw/<name>_sim.hex - same program with tiny delay constants, for
#                       fpga/sim/tb_basys3_top.v
#
# Run from the repository root:  bash fpga/build_programs.sh

set -e
cd "$(dirname "$0")/.."

CC=riscv-none-elf-gcc
OBJCOPY=riscv-none-elf-objcopy
FLAGS="-march=rv32i -mabi=ilp32 -nostdlib -nostartfiles -Ttext=0x0 -Wa,-Isw"

build() {
    local name=$1
    local simdefs=$2

    $CC $FLAGS -o sw/$name.elf sw/$name.s
    $OBJCOPY -O binary sw/$name.elf sw/$name.bin

    $CC $FLAGS $simdefs -o sw/${name}_sim.elf sw/$name.s
    $OBJCOPY -O verilog sw/${name}_sim.elf sw/${name}_sim.hex

    echo "built $name: $(wc -c < sw/$name.bin) bytes"
}

build hw_hello      "-Wa,--defsym,DELAY=20"
build hw_motor_test "-Wa,--defsym,RUN_ITERS=40 -Wa,--defsym,STOP_ITERS=15"
build hw_cache_lock "-Wa,--defsym,DELAY=50"
# Sim: 8-tick windows and a coarser search, so the board simulation
# finishes in minutes; hardware uses 256 ticks and ~1.6% resolution.
build hw_control_loop "-Wa,--defsym,WINDOW_SHIFT=3 -Wa,--defsym,SEARCH_SHIFT=4"
# Sim: 2000-cycle ticks (the board sim's motor model is scaled to match),
# 150-tick segments, and a log line every 10 ticks - printing isn't
# scaled down with the tick, so it can't keep up with the hardware rate.
build hw_speed_control "-Wa,--defsym,TICK=2000 -Wa,--defsym,SEG_TICKS=150 -Wa,--defsym,LOG_EVERY=10"

# hw_cache_lock's timed code must not share hot_loop's cache line
# index (see the header of sw/hw_cache_lock.s): measure has to end by
# 0x300.
end=$(riscv-none-elf-nm sw/hw_cache_lock.elf | awk '$3 == "measure_end" { print $1 }')
if [ $((16#$end)) -gt $((16#300)) ]; then
    echo "ERROR: hw_cache_lock measure ends at 0x$end, past 0x300"
    exit 1
fi
echo "hw_cache_lock layout OK: measure ends at 0x$end"
