# interference_unlocked_test.s
# The real test of what cache locking is for: does NOT lock hot_loop.
# Run against cpu_pipeline_cache.v (Configuration 2).
#
# Repeatedly calls hot_loop (the simulated "control loop hot path"),
# timing each call via the memory-mapped cycle counter, but calls
# interference (placed exactly 256 bytes after hot_loop - guaranteed
# to alias to the same direct-mapped cache slot, same index, different
# tag) in between every measured call, simulating competing traffic
# (another task, an ISR, anything) that touches the same cache slot.
#
# Without locking, every call to hot_loop after interference runs
# should be a fresh miss - interference evicted it. Expect min and max
# to end up close together, both near the miss cost - not because
# there's no jitter, but because EVERY call misses, so there's nothing
# to compare against. The real point is the CONTRAST with
# interference_locked_test.s: same interference pattern, but locked
# hot_loop stays resident and every call hits.
#
# measure_loop runs 6 total passes; the first (i==0) is a warm-up and
# excluded from the stats - its own instructions (timing reads, loop
# control) live in cache lines never explicitly warmed ahead of time,
# so the first pass through them pays a one-time cold-fetch cost
# unrelated to hot_loop/interference contention. Discarding it isolates
# the actual variable under test. Same fix applied to
# interference_locked_test.s, for a fair comparison.
#
# Build:
#   riscv-none-elf-gcc -march=rv32i -mabi=ilp32 -nostdlib -nostartfiles \
#     -Ttext=0x0 -o interference_unlocked_test.elf interference_unlocked_test.s
#   riscv-none-elf-objcopy -O verilog interference_unlocked_test.elf interference_unlocked_test.hex

.section .text
.global _start

_start:
    addi x10, x0, -252         # x10 = 0xFFFFFF04 (MMIO_CYCLE_ADDR)

    lui  x1, 0x80000             # x1 = min, sentinel 0x7FFFFFFF
    addi x1, x1, -1
    addi x2, x0, 0                # x2 = max
    addi x3, x0, 0                # x3 = sum
    addi x4, x0, 0                # x4 = loop index i
    addi x5, x0, 6                # x5 = 6 total passes (1 warm-up + 5 measured)

measure_loop:
    lw   x11, 0(x10)                 # t_start
    jal  x6, hot_loop                 # call the "hot path"
    lw   x12, 0(x10)                 # t_end
    sub  x13, x12, x11                # delta

    bne  x4, x0, record_stats           # i==0 is the warm-up pass - skip
    jal  x0, skip_stats
record_stats:
    add  x3, x3, x13                   # sum += delta
    bge  x13, x1, skip_min
    addi x1, x13, 0
skip_min:
    bge  x2, x13, skip_max
    addi x2, x13, 0
skip_max:
skip_stats:

    jal  x6, interference               # competing traffic - aliases to hot_loop's line

    addi x4, x4, 1
    blt  x4, x5, measure_loop

spin:
    jal  x0, spin

    .align 4                    # force hot_loop to start on a cache
                                  # line boundary
hot_loop:
    addi x23, x23, 1              # trivial "hot path" work
    jalr x0, 0(x6)

    .rept 62                     # pad exactly to hot_loop + 256 bytes
    nop                           # (hot_loop is 2 instrs = 8 bytes;
    .endr                         #  8 + 62*4 = 256)

interference:
    addi x24, x24, 1              # trivial "competing" work
    jalr x0, 0(x6)
