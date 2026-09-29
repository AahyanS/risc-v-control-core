# hw_cache_lock.s
# The project's headline experiment, on real hardware: does locking a
# cache line make a "hot path" immune to competing memory traffic?
# Same experiment as interference_unlocked_test.s and
# interference_locked_test.s (see those for the full reasoning), but
# both halves run in one program on one core - the unlocked half just
# leaves the lock bit clear - and the results are printed over the
# UART instead of being read out of registers by a testbench.
#
# Once a second it prints a line like:
#   run 1: unlocked 531-531 cycles, locked 10-10 cycles
# (min-max over 5 timed calls to hot_loop, each followed by a call to
# interference, which aliases to the same cache line). LD15-LD0 show
# the run count, so the CPU is visibly alive even with no terminal
# open. Serial settings: 115200 baud, 8N1.
#
# ---- Why the layout below matters ----
# The cache is 16 lines x 16 bytes; the line index is addr[7:4].
# hot_loop sits at 0x100 (index 0) and interference at 0x200 (index 0,
# different tag), so they fight over one line. Everything that runs
# inside the timed window - the measure routine - must NOT share index
# 0, or locking hot_loop's line would make the measuring code itself
# uncacheable and inflate the locked numbers. measure lives at 0x210
# onward and must end by 0x300; fpga/build_programs.sh checks this
# from the linked addresses. Code after that (printing, delay) may alias -
# it only gets slower, and it's not timed.
#
# No strings in memory: dmem starts empty and loads can't read flash,
# so text is sent one character at a time from immediates (PUTC).
# (A GAS .irpc loop can't generate the character constants: it doesn't
# substitute inside 'x literals, so every letter came out as the loop
# variable's own name - caught by the board simulation.)
#
# Build: bash fpga/build_programs.sh

.ifndef DELAY
.equ DELAY, 8000000          # ~1 s between runs at 25 MHz
.endif

.macro PUTC c
    addi a0, x0, \c
    jal  ra, putc
.endm

.section .text
.global _start

_start:
    jal  x0, main

# ---------------- The contested cache line ----------------

    .balign 256
hot_loop:                        # 0x100 - line index 0
    addi a6, a6, 1               # trivial "hot path" work
    jalr x0, 0(x6)

    .balign 256
interference:                    # 0x200 - line index 0, different tag
    addi a7, a7, 1               # trivial "competing" work
    jalr x0, 0(x6)

# ---------------- measure: time hot_loop under interference ----------------
# Returns a0 = min, a1 = max cycles over passes 1-5. Pass 0 is a
# warm-up (the measure loop's own lines may be cold) and is excluded,
# exactly as in the simulation tests. Link for hot_loop/interference
# is x6, so ra is untouched.

    .balign 16
measure:                         # 0x210 - line index 1
    addi t3, x0, -252            # 0xFFFFFF04 cycle counter
    lui  a0, 0x80000             # min = 0x7FFFFFFF
    addi a0, a0, -1
    addi a1, x0, 0               # max
    addi a2, x0, 0               # pass index
    addi a3, x0, 6               # 1 warm-up + 5 timed passes
m_loop:
    lw   t4, 0(t3)               # t_start
    jal  x6, hot_loop
    lw   t5, 0(t3)               # t_end
    sub  t5, t5, t4
    beq  a2, x0, m_skip          # pass 0: warm-up, not recorded
    bge  t5, a0, m_nomin
    addi a0, t5, 0
m_nomin:
    bge  a1, t5, m_skip
    addi a1, t5, 0
m_skip:
    jal  x6, interference        # evicts hot_loop - unless it's locked
    addi a2, a2, 1
    blt  a2, a3, m_loop
    jalr x0, 0(ra)
measure_end:

# ---------------- main ----------------

main:
    addi s0, x0, -208            # 0xFFFFFF30 UART
    addi s1, x0, -256            # 0xFFFFFF00 cache lock control
    addi s3, x0, -216            # 0xFFFFFF28 LEDs
    la   s2, hot_loop
    addi s4, x0, 0               # run count

