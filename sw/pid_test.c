// pid_test.c
// Verifies q16_mul's basic correctness, then proves anti-windup
// actually matters - not just that the PID math runs - by racing a
// guarded pid_step (pid.c) against a deliberately naive variant with
// no anti-windup guard, against the identical saturating scenario.
//
// The "plant" here is a bare integrator (measured += output each
// step) - a placeholder standing in for the real quadrature-encoder
// feedback this will eventually drive; it's simple enough to reason
// about by hand while still producing a genuine, sustained
// saturation-then-recovery scenario, which is what actually exercises
// anti-windup (a plant that never saturates the output has nothing
// to demonstrate).
//
// setpoint=100, output clamped to [-10,10], Kp=0.5, Ki=0.05, Kd=0.
// Error starts at 100, so P alone (50) already exceeds out_max (10) -
// output saturates immediately and stays there while measured climbs
// by 10/step. Once measured crosses setpoint (~10 steps in), the
// naive integral - having accumulated unchecked through the entire
// saturated phase - keeps commanding max output for several more
// steps than the guarded version, producing visible overshoot the
// guarded version doesn't have.
//
// Build:
//   riscv-none-elf-gcc -march=rv32i -mabi=ilp32 -O0 -nostdlib -nostartfiles \
//     -Ttext=0x0 -o pid_test.elf crt0.s pid.c pid_test.c -lgcc
//   riscv-none-elf-objcopy -O verilog pid_test.elf pid_test.hex

#include "pid.h"

#define RESULT_BASE 0x300

static q16_t plant_step(q16_t measured, q16_t output) {
    return measured + output;
}

// Deliberately WITHOUT anti-windup - always accumulates the integral,
// even while the output is saturated. Exists only to demonstrate,
// side by side with pid_step (pid.c), why that guard matters.
static q16_t pid_step_naive(pid_t *pid, q16_t setpoint, q16_t measured) {
    q16_t error = setpoint - measured;

    q16_t p_term = q16_mul(pid->kp, error);
    pid->integral += error;                    // unconditional - no windup guard
    q16_t i_term = q16_mul(pid->ki, pid->integral);
    q16_t derivative = error - pid->prev_error;
    q16_t d_term = q16_mul(pid->kd, derivative);

    q16_t output = p_term + i_term + d_term;
    if (output > pid->out_max)      output = pid->out_max;
    else if (output < pid->out_min) output = pid->out_min;

    pid->prev_error = error;
    return output;
}

int main(void) {
    volatile int32_t *results = (volatile int32_t *)RESULT_BASE;

    // ---- q16_mul sanity checks ----
    // 1.5 * 2.5 = 3.75 -> Q16.16: 98304 * 163840 (raw) -> 245760
    results[0] = q16_mul(98304, 163840);
    // -2.0 * 3.0 = -6.0 -> Q16.16: -131072 * 196608 (raw) -> -393216
    results[1] = q16_mul(-131072, 196608);

    // ---- Anti-windup comparison ----
    q16_t setpoint = Q16_FROM_INT(100);
    q16_t out_min  = Q16_FROM_INT(-10);
    q16_t out_max  = Q16_FROM_INT(10);

    pid_t pid_guarded, pid_naive;
    pid_init(&pid_guarded, Q16_ONE / 2, Q16_ONE / 20, 0, out_min, out_max);
    pid_init(&pid_naive,   Q16_ONE / 2, Q16_ONE / 20, 0, out_min, out_max);

    q16_t measured_guarded = 0;
    q16_t measured_naive   = 0;
    q16_t peak_guarded     = 0;   // highest measured value reached (overshoot marker)
    q16_t peak_naive       = 0;

    int i;
    for (i = 0; i < 40; i++) {
        q16_t out_g = pid_step(&pid_guarded, setpoint, measured_guarded);
        measured_guarded = plant_step(measured_guarded, out_g);
        if (measured_guarded > peak_guarded) peak_guarded = measured_guarded;

        q16_t out_n = pid_step_naive(&pid_naive, setpoint, measured_naive);
        measured_naive = plant_step(measured_naive, out_n);
        if (measured_naive > peak_naive) peak_naive = measured_naive;
    }

    results[2] = pid_guarded.integral;   // guarded integral after 40 steps
    results[3] = pid_naive.integral;     // naive integral - should be much larger (wound up)
    results[4] = peak_guarded;            // guarded peak measured value (overshoot marker)
    results[5] = peak_naive;              // naive peak measured value - should overshoot more

    while (1) {
        // spin forever - bare metal, main() never returns
    }

    return 0;
}
