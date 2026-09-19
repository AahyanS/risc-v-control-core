// pid.c
// See pid.h for the Q16.16 fixed-point convention this all runs on.

#include "pid.h"

void pid_init(pid_t *pid, q16_t kp, q16_t ki, q16_t kd,
              q16_t out_min, q16_t out_max) {
    pid->kp = kp;
    pid->ki = ki;
    pid->kd = kd;
    pid->integral   = 0;
    pid->prev_error = 0;
    pid->out_min = out_min;
    pid->out_max = out_max;
}

// One PID step. error is recomputed each call from setpoint/measured
// (both Q16.16) - the caller doesn't track error itself.
//
// Anti-windup: conditional integration. The integral is tentatively
// updated, then a P+I+D output is computed from that tentative value.
// If the output saturates, the tentative integral update is only kept
// if it points the RIGHT way - i.e., if the error itself would pull
// the output back toward the saturation limit rather than push it
// further past. Otherwise the update is discarded outright: the
// integral state doesn't move this step. This stops the integral
// term from growing without bound while the output is pinned at a
// limit and can't actually act on that growth.
q16_t pid_step(pid_t *pid, q16_t setpoint, q16_t measured) {
    q16_t error = setpoint - measured;

    q16_t p_term = q16_mul(pid->kp, error);

    q16_t tentative_integral = pid->integral + error;
    q16_t i_term = q16_mul(pid->ki, tentative_integral);

    q16_t derivative = error - pid->prev_error;
    q16_t d_term = q16_mul(pid->kd, derivative);

    q16_t output = p_term + i_term + d_term;

    if (output > pid->out_max) {
        output = pid->out_max;
        if (error < 0) {
            // error is pulling output back down - safe to integrate
            pid->integral = tentative_integral;
        }
        // else: discard - integrating here would only make the
        // saturation worse once it eventually lifts
    } else if (output < pid->out_min) {
        output = pid->out_min;
        if (error > 0) {
            pid->integral = tentative_integral;
        }
    } else {
        pid->integral = tentative_integral;
    }

    pid->prev_error = error;
    return output;
}
