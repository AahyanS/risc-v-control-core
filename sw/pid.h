// pid.h
// Fixed-point PID controller, Q16.16 format.
//
// Q16.16: a 32-bit signed integer represents a real value scaled by
// 2^16 - e.g. 1.5 is stored as 1.5 * 65536 = 98304. Addition/
// subtraction of two Q16.16 values works with plain integer +/- since
// both operands share the same scale. Multiplication does NOT just
// work - multiplying two values each scaled by 2^16 leaves the raw
// product scaled by 2^32, so it has to be rescaled back down (q16_mul,
// below) before it means anything as a Q16.16 value again.
//
// This core is base RV32I - no hardware multiply. C's * on int
// compiles to a call to libgcc's __mulsi3 (a software multiply
// routine); __muldi3/__ashrdi3 do the same for the 64-bit widening
// multiply and shift q16_mul needs. Build with -lgcc for these to
// link - see sw/pid_test.c's build comment.

#include <stdint.h>

typedef int32_t q16_t;

#define Q16_SHIFT 16
#define Q16_ONE   (1 << Q16_SHIFT)

// int-to-Q16.16 and back (truncating, not rounding - fine for the
// small integer setpoints/limits this project uses).
#define Q16_FROM_INT(x) ((q16_t)(x) << Q16_SHIFT)
#define Q16_TO_INT(x)   ((int32_t)(x) >> Q16_SHIFT)

// Multiply two Q16.16 values. Widens to a 64-bit intermediate product
// first (avoids losing bits before rescaling), then shifts right by
// 16 (arithmetic shift - preserves sign for negative products) to get
// back to Q16.16 scale, then truncates to 32 bits.
//
// Known simplification: no overflow/saturation check on the final
// truncation - if the true mathematical result doesn't fit in Q16.16
// (magnitude too large for 16 integer bits), this silently wraps
// rather than saturating. Acceptable here since gains are small
// fractional values and errors are bounded by real sensor/setpoint
// ranges, but worth remembering if either grows.
static inline q16_t q16_mul(q16_t a, q16_t b) {
    int64_t product = (int64_t)a * (int64_t)b;
    return (q16_t)(product >> Q16_SHIFT);
}

typedef struct {
    q16_t kp, ki, kd;
    q16_t integral;
    q16_t prev_error;
    q16_t out_min, out_max;
} pid_t;

void   pid_init(pid_t *pid, q16_t kp, q16_t ki, q16_t kd,
                 q16_t out_min, q16_t out_max);
q16_t  pid_step(pid_t *pid, q16_t setpoint, q16_t measured);
