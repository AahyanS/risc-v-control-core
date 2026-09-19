# interference_locked_test.s
# Identical to interference_unlocked_test.s, with one addition: locks
# hot_loop's cache line right after the warm-up call, before the
# timed measurement loop begins. Run against
# cpu_pipeline_cache_locked.v (Configuration 3).
#
# Same interference pattern as the unlocked test - interference is
# called between every measured hot_loop call, aliasing to the same
# direct-mapped cache slot (same index, different tag, guaranteed by
# placing it exactly 256 bytes after hot_loop). The difference this
# test is built to show: with hot_loop's line locked, interference's
# fetches get routed through the cache's bypass path instead of
# evicting hot_loop - so every measured hot_loop call should stay a
# fast hit despite the exact same competing traffic the unlocked test
# faces. Compare this program's min/max against
# interference_unlocked_test.s's: same workload, same interference,
# different cache-locking policy - the actual, direct evidence for
# what locking buys a real-time control loop.
#
# measure_loop runs 6 total passes; the first (i==0) is a warm-up and
# excluded from the stats. Its own instructions (the timing reads,
# loop control, etc.) live in cache lines that were never explicitly
# warmed ahead of time, so the FIRST pass through them pays a one-time
# cold-fetch cost unrelated to whether hot_loop itself gets evicted -
# that's an artifact of the test harness, not of the thing being
# measured. Discarding it isolates the actual variable under test:
# whether interference evicts hot_loop between calls.
#
# Build:
#   riscv-none-elf-gcc -march=rv32i -mabi=ilp32 -nostdlib -nostartfiles \
#     -Ttext=0x0 -o interference_locked_test.elf interference_locked_test.s
#   riscv-none-elf-objcopy -O verilog interference_locked_test.elf interference_locked_test.hex

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

    jal  x6, hot_loop              # dedicated warm-up call, BEFORE locking -
                                     # locking only protects an already-resident
                                     # line, it doesn't force a fill; locking an
                                     # empty line would route every future access
                                     # through bypass forever instead of ever
                                     # becoming a fast hit

    addi x7, x0, -256               # x7 = 0xFFFFFF00 (MMIO_LOCK_ADDR)
    la   x8, hot_loop
    lui  x9, 0x80000
    or   x8, x8, x9                  # x8 = hot_loop's address, lock bit set
    sw   x8, 0(x7)                    # lock hot_loop's cache line

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
