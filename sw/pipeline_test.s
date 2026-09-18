# pipeline_test.s
# Verifies cpu_pipeline.v's control-flow flush mechanism in isolation
# from data hazards - every register write is followed by several
# independent instructions before that register is ever read, since
# this first pipeline version has no forwarding yet.
#
# Build:
#   riscv-none-elf-gcc -march=rv32i -mabi=ilp32 -nostdlib -nostartfiles \
#     -Ttext=0x0 -o pipeline_test.elf pipeline_test.s
#   riscv-none-elf-objcopy -O verilog pipeline_test.elf pipeline_test.hex

.section .text
.global _start

_start:
    addi x1, x0, 5        # x1 = 5
    addi x0, x0, 0        # spacer
    addi x0, x0, 0        # spacer
    addi x0, x0, 0        # spacer
    addi x5, x1, 10       # x5 = x1 + 10 = 15 (reads x1, written 4 instrs earlier)
    addi x0, x0, 0
    addi x0, x0, 0
    addi x0, x0, 0

    beq  x0, x0, skip1     # always taken (x0 == x0) - tests taken-branch flush
    addi x7, x0, 999       # must be SKIPPED
skip1:
    addi x8, x0, 111       # branch target - must execute

    addi x0, x0, 0
    addi x0, x0, 0
    addi x0, x0, 0

    bne  x0, x0, neverskip # never taken (x0 == x0 makes BNE false) -
                            # tests that a not-taken branch does NOT
                            # incorrectly flush
    addi x9, x0, 222        # must execute (fall-through)
neverskip:
    addi x10, x0, 333       # must execute either way

    addi x0, x0, 0
    addi x0, x0, 0
    addi x0, x0, 0

    jal  x11, jal_target     # x11 = return address; tests JAL's flush
    addi x12, x0, 444        # must be SKIPPED
jal_target:
    addi x13, x0, 555        # JAL's target - must execute

spin:
    jal  x0, spin             # infinite self-loop (rd=x0: no link saved)
