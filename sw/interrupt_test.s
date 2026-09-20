# interrupt_test.s
# Sets up the timer interrupt (mtvec/mie/mstatus, timer compare via
# MMIO), then spins doing "background work" (incrementing x1) while
# the timer periodically interrupts, runs a handler that acknowledges
# it and counts invocations, and returns via mret - until 5
# interrupts have been serviced, proving the interrupt fires
# PERIODICALLY (not just once) and execution correctly resumes each
# time.
#
# RISC-V doesn't save/restore general-purpose registers on trap entry
# automatically - only mepc/mstatus are hardware-saved. A real,
# general-purpose ISR needs to spill/restore anything it clobbers
# (typically via the stack). This test sidesteps that complexity with
# a simpler, legitimate convention for a small, fixed-purpose
# handler: x28 is reserved exclusively for the ISR (the main loop
# never reads or writes it), so the handler never needs to save
# anything - there's nothing shared to corrupt.
#
# Build:
#   riscv-none-elf-gcc -march=rv32i -mabi=ilp32 -nostdlib -nostartfiles \
#     -Ttext=0x0 -o interrupt_test.elf interrupt_test.s
#   riscv-none-elf-objcopy -O verilog interrupt_test.elf interrupt_test.hex

.section .text
.global _start

_start:
    addi x1,  x0, 0        # background work counter - must start
                             # defined (accumulated onto below), not
                             # whatever regfile's undefined reset
                             # value is
    addi x28, x0, 0          # ISR invocation counter (ISR-only register)

    la    x5, handler          # mtvec = address of the trap handler
    csrrw x0, mtvec, x5

    addi  x5, x0, 0x80          # mie.MTIE (bit 7) = 1
    csrrw x0, mie, x5

    addi  x10, x0, -228          # x10 = 0xFFFFFF1C (MMIO_TIMER_CMP_ADDR)
    addi  x6,  x0, 200            # fires every 200 cycles
    sw    x6, 0(x10)

    addi  x5, x0, 0x08            # mstatus.MIE (bit 3) = 1 - enabling
    csrrs x0, mstatus, x5           # global interrupts LAST, after
                                      # mtvec/mie are already configured

    addi  x7, x0, 5                  # wait for 5 interrupts
main_loop:
    addi  x1, x1, 1                   # background work
    blt   x28, x7, main_loop

    addi x11, x0, 768                  # x11 = 0x300, results base
    sw   x1,  0(x11)                    # background work counter
    sw   x28, 4(x11)                     # ISR invocation count

done:
    jal x0, done

    .align 4
handler:
    addi x29, x0, -224          # x29 = 0xFFFFFF20 (MMIO_TIMER_ACK_ADDR)
    sw   x0, 0(x29)               # acknowledge - clears the timer's pending flag
    addi x28, x28, 1               # ISR invocation counter
    mret
