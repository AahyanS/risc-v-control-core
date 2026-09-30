// pid_mac_test.c
// Differential test: pid_step() (pid.c, C with libgcc's software
// multiply) vs. pid_step_mac() (pid_mac.s, the PID_MAC macro the
// control-loop interrupt handler uses). Both controllers get the same
// gains and the same inputs every step; after each step the output,
// the integral, and prev_error must match exactly.
//
// Agreement only means something if every path was exercised, so the
// test also counts which branch each step took (in range, clamped
// high, clamped low, and for the clamped cases whether anti-windup
// kept or discarded the integral update); the testbench requires all
// five to occur.
//
// Two phases:
//   1. random: fresh pseudo-random setpoint/measured every step, gains
//      re-randomized every 10 steps (positive and negative errors,
//      saturation both ways, all branch combinations)
//   2. closed loop: a simple integrating plant, like pid_test.c - a
//      realistic trajectory where the integral state carries over
// Input ranges are kept small enough that no intermediate overflows
// int32 in the C version (signed overflow is undefined in C, so a
// "match" there would prove nothing).
//
// No initialized data or switch statements: loads can't read flash on
// this core, so the program must not need .rodata/.data.
//
// Build: see tb_pid_mac_test.v

#include "pid.h"

#define RESULT_BASE 0x300

q16_t pid_step_mac(pid_t *pid, q16_t setpoint, q16_t measured);

static uint32_t lcg_state;

static uint32_t rnd(void) {
    lcg_state = lcg_state * 1664525u + 1013904223u;   // Numerical Recipes LCG
    return lcg_state;
}

// Signed value in [-range, range), range a power of two.
static int32_t rnd_signed(int32_t range) {
    return (int32_t)(rnd() & (uint32_t)(2 * range - 1)) - range;
}

int main(void) {
    volatile int32_t *results = (volatile int32_t *)RESULT_BASE;

    pid_t a, b;                 // a: C reference, b: MAC version
    int32_t steps = 0, mismatches = 0;
    int32_t n_in = 0, n_hi = 0, n_lo = 0, n_hi_keep = 0, n_lo_keep = 0;
    q16_t out_a, out_b, integral_before, setpoint, measured;
    int i;

    lcg_state = 12345;

    for (i = 0; i < 100; i++) {
        if (i % 10 == 0) {
            // Gains: kp in [0, 2), ki in [0, 0.25), kd in [0, 1).
            q16_t kp = (q16_t)(rnd() & 0x1FFFF);
            q16_t ki = (q16_t)(rnd() & 0x03FFF);
            q16_t kd = (q16_t)(rnd() & 0x0FFFF);
            q16_t lim = Q16_FROM_INT(1 + (rnd() & 7));
            pid_init(&a, kp, ki, kd, -lim, lim);
            pid_init(&b, kp, ki, kd, -lim, lim);
        }

        if (i < 60) {
            setpoint = rnd_signed(1 << 20);        // within +-16.0
            measured = rnd_signed(1 << 20);
        } else {
            if (i == 60) { setpoint = Q16_FROM_INT(12); measured = 0; }
            // integrating plant: measured moves by the last output
            measured = measured + out_a;
        }

        integral_before = a.integral;
        out_a = pid_step(&a, setpoint, measured);
        out_b = pid_step_mac(&b, setpoint, measured);
        steps++;

        if (out_a != out_b || a.integral != b.integral ||
            a.prev_error != b.prev_error)
            mismatches++;

        if (out_a == a.out_max && a.out_max != 0) {
            n_hi++;
            if (a.integral != integral_before) n_hi_keep++;
        } else if (out_a == a.out_min) {
            n_lo++;
            if (a.integral != integral_before) n_lo_keep++;
        } else {
            n_in++;
        }
    }

    results[0] = steps;
    results[1] = mismatches;
    results[2] = n_in;
    results[3] = n_hi;
    results[4] = n_lo;
    results[5] = n_hi_keep;
    results[6] = n_lo_keep;
    results[7] = 0x600D;        // done marker

    for (;;) { }
}
