# pid_mac.inc
# One PID step in assembly, using the custom MAC instruction - the
# same arithmetic as pid_step() in pid.c, bit for bit, but small
# enough to lock into the instruction cache (pid.c plus libgcc's
# software 64-bit multiply is far bigger than the 256-byte cache).
#
# Shared by the control-loop interrupt handler (hw_control_loop.s) and
# the C-callable wrapper pid_mac.s that sw/pid_mac_test.c checks
# against pid_step(), so the code that's tested is the code that runs.
#
# mac rd, rs1, rs2:  rd = rd + ((rs1 * rs2) >> 16), 64-bit product -
# exactly q16_mul() plus an add, including the truncation to 32 bits.
# So output = 0; mac Kp*e; mac Ki*i; mac Kd*d gives the same
# p_term + i_term + d_term as pid.c, wraparound and all.
#
# Registers (all passed in, so the caller chooses the allocation):
#   err    in:  error = setpoint - measured (Q16.16)
#   integ  in/out: integral state (updated per the anti-windup rule)
#   prev   in/out: previous error (set to err)
#   out    out: controller output, clamped to [out_min, out_max]
#   t0-t2  scratch
#   base   pointer to the gains, laid out like pid_t in pid.h:
#            0 kp   4 ki   8 kd   20 out_min   24 out_max
#          (offsets 12/16, integral/prev_error, are the caller's
#          business - the handler keeps them in registers instead)
#
# Anti-windup, as in pid.c: the integral update is kept if the output
# isn't saturated, or if it is but the error points back inside the
# limits; otherwise it's discarded.

.macro MAC rd, rs1, rs2
    .insn r 0x0B, 0, 0, \rd, \rs1, \rs2
.endm

.macro PID_MAC err, integ, prev, out, t0, t1, t2, base
    add  \t1, \integ, \err          # tentative integral
    sub  \t2, \err, \prev           # derivative
    addi \prev, \err, 0             # prev_error = error
    addi \out, x0, 0
    lw   \t0, 0(\base)              # kp
    MAC  \out, \t0, \err
    lw   \t0, 4(\base)              # ki
    MAC  \out, \t0, \t1
    lw   \t0, 8(\base)              # kd
    MAC  \out, \t0, \t2
    lw   \t0, 24(\base)             # out_max
    blt  \t0, \out, 1f              # output > out_max
    lw   \t0, 20(\base)             # out_min
    blt  \out, \t0, 2f              # output < out_min
    addi \integ, \t1, 0             # in range: keep the update
    jal  x0, 3f
1:  addi \out, \t0, 0               # clamp high
    bge  \err, x0, 3f               # keep only if error < 0
    addi \integ, \t1, 0
    jal  x0, 3f
2:  addi \out, \t0, 0               # clamp low
    bge  x0, \err, 3f               # keep only if error > 0
    addi \integ, \t1, 0
3:
.endm
