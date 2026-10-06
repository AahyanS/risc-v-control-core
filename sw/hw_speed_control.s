# hw_speed_control.s
# Closed-loop speed control of the motor: a 1 kHz timer interrupt
# measures speed from the encoder and runs a PI step (PID_MAC from
# pid_mac.inc, Kd = 0) to set the H-bridge direction and PWM duty. The
# handler's cache lines are locked, so it runs in a fixed, short time.
# The main program steps the setpoint through a schedule and logs the
# response over the UART as CSV:
#   ms,setpoint,speed,duty
# (115200 8N1; one line every LOG_EVERY ticks), ready to plot.
#
# ---- Speed measurement ----
# The encoder runs in single-channel mode (quad_decoder.v): B edges
# only, sign taken from the commanded direction, because this project's
# encoder lost its A channel. That's ~300 counts per output-shaft turn,
# so at full speed (~625 RPM no-load at 6 V) one 1 ms tick sees only
# ~3 counts - too coarse to control. Speed is instead the position
# change over the last WIN = 16 ticks (a 16-entry ring buffer in dmem):
# ~50 counts at full speed, ~2% resolution, still updated every tick.
# Units: counts per 16 ms. The cost is lag - it's a 16-tick moving
# average, about 8 ms of effective delay, which the gains allow for.
#
# ---- Setpoint schedule ----
# SEG_TICKS per segment (2 s): 0, 20, 35, 10, -20, 0, repeating. The
# -20 step reverses the motor - the case single-channel counting is
# weakest at (a shaft still coasting forward right after the direction
# flips is counted as reverse).
#
# ---- Safety ----
# SW15 must be up for the motor to move at all (basys3_top.v), and
# motor_dir_guard.v enforces the H-bridge's disable-before-reversing
# rule in hardware, so a controller output flipping sign can't short
# the bridge.
#
# ---- Register convention (same as hw_control_loop.s) ----
# Handler-only: gp MMIO base, tp state, x18 integral, x19 prev_error,
# x20 ring offset, x21 speed, x22 tick count, x23 last output (Q16.16),
# x25-x31 scratch. Main reads x21-x23 but never writes them while
# ticks are on. Main uses ra, sp, t0-t2, s0-s1, a0-a7.
#
# Build: bash fpga/build_programs.sh

.option arch, +zicsr
.include "pid_mac.inc"

.ifndef TICK
.equ TICK, 25000                     # cycles per control tick: 1 kHz at 25 MHz
.endif
.ifndef SEG_TICKS
.equ SEG_TICKS, 2000                 # 2 s per setpoint segment
.endif
.ifndef LOG_EVERY
.equ LOG_EVERY, 10                   # log every 10 ms
.endif

.equ STATE, 0x100
.equ S_SETPOINT, 28                  # Q16.16, counts per 16 ticks
.equ RING, 0x400                     # 16 past positions

.equ M_LOCK, 0x00
.equ M_ENC, 0x10
.equ M_PWM, 0x18
.equ M_TCMP, 0x1C
.equ M_TACK, 0x20
.equ M_LED, 0x28
.equ M_DIR, 0x2C
.equ M_UART, 0x30
.equ M_ENC_MODE, 0x38

.macro PUTC c
    addi a0, x0, \c
    jal  ra, putc
.endm

.section .text
.global _start

_start:
    jal  x0, main

# ======================= The control loop =======================

    .balign 16
isr:
    sw   x0, M_TACK(gp)              # acknowledge the tick
    lw   x25, M_ENC(gp)              # position now
    lw   x27, RING(x20)              # position WIN ticks ago
    sw   x25, RING(x20)
    addi x20, x20, 4
    andi x20, x20, 63                # 16 entries
    sub  x21, x25, x27               # speed, counts per 16 ticks
    slli x25, x21, 16                # -> Q16.16
    lw   x26, S_SETPOINT(tp)
    sub  x26, x26, x25               # error
    PID_MAC x26, x18, x19, x29, x30, x27, x28, tp
    addi x23, x29, 0                 # for the log
    srai x30, x29, 31                # 0 or -1: sign of the output
    sw   x30, M_DIR(gp)              # direction (bit 0)
    xor  x29, x29, x30
    sub  x29, x29, x30               # |output|
    srli x29, x29, 16                # integer duty, 0..1023
    sw   x29, M_PWM(gp)
    addi x22, x22, 1
    mret
isr_end:

# ======================= main =======================

