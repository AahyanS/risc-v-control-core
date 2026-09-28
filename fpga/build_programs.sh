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
FLAGS="-march=rv32i -mabi=ilp32 -nostdlib -nostartfiles -Ttext=0x0"

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
