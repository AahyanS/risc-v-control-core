# predictor_measurement.s
# A synthetic but representative "control loop" shape: one tight
# backward branch, executed many times - exactly the pattern
# docs/DESIGN_LOG.md's branch predictor plan is built around measuring, not
# assuming. 1000 iterations: the branch is taken 999 times and
# not-taken exactly once (the loop exit).
#
# Build:
#   riscv-none-elf-gcc -march=rv32i -mabi=ilp32 -nostdlib -nostartfiles \
#     -Ttext=0x0 -o predictor_measurement.elf predictor_measurement.s
#   riscv-none-elf-objcopy -O verilog predictor_measurement.elf predictor_measurement.hex

.section .text
.global _start

_start:
    addi x1, x0, 0        # iteration counter
    addi x2, x0, 1000       # N iterations

loop:
    addi x1, x1, 1            # increment
    blt  x1, x2, loop           # tight backward branch

    addi x30, x0, 768            # results base 0x300
    sw   x1, 0(x30)

done:
    jal x0, done
