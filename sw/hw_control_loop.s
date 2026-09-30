# hw_control_loop.s
# The project's headline measurement: how fast can a real interrupt-
# driven control loop run, in each of the three configurations?
#   1. no cache  - every fetch from flash (cache control bit set)
#   2. cache     - normal cache, nothing locked
#   3. locked    - the interrupt handler's cache lines locked
# One bitstream, one program; only control registers differ between
# the three.
#
# ---- The workload ----
# A timer interrupt fires every PERIOD cycles. The handler reads the
# encoder, runs one PID step (PID_MAC from pid_mac.inc - the same code
# sw/pid_mac_test.c checks against pid.c), writes the motor direction
# and PWM duty, and acknowledges the tick. Between ticks the main
# program runs a "background task": 320 bytes of straight-line code,
# standing in for whatever else a real controller does (communication,
# logging, a second task). It's bigger than the 256-byte cache, so it
# touches every cache line - realistic competing traffic, not an
# artificial worst case.
#
# ---- What's measured, per configuration ----
#   response: cycles from the tick firing to the handler finishing
#             (read from the timer's own count at the end of the
#             handler - the timer restarted from 0 when it fired).
#             min / mean / max over WINDOW ticks at a relaxed period
#             (P_REF) where every configuration keeps up.
#   max rate: the shortest period with zero missed deadlines, found by
#             binary search. A deadline is missed when the next tick
#             has already fired by the time the handler finishes.
#   background: iterations of the background task completed during
#             the P_REF window - what the configuration leaves for
#             everything else.
# Printed over the UART (115200 8N1), one line per configuration,
# repeating. LD15-LD0 show the round number.
#
# ---- Register convention ----
# The handler saves nothing, so it owns registers the rest of the
# program never writes while ticks are enabled:
#   gp (x3)   MMIO base 0xFFFFFF00         (constant; main reads it too)
#   tp (x4)   control-loop state in dmem   (constant)
#   x18 integral    x19 prev_error
#   x20 max  x21 sum  x22 tick count  x23 missed deadlines  x24 min
#   x25-x31 scratch
# Main uses ra, sp (as a scratch register), t0-t2, s0-s1, a0-a7.
#
# Build: bash fpga/build_programs.sh

.option arch, +zicsr                 # CSR instructions (interrupt setup)
.include "pid_mac.inc"

.ifndef WINDOW_SHIFT
.equ WINDOW_SHIFT, 8                 # 256 ticks per window
.endif
.equ WINDOW, 1 << WINDOW_SHIFT
.ifndef SEARCH_SHIFT
.equ SEARCH_SHIFT, 6                 # stop when hi-lo <= hi/64 (~1.6%)
.endif
.equ P_REF, 50000                    # relaxed period: 500 Hz at 25 MHz
.equ CLK_HZ, 25000000
.equ LIM, 1000                       # output limit, PWM duty units

# Control-loop state (tp) and main's results area, in dmem.
.equ STATE, 0x100
.equ S_SETPOINT, 28
.equ S_TARGET, 32                    # tick count that ends a window
.equ R_MIN, 0x200
.equ R_MEAN, 0x204
.equ R_MAX, 0x208
.equ R_BG, 0x20C
.equ R_MISS, 0x210
.equ R_LO, 0x218
.equ R_HI, 0x21C
.equ R_MID, 0x220

# MMIO offsets from gp.
.equ M_LOCK, 0x00
.equ M_ENC, 0x10
.equ M_PWM, 0x18
.equ M_TCMP, 0x1C
.equ M_TACK, 0x20
.equ M_TCOUNT, 0x24
.equ M_LED, 0x28
.equ M_DIR, 0x2C
.equ M_UART, 0x30
.equ M_CACHE, 0x34

.macro PUTC c
    addi a0, x0, \c
    jal  ra, putc
.endm

.section .text
.global _start

_start:
    jal  x0, main

# ======================= The control loop =======================
# Aligned to a cache line, so locking isr..isr_end covers exactly the
# lines it occupies.

    .balign 16
