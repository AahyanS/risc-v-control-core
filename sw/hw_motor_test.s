# hw_motor_test.s
# Open-loop motor check for real hardware, run before any control
# loop: forward, stop, reverse, stop, repeat. The motor only moves
# while switch SW15 is up (hardware arm switch in fpga/basys3_top.v).
#
#   LD15:     requested direction (0 = forward, 1 = reverse)
#   LD14:     motor commanded on
#   LD13-LD0: encoder position / 64, updated continuously
#
# What to check: while going forward, LD13-LD0 should count one way;
# in reverse, the other way. If the count goes the "wrong" way for
# the direction you want to call forward, swap the A/B encoder wires
# (or the two motor wires) - either fixes it. If the count doesn't
# move while the motor spins, the encoder isn't wired or powered.
#
# RUN_ITERS/STOP_ITERS set the phase lengths (about 2 s and 0.5 s on
# hardware at 25 MHz); the simulation build overrides them.

.ifndef RUN_ITERS
.equ RUN_ITERS, 2800000
.endif
.ifndef STOP_ITERS
.equ STOP_ITERS, 700000
.endif
.equ DUTY, 410                # 40% of the 1024-cycle PWM period

.section .text
.global _start

_start:
    addi s0, x0, -216         # 0xFFFFFF28 LED register
    addi s1, x0, -240         # 0xFFFFFF10 encoder position
    addi s2, x0, -232         # 0xFFFFFF18 PWM duty cycle
    addi s3, x0, -212         # 0xFFFFFF2C motor direction
    sw   x0, 0(s1)            # zero the encoder position

loop:
    # ---- forward ----
    sw   x0, 0(s3)
    li   t2, DUTY
    sw   t2, 0(s2)
    li   s4, 0x4000           # LD14 on, LD15 off
    li   a0, RUN_ITERS
    jal  ra, wait

    # ---- stop ----
    sw   x0, 0(s2)
    li   s4, 0x0000
    li   a0, STOP_ITERS
    jal  ra, wait

    # ---- reverse ----
    addi t2, x0, 1
    sw   t2, 0(s3)
    li   t2, DUTY
    sw   t2, 0(s2)
    li   s4, 0xC000           # LD15 and LD14 on
    li   a0, RUN_ITERS
    jal  ra, wait

    # ---- stop ----
    sw   x0, 0(s2)
    li   s4, 0x8000
    li   a0, STOP_ITERS
    jal  ra, wait

    jal  x0, loop

# wait: spin a0 iterations, refreshing the LEDs every iteration.
wait:
    lw   t0, 0(s1)            # encoder position
    srai t0, t0, 6
    li   t1, 0x3FFF
    and  t0, t0, t1
    or   t0, t0, s4
    sw   t0, 0(s0)
    addi a0, a0, -1
    bne  a0, x0, wait
    jalr x0, 0(ra)
