# pwm_test.s
# Sets the PWM duty cycle via MMIO, then reads it back to confirm the
# write stuck. tb_pwm_test.v observes the actual physical pwm_out pin
# over a full PWM period afterward to confirm the hardware waveform
# matches what software programmed - not just that the register holds
# the value.
#
# Build:
#   riscv-none-elf-gcc -march=rv32i -mabi=ilp32 -nostdlib -nostartfiles \
#     -Ttext=0x0 -o pwm_test.elf pwm_test.s
#   riscv-none-elf-objcopy -O verilog pwm_test.elf pwm_test.hex

.section .text
.global _start

_start:
    addi x10, x0, -232        # x10 = 0xFFFFFF18 (MMIO_PWM_ADDR)
    addi x1, x0, 256           # duty_cycle = 256 (25% of the 1024-cycle period)
    sw   x1, 0(x10)
    lw   x2, 0(x10)             # read back - confirm it stuck

    addi x13, x0, 512            # x13 = 0x200, results base
    sw   x2, 0(x13)

spin:
    jal  x0, spin
