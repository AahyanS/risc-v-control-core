# mac_benchmark.s
# Times the core repeated operation in a PID loop -
# output = Kp*error + Ki*integral + Kd*derivative - using the
# hardware MAC instruction, three times accumulating into the same
# register. Companion to sw/software_mac_benchmark.c, which times the
# identical computation (same values) using the software q16_mul
# routine pid.c already uses - same workload, only the multiply
# mechanism differs, for a direct cycles-per-iteration comparison.
#
# Build:
#   riscv-none-elf-gcc -march=rv32i -mabi=ilp32 -nostdlib -nostartfiles \
#     -Ttext=0x0 -o mac_benchmark.elf mac_benchmark.s
#   riscv-none-elf-objcopy -O verilog mac_benchmark.elf mac_benchmark.hex

.section .text
.global _start

_start:
    addi x10, x0, -252        # x10 = 0xFFFFFF04 (MMIO_CYCLE_ADDR)
    sw   x0, 0(x10)             # reset cycle counter

    lw   x11, 0(x10)             # t_start

    addi x1, x0, 0                 # output accumulator
    lui  x2, 0x8                    # Kp = 0.5
    lui  x3, 0x10                    # error = 1.0
    .insn r 0x0B, 0, 0, x1, x2, x3     # output += Kp*error

    lui  x4, 0x4                        # Ki = 0.25
    lui  x5, 0x20                        # integral = 2.0
    .insn r 0x0B, 0, 0, x1, x4, x5         # output += Ki*integral

    lui  x6, 0x2                            # Kd = 0.125
    lui  x7, 0x10                            # derivative = 1.0
    .insn r 0x0B, 0, 0, x1, x6, x7             # output += Kd*derivative

    lw   x12, 0(x10)                             # t_end
    sub  x13, x12, x11                            # cycles taken

    addi x30, x0, 768                              # results base 0x300
    sw   x1,  0(x30)                                # PID output
    sw   x13, 4(x30)                                 # cycle count

done:
    jal x0, done
