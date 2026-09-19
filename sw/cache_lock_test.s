# cache_lock_test.s
# Proves cache-line locking actually protects a line from eviction.
#
# Sequence:
#   1. Call hot_code once - warms its cache line (a real miss/fill).
#   2. Lock that line via the memory-mapped lock register at
#      0xFFFFFF00 (bit 31 = lock enable, bits 23:0 = an address inside
#      the line to lock - here, hot_code's own address).
#   3. Jump to alias_setup, placed EXACTLY 256 bytes after hot_code.
#      256 = 2^8 is exactly one unit in a direct-mapped cache's tag
#      field (addr[23:8]) while leaving the index field (addr[7:4])
#      unchanged - so alias_setup is guaranteed to map to the SAME
#      cache slot as hot_code, with a different tag. Without locking,
#      fetching alias_setup would evict hot_code's line.
#   4. Call hot_code a second time.
#
# Architectural correctness (x1/x2 ending up right) can't by itself
# prove locking worked - flash is the source of truth, so even an
# evicted-then-refilled hot_code would produce the same register
# results, just slower. The actual proof is internal cache state,
# checked by the testbench (tb_cache_lock_protection.v): does
# hot_code's line still hold hot_code's tag after alias_setup ran?
#
# Build:
#   riscv-none-elf-gcc -march=rv32i -mabi=ilp32 -nostdlib -nostartfiles \
#     -Ttext=0x0 -o cache_lock_test.elf cache_lock_test.s
#   riscv-none-elf-objcopy -O verilog cache_lock_test.elf cache_lock_test.hex

.section .text
.global _start

_start:
    addi x1, x0, 0              # x1 is used as an accumulator below
                                  # (addi x1,x1,1) - must start defined,
                                  # not whatever regfile's undefined
                                  # reset value is (x + 1 = x under
                                  # X-propagation otherwise)
    jal  x6, hot_code          # 1st call - warms hot_code's cache line

    addi x7, x0, -256          # x7 = 0xFFFFFF00 (MMIO_LOCK_ADDR)
    la   x8, hot_code          # x8 = address of hot_code
    lui  x9, 0x80000           # x9 = 0x80000000 (lock-enable bit)
    or   x8, x8, x9            # x8 = hot_code's address with lock bit set
    sw   x8, 0(x7)             # lock hot_code's cache line

    jal  x0, alias_setup       # skip the padding, go straight to the
                                # aliasing code 256 bytes ahead

    .align 4                   # force hot_code to start on a 16-byte
                                # (cache line) boundary
hot_code:
    addi x1, x1, 1              # hot pass counter - 1 after call #1, 2 after call #2
    addi x2, x0, 111            # hot result marker - should read 111 after either call
    jalr x0, 0(x6)              # return to caller

    .rept 61                    # pad exactly to hot_code + 256 bytes
    nop                          # (hot_code is 3 instrs = 12 bytes;
    .endr                        #  12 + 61*4 = 256)

alias_setup:
    addi x3, x0, 222            # aliasing-code marker
    addi x3, x3, 1               # x3 = 223 once this runs
    jal  x6, hot_code            # 2nd call - re-run hot_code

spin:
    jal  x0, spin