isr:
    sw   x0, M_TACK(gp)              # acknowledge the tick
    lw   x25, M_ENC(gp)              # encoder position, counts
    slli x25, x25, 16                # -> Q16.16
    lw   x26, S_SETPOINT(tp)
    sub  x26, x26, x25               # error
    PID_MAC x26, x18, x19, x29, x30, x27, x28, tp
    srai x30, x29, 31                # 0 or -1: sign of the output
    sw   x30, M_DIR(gp)              # direction (bit 0)
    xor  x29, x29, x30
    sub  x29, x29, x30               # |output|
    srli x29, x29, 16                # integer duty
    sw   x29, M_PWM(gp)
    # ---- instrumentation ----
    lw   x31, M_TCOUNT(gp)           # response: cycles since the tick
    lw   x30, M_TACK(gp)             # 1 if the next tick already fired
    add  x23, x23, x30               #   = missed deadline
    add  x21, x21, x31
    bgeu x20, x31, 1f
    addi x20, x31, 0                 # new max
1:  bgeu x31, x24, 2f
    addi x24, x31, 0                 # new min
2:  addi x22, x22, 1
    lw   x30, S_TARGET(tp)
    bne  x22, x30, 3f
    csrrw x0, mie, x0                # window complete: stop taking ticks
3:  mret
isr_end:

# ======================= main =======================

main:
    addi gp, x0, -256                # 0xFFFFFF00
    addi tp, x0, STATE

    # Gains: kp 2.0, ki ~0.05, kd 0.5; output limited to +-LIM duty.
    lui  t0, 0x20
    sw   t0, 0(tp)
    li   t0, 0x0CCC
    sw   t0, 4(tp)
    lui  t0, 0x8
    sw   t0, 8(tp)
    li   t0, -(LIM << 16)
    sw   t0, 20(tp)
    li   t0, LIM << 16
    sw   t0, 24(tp)

    la    t0, isr
    csrrw x0, mtvec, t0
    csrrw x0, mie, x0
    addi  s1, x0, 0                  # round number

round:
    addi s1, s1, 1
    sw   s1, M_LED(gp)
    PUTC '-'
    PUTC '-'
    PUTC ' '
    PUTC 'r'
    PUTC 'o'
    PUTC 'u'
    PUTC 'n'
    PUTC 'd'
    PUTC ' '
    addi a0, s1, 0
    jal  ra, print_dec
    PUTC 13
    PUTC 10

    addi s0, x0, 0                   # configuration 0, 1, 2
config:
    jal  ra, setup_config
    jal  ra, measure
    jal  ra, report
    addi s0, s0, 1
    addi t0, x0, 3
    bne  s0, t0, config
    jal  x0, round

# ---------------- setup_config: cache mode for configuration s0 ----------------

setup_config:
    addi sp, ra, 0
    sltiu t0, s0, 1                  # config 0: cache off
    sw   t0, M_CACHE(gp)

    # Unlock the handler's lines (configs 0 and 1 run unlocked).
    la   a0, isr
    la   a1, isr_end
1:  sw   a0, M_LOCK(gp)              # bit 31 clear = unlock
    addi a0, a0, 16
    bltu a0, a1, 1b

    addi t0, x0, 2
    bne  s0, t0, 3f

    # Config 2: lock (reserve) every line of the handler, then run each
    # of its paths once so every line is filled before measuring.
    la   a0, isr
    la   a1, isr_end
    lui  t1, 0x80000
2:  or   t0, a0, t1                  # bit 31 set = lock
    sw   t0, M_LOCK(gp)
    addi a0, a0, 16
    bltu a0, a1, 2b
    jal  ra, warm_isr
3:  addi ra, sp, 0
    ret

# ---------------- warm_isr: run every path of the handler once ----------------
# Calls the handler as a subroutine: mepc = where mret should return.
# Five calls cover every instruction: in range; clamped high and low
# with the integral update discarded; clamped high and low with it
# kept; the last call also ends a (fake) window, executing the mie
# write. Ticks are off (mie = 0) throughout.

.macro WARM_CASE delta, integral
    lw   t0, M_ENC(gp)
    slli t0, t0, 16
    li   t1, \delta
    add  t0, t0, t1
    sw   t0, S_SETPOINT(tp)          # setpoint = measured + delta
    li   x18, \integral
    addi x19, x0, 0
    la   t0, 9f
    csrrw x0, mepc, t0
    jal  x0, isr
9:
.endm