run:
    addi s4, s4, 1
    sw   s4, 0(s3)               # LEDs = run count

    # Unlocked: clear hot_loop's lock bit (store value bit 31 = 0).
    sw   s2, 0(s1)
    jal  ra, measure
    addi s5, a0, 0
    addi s6, a1, 0

    # Locked: warm hot_loop's line first (interference just evicted
    # it; locking only protects a line that's already resident), then
    # set the lock bit.
    jal  x6, hot_loop
    lui  t0, 0x80000
    or   t0, s2, t0
    sw   t0, 0(s1)
    jal  ra, measure
    addi s7, a0, 0
    addi s8, a1, 0

    # "run N: unlocked MIN-MAX cycles, locked MIN-MAX cycles\r\n"
    PUTC 'r'
    PUTC 'u'
    PUTC 'n'
    PUTC ' '
    addi a0, s4, 0
    jal  ra, print_dec
    PUTC ':'
    PUTC ' '
    PUTC 'u'
    PUTC 'n'
    PUTC 'l'
    PUTC 'o'
    PUTC 'c'
    PUTC 'k'
    PUTC 'e'
    PUTC 'd'
    PUTC ' '
    addi a0, s5, 0
    jal  ra, print_dec
    PUTC '-'
    addi a0, s6, 0
    jal  ra, print_dec
    jal  ra, print_cycles
    PUTC ','
    PUTC ' '
    PUTC 'l'
    PUTC 'o'
    PUTC 'c'
    PUTC 'k'
    PUTC 'e'
    PUTC 'd'
    PUTC ' '
    addi a0, s7, 0
    jal  ra, print_dec
    PUTC '-'
    addi a0, s8, 0
    jal  ra, print_dec
    jal  ra, print_cycles
    PUTC 13
    PUTC 10

    li   t0, DELAY
delay:
    addi t0, t0, -1
    bne  t0, x0, delay
    jal  x0, run

# ---------------- putc: send a0[7:0] over the UART ----------------
# Waits for the transmitter to finish the previous byte (busy = bit 0
# of a load from 0xFFFFFF30), then stores the new one. Uses t0 only.

putc:
    lw   t0, 0(s0)
    andi t0, t0, 1
    bne  t0, x0, putc
    sw   a0, 0(s0)
    jalr x0, 0(ra)

# ---------------- print_cycles: " cycles" ----------------
# ra is saved in t6 because each PUTC overwrites it.

print_cycles:
    addi t6, ra, 0
    PUTC ' '
    PUTC 'c'
    PUTC 'y'
    PUTC 'c'
    PUTC 'l'
    PUTC 'e'
    PUTC 's'
    jalr x0, 0(t6)

# ---------------- print_dec: a0 as unsigned decimal ----------------
# RV32I has no divide, so each digit is found by repeated subtraction
# of its power of ten (at most 9 subtractions per digit). Leading
# zeros are suppressed; the ones digit always prints. Uses a4, a5,
# t2, t3, t6 (ra is saved in t6 because digit/putc overwrite it).

print_dec:
    addi t6, ra, 0
    addi a4, a0, 0               # value still to print
    addi a5, x0, 0               # set once a nonzero digit is printed
    li   t2, 1000000000
    jal  ra, digit
    li   t2, 100000000
    jal  ra, digit
    li   t2, 10000000
    jal  ra, digit
    li   t2, 1000000
    jal  ra, digit
    li   t2, 100000
    jal  ra, digit
    li   t2, 10000
    jal  ra, digit
    li   t2, 1000
    jal  ra, digit
    li   t2, 100
    jal  ra, digit
    li   t2, 10
    jal  ra, digit
    addi a5, x0, 1               # always print the ones digit
    addi t2, x0, 1
    jal  ra, digit
    jalr x0, 0(t6)

digit:                           # prints the t2-place digit of a4
    addi a0, x0, '0'
d_loop:
    bltu a4, t2, d_done
    sub  a4, a4, t2
    addi a0, a0, 1
    jal  x0, d_loop
d_done:
    addi t3, x0, '0'
    bne  a0, t3, d_print
    beq  a5, x0, d_ret           # leading zero: skip
d_print:
    addi a5, x0, 1
    jal  x0, putc                # tail call: putc returns to digit's caller
d_ret:
    jalr x0, 0(ra)
