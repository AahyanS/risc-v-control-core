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

.section .text
.global _start

_start:
    li   sp, 1020      # stack pointer = top of dmem's 1KB (1024-4,
                        # word-aligned), growing downward
    call main           # hand off to the real program
1:
    j    1b             # main() should never return; spin forever if it does