warm_isr:
    addi a6, ra, 0
    addi t0, x0, 5
    sw   t0, S_TARGET(tp)            # the 5th call completes the "window"
    addi x22, x0, 0
    addi x20, x0, 0
    addi x24, x0, -1
    WARM_CASE 0, 0                               # in range
    WARM_CASE (2000 << 16), 0                    # high, error > 0: discard
    WARM_CASE -(2000 << 16), 0                   # low, error < 0: discard
    WARM_CASE -1, (30000 << 16)                  # high, error < 0: keep
    WARM_CASE 1, -(30000 << 16)                  # low, error > 0: keep
    addi ra, a6, 0
    ret

# ---------------- window: run WINDOW ticks at period a0 ----------------
# Returns a2 = background iterations completed. Stats land in x20-x24.

window:
    csrrw x0, mie, x0
    addi x18, x0, 0                  # fresh controller state
    addi x19, x0, 0
    addi x20, x0, 0
    addi x21, x0, 0
    addi x22, x0, 0
    addi x23, x0, 0
    addi x24, x0, -1
    sw   x0, S_SETPOINT(tp)
    addi t0, x0, WINDOW
    sw   t0, S_TARGET(tp)
    addi t0, a0, -1
    sw   t0, M_TCMP(gp)              # tick every a0 cycles; restarts the count
    sw   x0, M_TACK(gp)              # drop any stale tick
    addi t0, x0, 8
    csrrs x0, mstatus, t0            # global interrupt enable
    addi a2, x0, 0
    addi t1, x0, WINDOW
    addi t0, x0, 0x80
    csrrw x0, mie, t0                # timer interrupt on: go
bg:
    # Background task: 80 instructions, 320 bytes, straight-line.
    .rept 40
    add  a5, a5, a6
    xor  a6, a6, a5
    .endr
    addi a2, a2, 1
    bne  x22, t1, bg
    ret

# ---------------- measure: response stats, then the rate search ----------------

measure:
    addi a7, ra, 0

    li   a0, P_REF
    jal  ra, window
    sw   x24, R_MIN(x0)
    srli t0, x21, WINDOW_SHIFT
    sw   t0, R_MEAN(x0)
    sw   x20, R_MAX(x0)
    sw   a2, R_BG(x0)
    sw   x23, R_MISS(x0)

    # Binary search for the shortest period with no missed deadlines:
    # lo always fails (or is 0), hi always passes.
    sw   x0, R_LO(x0)
    li   t0, P_REF
    sw   t0, R_HI(x0)
search:
    lw   a0, R_LO(x0)
    lw   a1, R_HI(x0)
    sub  t0, a1, a0
    srli t1, a1, SEARCH_SHIFT
    bgeu t1, t0, search_done
    add  a0, a0, a1
    srli a0, a0, 1
    sw   a0, R_MID(x0)
    jal  ra, window
    lw   a0, R_MID(x0)
    bne  x23, x0, 1f
    sw   a0, R_HI(x0)
    jal  x0, search
1:  sw   a0, R_LO(x0)
    jal  x0, search
search_done:
    addi ra, a7, 0
    ret

# ---------------- report: one line for configuration s0 ----------------
# "locked: response min 88 mean 90 max 93 cycles, max rate 211864 Hz
#  (period 118), background 1234"

report:
    addi sp, ra, 0
    bne  s0, x0, 1f
    PUTC 'n'
    PUTC 'o'
    PUTC ' '
    PUTC 'c'
    PUTC 'a'
    PUTC 'c'
    PUTC 'h'
    PUTC 'e'
    jal  x0, 3f
1:  addi t0, x0, 1
    bne  s0, t0, 2f
    PUTC 'c'
    PUTC 'a'
    PUTC 'c'
    PUTC 'h'
    PUTC 'e'
    jal  x0, 3f
2:  PUTC 'l'
    PUTC 'o'
    PUTC 'c'
    PUTC 'k'
    PUTC 'e'
    PUTC 'd'
