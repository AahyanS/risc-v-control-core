# cycle_timing_test.s
# Demonstrates the cycle-counter instrumentation is actually usable
# for its real purpose: measuring per-iteration timing and exposing
# jitter, the exact capability the whole three-configuration
# comparison (Configuration 1/2/3) is built around.
#
# Times 5 iterations of a tiny loop body via the memory-mapped cycle
# counter at 0xFFFFFF04 (read = current count, write = reset to 0),
# tracking min/max/sum across iterations (mean is left as sum/N for
# whatever reads the result - this core is base RV32I, no hardware
# divide).
#
# Run against a cache-enabled configuration (cpu_pipeline_cache.v),
# the FIRST iteration's loop body is an uncached miss (slow - has to
# actually fetch from flash) while every later iteration hits the
# now-warm cache (fast) - so max should come from iteration 0 and
# min from a later iteration, concretely showing the exact
# "average case great, first time is a jitter spike" story this
# project's thesis is about. Run against cpu_pipeline_xip.v
# (Configuration 1, no cache at all), every iteration pays full flash
# latency uniformly - min and max should end up nearly identical
# instead.
#
# Build:
#   riscv-none-elf-gcc -march=rv32i -mabi=ilp32 -nostdlib -nostartfiles \
#     -Ttext=0x0 -o cycle_timing_test.elf cycle_timing_test.s
#   riscv-none-elf-objcopy -O verilog cycle_timing_test.elf cycle_timing_test.hex

.section .text
.global _start

_start:
    addi x10, x0, -252        # x10 = 0xFFFFFF04 (MMIO_CYCLE_ADDR)
    sw   x0, 0(x10)            # reset the cycle counter to 0

    lui  x1, 0x80000            # x1 = min, init sentinel 0x7FFFFFFF
    addi x1, x1, -1
    addi x2, x0, 0               # x2 = max, init 0 (any real delta beats this)
    addi x3, x0, 0               # x3 = sum
    addi x4, x0, 0               # x4 = loop index i
    addi x5, x0, 5               # x5 = N = 5 iterations

loop:
    lw   x11, 0(x10)              # t_start
    addi x20, x20, 1               # dummy loop-body work (3 instrs)
    addi x21, x21, 1
    addi x22, x21, 1
    lw   x12, 0(x10)              # t_end
    sub  x13, x12, x11             # delta = t_end - t_start

    add  x3, x3, x13               # sum += delta

    bge  x13, x1, skip_min          # if delta >= min, min unchanged
    addi x1, x13, 0
skip_min:
    bge  x2, x13, skip_max          # if max >= delta, max unchanged
    addi x2, x13, 0
skip_max:

    addi x4, x4, 1
    blt  x4, x5, loop

spin:
    jal  x0, spin
