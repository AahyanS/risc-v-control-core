# pipeline_predictor_test.s
# Verifies the branch predictor actually predicts, not just that the
# core stays correct with one installed. A loop with 7 executions of
# the same backward branch: 6 taken (i=2..7), then 1 not-taken (the
# exit, i=8). Starting from bht's default "weakly not-taken" state:
#   exec1 (taken):     predicted not-taken -> mispredict (flush)
#   exec2 (taken):     predicted taken (after exec1's update) -> correct, no flush
#   exec3-6 (taken):   predicted taken (saturated) -> correct, no flush
#   exec7 (not-taken): predicted taken (still saturated) -> mispredict (flush)
# So exactly 2 flushes across 7 branch executions, versus 6 under the
# old "always predict not-taken" policy (which flushed every taken
# branch) - a real, measurable improvement, not just "still correct."
#
# Build:
#   riscv-none-elf-gcc -march=rv32i -mabi=ilp32 -nostdlib -nostartfiles \
#     -Ttext=0x0 -o pipeline_predictor_test.elf pipeline_predictor_test.s
#   riscv-none-elf-objcopy -O verilog pipeline_predictor_test.elf pipeline_predictor_test.hex

.section .text
.global _start

_start:
    addi x1, x0, 0     # sum
    addi x2, x0, 1     # i
    addi x3, x0, 8      # limit
loop:
    add  x1, x1, x2       # sum += i
    addi x2, x2, 1          # i++
    blt  x2, x3, loop         # repeat while i < 8
    addi x4, x0, 999           # after-loop marker

spin:
    jal x0, spin
