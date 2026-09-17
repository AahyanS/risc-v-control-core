/* link.ld
 * Minimal linker script for this core, standing in for riscv-tests'
 * env/p/link.ld.
 *
 * The official script places .text at 0x80000000 and 4KB-aligns every
 * section - reasonable for a real system with a large address space,
 * but this core has a single 1KB instruction memory and a single 1KB
 * data memory, so everything here is packed tightly starting at 0x0
 * instead.
 */

OUTPUT_ARCH("riscv")
ENTRY(_start)

SECTIONS
{
  . = 0x0;
  .text.init : { *(.text.init) }
  .text      : { *(.text) }
  .data      : { *(.data) }
  .bss       : { *(.bss) }
  _end = .;
}
