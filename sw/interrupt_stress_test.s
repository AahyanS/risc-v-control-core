# interrupt_stress_test.s
# Hammers the interrupt logic with timer ticks landing at every point
# in the pipeline, in three phases that stress different fetch paths:
#   1. cached:   a tight loop that hits in the cache - ticks land at
#                every phase of the two-cycle fetch cadence
#   2. no cache: the same loop with the cache disabled - every fetch
#                is a one-word flash read, so ticks land mid-read and
#                the read is aborted
#   3. thrash:   a loop that calls a function placed exactly 256 bytes
#                away (same cache line index), so the two evict each
#                other every iteration - ticks land mid line-fill and
#                the fill is aborted
# Each loop accumulates a loaded 1 into s2, a set number of times.
# Whatever the interrupts do, each phase's sum must come out exact: an
# instruction executed twice, skipped, executed with a stale value, or
# mislabeled shows up as a wrong sum (and tb_interrupt_stress.v checks
# pipeline properties every cycle as well). Each phase must also
# finish at all - the forward-progress guarantee in
# cpu_pipeline_cache_locked.v (progress_hold).
#
# The handler changes the timer period on every tick to
# base + 0..15 cycles, so tick arrival drifts across every phase of the
# loop. base is chosen per phase to leave room for the handler (which
# is much slower when fetched from flash in phase 2).
#
# Handler-only registers (the handler saves nothing): s4 tick count,
# s5 scratch, s6 period base (set by main while ticks are off), gp.
#
# Build:
#   riscv-none-elf-gcc -march=rv32i_zicsr -mabi=ilp32 -nostdlib -nostartfiles \
#     -Ttext=0x0 -o interrupt_stress_test.elf interrupt_stress_test.s
#   riscv-none-elf-objcopy -O verilog interrupt_stress_test.elf interrupt_stress_test.hex

.equ ITERS_CACHED,  1500
.equ ITERS_NOCACHE, 60
.equ ITERS_THRASH,  60

.section .text
.global _start

_start:
    addi  gp, x0, -256             # 0xFFFFFF00 MMIO base
    addi  s0, x0, 0x100            # data word
    addi  t0, x0, 1
    sw    t0, 0(s0)                # the value every load reads
    addi  s4, x0, 0                # tick count (handler-only)
    la    t0, handler
    csrrw x0, mtvec, t0
    addi  t0, x0, 0x08
    csrrs x0, mstatus, t0          # global enable (source enabled per phase)
    jal   x0, phase1

    .balign 16
handler:
    sw    x0, 0x20(gp)             # acknowledge
    addi  s4, s4, 1
    andi  s5, s4, 15
    add   s5, s5, s6               # next period: base + 0..15
    sw    s5, 0x1C(gp)             # (writing compare restarts the count)
    mret

# ---- start ticks: t0 = period base ----
ticks_on:
    addi  s6, t0, 0
    sw    t0, 0x1C(gp)
    sw    x0, 0x20(gp)
    addi  t0, x0, 0x80
    csrrw x0, mie, t0
    jalr  x0, 0(ra)

# ---------------- phase 1: cached ----------------
phase1:
    addi  s2, x0, 0
    li    s3, ITERS_CACHED
    addi  t0, x0, 40
    jal   ra, ticks_on
loop1:
    lw    t0, 0(s0)
    add   s2, s2, t0
    lw    t1, 0(s0)
    sub   s2, s2, t1
    lw    t2, 0(s0)
    add   s2, s2, t2               # net +1 per iteration
    addi  s3, s3, -1
    bne   s3, x0, loop1
    csrrw x0, mie, x0
    sw    s2, 0x300(x0)

# ---------------- phase 2: cache disabled ----------------
    addi  t0, x0, 1
    sw    t0, 0x34(gp)             # cache off: every fetch from flash
    addi  s2, x0, 0
    li    s3, ITERS_NOCACHE
    addi  t0, x0, 1200             # handler is ~6 x 131 cycles now
    jal   ra, ticks_on
loop2:
    lw    t0, 0(s0)
    add   s2, s2, t0
    addi  s3, s3, -1
    bne   s3, x0, loop2
    csrrw x0, mie, x0
    sw    x0, 0x34(gp)             # cache back on
    sw    s2, 0x304(x0)

# ---------------- phase 3: thrash ----------------
    addi  s2, x0, 0
    li    s3, ITERS_THRASH
    addi  t0, x0, 300
    jal   ra, ticks_on
    jal   x0, loop3

    .balign 256
loop3:                              # line index 0
    lw    t0, 0(s0)
    add   s2, s2, t0
    jal   x6, far                   # evicts loop3's line, and vice versa
    addi  s3, s3, -1
    bne   s3, x0, loop3
    jal   x0, finish

    .balign 256
far:                                # same line index as loop3
    addi  x0, x0, 0
    jalr  x0, 0(x6)

finish:
    csrrw x0, mie, x0
    sw    s2, 0x308(x0)
    sw    s4, 0x30C(x0)            # total ticks handled
    li    t1, 0x600D
    sw    t1, 0x310(x0)            # done marker
done:
    jal   x0, done