3:  PUTC ':'
    PUTC ' '
    PUTC 'r'
    PUTC 'e'
    PUTC 's'
    PUTC 'p'
    PUTC 'o'
    PUTC 'n'
    PUTC 's'
    PUTC 'e'
    PUTC ' '
    PUTC 'm'
    PUTC 'i'
    PUTC 'n'
    PUTC ' '
    lw   a0, R_MIN(x0)
    jal  ra, print_dec
    PUTC ' '
    PUTC 'm'
    PUTC 'e'
    PUTC 'a'
    PUTC 'n'
    PUTC ' '
    lw   a0, R_MEAN(x0)
    jal  ra, print_dec
    PUTC ' '
    PUTC 'm'
    PUTC 'a'
    PUTC 'x'
    PUTC ' '
    lw   a0, R_MAX(x0)
    jal  ra, print_dec
    PUTC ' '
    PUTC 'c'
    PUTC 'y'
    PUTC 'c'
    PUTC 'l'
    PUTC 'e'
    PUTC 's'
    lw   t0, R_MISS(x0)              # the P_REF window itself missed?
    beq  t0, x0, 4f
    PUTC ' '
    PUTC '('
    PUTC 'm'
    PUTC 'i'
    PUTC 's'
    PUTC 's'
    PUTC 'e'
    PUTC 'd'
    PUTC ' '
    lw   a0, R_MISS(x0)
    jal  ra, print_dec
    PUTC ')'
4:  PUTC ','
    PUTC ' '
    PUTC 'm'
    PUTC 'a'
    PUTC 'x'
    PUTC ' '
    PUTC 'r'
    PUTC 'a'
    PUTC 't'
    PUTC 'e'
    PUTC ' '
    li   a0, CLK_HZ
    lw   a1, R_HI(x0)
    jal  ra, udiv
    jal  ra, print_dec
    PUTC ' '
    PUTC 'H'
    PUTC 'z'
    PUTC ' '
    PUTC '('
    PUTC 'p'
    PUTC 'e'
    PUTC 'r'
    PUTC 'i'
    PUTC 'o'
    PUTC 'd'
    PUTC ' '
    lw   a0, R_HI(x0)
    jal  ra, print_dec
    PUTC ')'
    PUTC ','
    PUTC ' '
    PUTC 'b'
    PUTC 'a'
    PUTC 'c'
    PUTC 'k'
    PUTC 'g'
    PUTC 'r'
    PUTC 'o'
    PUTC 'u'
    PUTC 'n'
    PUTC 'd'
    PUTC ' '
    lw   a0, R_BG(x0)
    jal  ra, print_dec
    PUTC 13
    PUTC 10
    addi ra, sp, 0
    ret

# ---------------- putc: send a0[7:0] over the UART ----------------
# Waits until the transmitter is free (busy = bit 0). Uses t0 only.

putc:
    lw   t0, M_UART(gp)
    andi t0, t0, 1
    bne  t0, x0, putc
    sw   a0, M_UART(gp)
    ret

# ---------------- print_dec: a0 as unsigned decimal ----------------
# Repeated subtraction per power of ten (RV32I has no divide).
# Uses a4, a5, t1, t2, a3 (saved ra).

print_dec:
    addi a3, ra, 0
    addi a4, a0, 0
    addi a5, x0, 0                   # set once a digit is printed
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
    addi a5, x0, 1                   # ones digit always prints
    addi t2, x0, 1
    jal  ra, digit
    addi ra, a3, 0
    ret

digit:
    addi a0, x0, '0'
d_loop:
    bltu a4, t2, d_done
    sub  a4, a4, t2
    addi a0, a0, 1
    jal  x0, d_loop
d_done:
    addi t1, x0, '0'
    bne  a0, t1, d_print
    beq  a5, x0, d_ret               # leading zero: skip
d_print:
    addi a5, x0, 1
    jal  x0, putc                    # tail call
d_ret:
    ret

# ---------------- udiv: a0 = a0 / a1 (unsigned) ----------------
# Shift-and-subtract long division. Uses a2, a4, t1, t2.

udiv:
    addi a2, x0, 0                   # quotient
    addi a4, x0, 0                   # remainder
    addi t1, x0, 32
u_loop:
    slli a4, a4, 1
    srli t2, a0, 31
    or   a4, a4, t2
    slli a0, a0, 1
    slli a2, a2, 1
    bltu a4, a1, u_skip
    sub  a4, a4, a1
    ori  a2, a2, 1
u_skip:
    addi t1, t1, -1
    bne  t1, x0, u_loop
    addi a0, a2, 0
    ret
