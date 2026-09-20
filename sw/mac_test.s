# mac_test.s
# Verifies the custom MAC instruction (mac rd, rs1, rs2: rd = rd +
# rs1*rs2, Q16.16), encoded via GNU as's `.insn r` directive (opcode
# 0x0B = custom-0, funct3=0, funct7=0) since it's not a mnemonic the
# assembler knows.
#
# Three things checked, matching the three real correctness risks in
# this instruction's implementation:
#   1. Basic multiply-accumulate correctness (cross-checked against
#      the same 1.5*2.5=3.75 values pid_test.c's q16_mul test uses).
#   2. Three consecutive MAC instructions accumulating into the SAME
#      rd, each depending on the immediately preceding one's result -
#      the actual use case MAC exists for (Kp*error, Ki*integral,
#      Kd*derivative), and exactly what exercises the new EX-stage
#      forwarding path for the accumulator read.
#   3. A load immediately followed by using that loaded value as MAC's
#      accumulator (rd) - exercises the load-use hazard extension,
#      since MAC reading its own rd as a source is a hazard the
#      original load-use check (only rs1/rs2) didn't cover.
#
# Build:
#   riscv-none-elf-gcc -march=rv32i -mabi=ilp32 -nostdlib -nostartfiles \
#     -Ttext=0x0 -o mac_test.elf mac_test.s
#   riscv-none-elf-objcopy -O verilog mac_test.elf mac_test.hex

.section .text
.global _start

_start:
    # ---- Test 1: basic correctness ----
    addi x1, x0, 0            # accumulator, must start defined
    lui  x2, 0x18               # x2 = 1.5 (Q16.16)
    lui  x3, 0x28                # x3 = 2.5 (Q16.16)
    .insn r 0x0B, 0, 0, x1, x2, x3    # x1 = 0 + 1.5*2.5 = 3.75

    # ---- Test 2: back-to-back accumulation into the same rd ----
    addi x10, x0, 0
    lui  x4, 0x10                # 1.0
    lui  x5, 0x10                 # 1.0
    .insn r 0x0B, 0, 0, x10, x4, x5    # x10 = 0 + 1.0*1.0 = 1.0
    lui  x6, 0x20                  # 2.0
    lui  x7, 0x10                   # 1.0
    .insn r 0x0B, 0, 0, x10, x6, x7    # x10 = 1.0 + 2.0*1.0 = 3.0 (forwarded)
    lui  x8, 0x8                     # 0.5
    lui  x9, 0x20                     # 2.0
    .insn r 0x0B, 0, 0, x10, x8, x9    # x10 = 3.0 + 0.5*2.0 = 4.0 (forwarded again)

    # ---- Test 3: load-use hazard on MAC's accumulator read ----
    addi x20, x0, 512                  # x20 = 0x200, scratch base
    lui  x21, 0x10                      # 1.0
    sw   x21, 100(x20)                   # store 1.0 at 0x264
    lw   x22, 100(x20)                    # load it right back
    lui  x23, 0x20                         # 2.0
    lui  x24, 0x10                          # 1.0
    .insn r 0x0B, 0, 0, x22, x23, x24    # x22 = x22(loaded,1.0) + 2.0*1.0 = 3.0

    addi x30, x0, 768                    # x30 = 0x300, results base
    sw   x1,  0(x30)
    sw   x10, 4(x30)
    sw   x22, 8(x30)

done:
    jal x0, done
