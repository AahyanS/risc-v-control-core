# encoder_test.s
# Reads the quadrature encoder's position/error registers via MMIO,
# then clears position and re-reads to confirm the clear worked. The
# actual encoder transitions are driven by the testbench
# (tb_encoder_test.v) directly on the physical a/b pins, early enough
# (right after reset releases) that they're long done before this
# program's first `lw` actually executes - XIP fetch is slow enough
# (~128 cycles for the first instruction) that this isn't a tight
# race.
#
# Build:
#   riscv-none-elf-gcc -march=rv32i -mabi=ilp32 -nostdlib -nostartfiles \
#     -Ttext=0x0 -o encoder_test.elf encoder_test.s
#   riscv-none-elf-objcopy -O verilog encoder_test.elf encoder_test.hex

.section .text
.global _start

_start:
    addi x10, x0, -240        # x10 = 0xFFFFFF10 (MMIO_ENC_POS_ADDR)
    addi x11, x0, -236        # x11 = 0xFFFFFF14 (MMIO_ENC_ERR_ADDR)
    addi x13, x0, 512         # x13 = 0x200, results base

    lw   x1, 0(x10)            # x1 = encoder position (set by testbench-driven transitions)
    lw   x2, 0(x11)            # x2 = encoder error count (should be 0 - clean transitions)

    sw   x1, 0(x13)
    sw   x2, 4(x13)

    sw   x0, 0(x10)             # write to position register - clears it to 0
    lw   x3, 0(x10)              # re-read - should now be 0
    sw   x3, 8(x13)

spin:
    jal  x0, spin
