// sum_loop.c
// First real program compiled for this core (not hand-assembled).
//
// Computes 1+2+3+4+5 and writes the result to a fixed data memory
// address, since the core has no I/O peripherals yet - a store to a
// known address is the only way to observe a result from outside.
//
// Build:
//   riscv-none-elf-gcc -march=rv32i -mabi=ilp32 -O0 -nostdlib \
//     -nostartfiles -Ttext=0x0 -o sum_loop.elf crt0.s sum_loop.c
//   riscv-none-elf-objcopy -O verilog sum_loop.elf sum_loop.hex

// A fixed address inside dmem's 1KB space, used purely as an
// observation point - the address itself has no other meaning.
#define RESULT_ADDR 0x200

int main(void) {
    volatile int *result = (volatile int *)RESULT_ADDR;
    int sum = 0;

    for (int i = 1; i <= 5; i++) {
        sum += i;
    }

    *result = sum;

    while (1) {
        // main() never returns on bare metal - spin here forever
    }

    return 0;
}
