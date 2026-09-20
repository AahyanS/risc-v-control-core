// software_mac_benchmark.c
// Times the identical computation as mac_benchmark.s - same values,
// same three-term accumulation - using pid.c's software q16_mul
// (built on libgcc's __mulsi3/__muldi3, since this core has no
// hardware multiply) instead of the MAC instruction. Direct
// cycles-per-iteration comparison: same workload, only the multiply
// mechanism differs.
//
// Build:
//   riscv-none-elf-gcc -march=rv32i -mabi=ilp32 -nostdlib -nostartfiles \
//     -Ttext=0x0 -o software_mac_benchmark.elf crt0.s pid.c software_mac_benchmark.c -lgcc
//   riscv-none-elf-objcopy -O verilog software_mac_benchmark.elf software_mac_benchmark.hex

#include "pid.h"

#define MMIO_CYCLE_ADDR ((volatile uint32_t *)0xFFFFFF04)
#define RESULT_BASE     ((volatile int32_t *)0x300)

int main(void) {
    *MMIO_CYCLE_ADDR = 0;
    uint32_t t_start = *MMIO_CYCLE_ADDR;

    q16_t output = 0;
    output += q16_mul(Q16_ONE / 2, Q16_ONE);          // Kp * error       (0.5 * 1.0)
    output += q16_mul(Q16_ONE / 4, Q16_ONE * 2);        // Ki * integral    (0.25 * 2.0)
    output += q16_mul(Q16_ONE / 8, Q16_ONE);             // Kd * derivative  (0.125 * 1.0)

    uint32_t t_end = *MMIO_CYCLE_ADDR;

    RESULT_BASE[0] = output;
    RESULT_BASE[1] = (int32_t)(t_end - t_start);

    while (1) {
        // spin forever - bare metal, main() never returns
    }

    return 0;
}
