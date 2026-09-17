# crt0.s
# Minimal bare-metal startup stub for this core.
#
# There's no OS, no C runtime library, and no memory-mapped stack
# guard on this design - so before any C code can safely run, this
# has to set up a stack pointer by hand (C code spills local variables
# to the stack even at -O0, and sp starts undefined otherwise), then
# hand off to main(). Real embedded toolchains ship a crt0.s that does
# exactly this, usually with more setup (BSS zeroing, interrupt vector
# table); this is the minimum version for our core's current state.
#
# Registers x1-x31 are explicitly zeroed first. This core's regfile.v
# never resets general-purpose registers (only x0's read port is
# hardwired to 0) - matching real RISC-V hardware, which the spec
# does not require to define a reset value for x1-x31 either. A
# compiler-generated prologue can spill an as-yet-unset register (e.g.
# saving the frame pointer before this function has set it) with no
# correctness impact on the program, but it did produce a spurious
# mismatch during differential co-simulation against a reference
# model that assumed zero-initialized registers. Real riscv-tests
# does exactly this same zeroing (its INIT_XREG macro) for the same
# reason: don't rely on hardware reset state you're not guaranteed.

.section .text
.global _start

_start:
    li   x1, 0
    li   x2, 0
    li   x3, 0
    li   x4, 0
    li   x5, 0
    li   x6, 0
    li   x7, 0
    li   x8, 0
    li   x9, 0
    li   x10, 0
    li   x11, 0
    li   x12, 0
    li   x13, 0
    li   x14, 0
    li   x15, 0
    li   x16, 0
    li   x17, 0
    li   x18, 0
    li   x19, 0
    li   x20, 0
    li   x21, 0
    li   x22, 0
    li   x23, 0
    li   x24, 0
    li   x25, 0
    li   x26, 0
    li   x27, 0
    li   x28, 0
    li   x29, 0
    li   x30, 0
    li   x31, 0
    li   sp, 8188       # stack pointer = top of dmem's 8KB
                         # (8192-4, word-aligned), growing downward
    call main            # hand off to the real program
1:
    j    1b              # main() should never return; spin forever if it does
