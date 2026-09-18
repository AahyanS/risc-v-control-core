# pipeline_hazard_test.s
# Verifies cpu_pipeline.v's forwarding paths and load-use stall.
# Companion to pipeline_test.s, which verifies the control-flow flush
# mechanism in isolation from data hazards - this one deliberately
# does the opposite: every dependency here is as tight as possible.
#
# Build:
#   riscv-none-elf-gcc -march=rv32i -mabi=ilp32 -nostdlib -nostartfiles \
#     -Ttext=0x0 -o pipeline_hazard_test.elf pipeline_hazard_test.s
#   riscv-none-elf-objcopy -O verilog pipeline_hazard_test.elf pipeline_hazard_test.hex

.section .text
.global _start

_start:
    # 0-gap ALU dependency: needs EX/MEM forwarding
    addi x1, x0, 5
    add  x2, x1, x1        # x2 = 5 + 5 = 10, x1 read the instruction right after it's written

    # 1-gap ALU dependency: needs MEM/WB forwarding
    addi x3, x0, 7
    addi x0, x0, 0          # spacer
    add  x4, x3, x3          # x4 = 7 + 7 = 14

    addi x7, x0, 300          # base address for the memory tests below

    # 0-gap store-data forwarding: the value being stored was just computed
    addi x10, x0, 42
    sw   x10, 0(x7)            # mem[300] = 42, x10 forwarded straight into dmem's write_data

    # Load-use hazard: the load's result is consumed by the very next
    # instruction - forwarding alone can't cover this, needs the stall
    lw   x8, 0(x7)
    add  x9, x8, x0             # x9 = 42

    # 1-gap load forwarding: no stall needed, MEM/WB forwarding covers it
    addi x13, x0, 99
    sw   x13, 4(x7)               # mem[304] = 99
    lw   x11, 4(x7)
    addi x0, x0, 0                 # spacer
    add  x12, x11, x0                # x12 = 99

spin:
    jal x0, spin