main:
    addi gp, x0, -256                # 0xFFFFFF00
    addi tp, x0, STATE

    # PI gains, in duty units per (count per 16 ms): kp 25, ki 1.25, kd 0.
    # Output limited to +-1023 (the PWM period is 1024 cycles).
    # From SIMC tuning of a first-order motor model: plant gain
    # K = 50/1024 counts per duty unit (full speed ~50), time constant
    # tau 15-30 ms (a guess for this gearmotor), and ~8 ms of delay from
    # the 16-tick speed average; with the closed-loop time constant set
    # equal to that delay, ki = 1/(K*16) ~ 1.28 per tick independent of
    # tau, and kp = tau/(K*16) = 19-38, so 25 sits in the middle. A first
    # try at kp 12 / ki 0.4 was stable but took ~130 ms to settle.
    lui  t0, 0x190                   # 25.0
    sw   t0, 0(tp)
    lui  t0, 0x14                    # 1.25
    sw   t0, 4(tp)
    sw   x0, 8(tp)
    li   t0, -(1023 << 16)
    sw   t0, 20(tp)
    li   t0, 1023 << 16
    sw   t0, 24(tp)
    sw   x0, S_SETPOINT(tp)

    addi t0, x0, 1
    sw   t0, M_ENC_MODE(gp)          # single-channel encoder counting

    # Controller and ring buffer start clean.
    addi x18, x0, 0
    addi x19, x0, 0
    addi x20, x0, 0
    addi x21, x0, 0
    addi x22, x0, 0
    addi x23, x0, 0
    addi t0, x0, RING
    addi t1, x0, RING + 64
1:  sw   x0, 0(t0)
    addi t0, t0, 4
    bltu t0, t1, 1b
    sw   x0, M_ENC(gp)               # position = 0 (store clears it)

    # Lock the handler's lines (a lock reserves them for its addresses;
    # the first tick fills them).
    la   a0, isr
    la   a1, isr_end
    lui  t1, 0x80000
2:  or   t0, a0, t1
    sw   t0, M_LOCK(gp)
    addi a0, a0, 16
    bltu a0, a1, 2b

    PUTC 'm'
    PUTC 's'
    PUTC ','
    PUTC 's'
    PUTC 'e'
    PUTC 't'
    PUTC 'p'
    PUTC 'o'
    PUTC 'i'
    PUTC 'n'
    PUTC 't'
    PUTC ','
    PUTC 's'
    PUTC 'p'
    PUTC 'e'
    PUTC 'e'
    PUTC 'd'
    PUTC ','
    PUTC 'd'
    PUTC 'u'
    PUTC 't'
    PUTC 'y'
    PUTC 13
    PUTC 10

    # Start ticking.
    la    t0, isr
    csrrw x0, mtvec, t0
    li    t0, TICK - 1
    sw    t0, M_TCMP(gp)
    sw    x0, M_TACK(gp)
    addi  t0, x0, 0x80
    csrrw x0, mie, t0
    addi  t0, x0, 8
    csrrs x0, mstatus, t0

    addi s0, x0, 0                   # segment number, 0..5
    li   s1, SEG_TICKS               # tick at which the next segment starts
    addi a6, x0, LOG_EVERY           # tick of the next log line
    jal  ra, set_segment

loop:
    bltu x22, s1, 3f                 # time for the next segment?
    addi s0, s0, 1
    addi t0, x0, 6
    bne  s0, t0, 4f
    addi s0, x0, 0
4:  li   t0, SEG_TICKS
    add  s1, s1, t0
    jal  ra, set_segment
3:  bltu x22, a6, loop               # time for a log line?
    addi a6, a6, LOG_EVERY
    jal  ra, log_line
    jal  x0, loop

# ---------------- set_segment: setpoint for segment s0 ----------------
# 0, 20, 35, 10, -20, 0 counts per 16 ms. No data tables - loads can't
# read flash on this core - so it's a chain of compares.

set_segment:
    addi a0, x0, 0
    addi t0, x0, 1
    bne  s0, t0, 1f
    addi a0, x0, 20
1:  addi t0, x0, 2
    bne  s0, t0, 2f
    addi a0, x0, 35
2:  addi t0, x0, 3
    bne  s0, t0, 3f
    addi a0, x0, 10
3:  addi t0, x0, 4
    bne  s0, t0, 4f
    addi a0, x0, -20
4:  slli a0, a0, 16
    sw   a0, S_SETPOINT(tp)
    sw   s0, M_LED(gp)               # LEDs show the segment
    ret

# ---------------- log_line: "ms,setpoint,speed,duty" ----------------

log_line:
    addi sp, ra, 0
    addi a0, x22, 0
    jal  ra, print_signed
    PUTC ','
    lw   a0, S_SETPOINT(tp)
    srai a0, a0, 16
    jal  ra, print_signed
    PUTC ','
    addi a0, x21, 0
    jal  ra, print_signed
    PUTC ','
    srai a0, x23, 16
    jal  ra, print_signed
    PUTC 13
    PUTC 10
    addi ra, sp, 0
    ret

# ---------------- putc: send a0[7:0] over the UART ----------------

putc:
    lw   t0, M_UART(gp)
    andi t0, t0, 1
    bne  t0, x0, putc
    sw   a0, M_UART(gp)
    ret

# ---------------- print_signed: a0 as signed decimal ----------------
# Uses a1, a3 (saved ra), a4, a5, t1, t2.

print_signed:
    addi a1, ra, 0
    bge  a0, x0, 1f
    sub  a4, x0, a0                  # magnitude
    PUTC '-'
    addi a0, a4, 0
1:  addi ra, a1, 0
    # falls through to print_dec with ra = caller

# ---------------- print_dec: a0 as unsigned decimal ----------------

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
