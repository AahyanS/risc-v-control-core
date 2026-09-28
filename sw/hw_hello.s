# hw_hello.s
# First program to run on real hardware (fpga/basys3_top.v). It is
# fetched from the Basys3's onboard flash, so if it runs at all, the
# whole instruction path works: STARTUPE2 boot sequence, flash reads,
# the cache, and the pipeline.
#
#   LD15-LD8: heartbeat counter, ticking a few times a second
#   LD7-LD0:  low 8 bits of the encoder position, updated continuously
#
# Turning the motor shaft by hand should make LD7-LD0 count one way
# and then the other way when reversed - that confirms the encoder
# wiring without the motor ever being powered.
#
# DELAY sets the heartbeat speed. Default is for hardware at 25 MHz;
# the simulation build overrides it with a tiny value via
# -Wa,--defsym,DELAY=<n> (see fpga/build_programs.sh).

.ifndef DELAY
.equ DELAY, 400000
.endif

.section .text
.global _start

_start:
    addi s0, x0, -216        # 0xFFFFFF28 LED register
    addi s1, x0, -240        # 0xFFFFFF10 encoder position
    addi s2, x0, 0           # heartbeat count

outer:
    li   t0, DELAY
inner:
    lw   t1, 0(s1)           # encoder position
    andi t1, t1, 0xFF
    slli t2, s2, 8
    or   t2, t2, t1
    sw   t2, 0(s0)           # LEDs = {heartbeat, position[7:0]}
    addi t0, t0, -1
    bne  t0, x0, inner

    addi s2, s2, 1
    andi s2, s2, 0xFF
    jal  x0, outer
