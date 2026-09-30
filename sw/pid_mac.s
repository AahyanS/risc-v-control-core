# pid_mac.s
# C-callable wrapper around the PID_MAC macro (pid_mac.inc), with the
# same signature as pid_step() in pid.c:
#
#   q16_t pid_step_mac(pid_t *pid, q16_t setpoint, q16_t measured);
#
# Exists so sw/pid_mac_test.c can run the MAC version and the C
# version side by side on the same inputs and check they agree - the
# interrupt handler uses the identical macro.

.include "pid_mac.inc"

.section .text
.global pid_step_mac

pid_step_mac:                       # a0 = pid, a1 = setpoint, a2 = measured
    sub  a1, a1, a2                 # error
    lw   a3, 12(a0)                 # integral
    lw   a4, 16(a0)                 # prev_error
    PID_MAC a1, a3, a4, a5, t0, t1, t2, a0
    sw   a3, 12(a0)
    sw   a4, 16(a0)
    addi a0, a5, 0
    ret
