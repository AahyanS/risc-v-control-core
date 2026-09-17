// imem.v
// Instruction memory for RV32I
//
// Combinational read-only memory, addressed by the PC. Byte-addressable
// (same pattern as dmem.v) so it can be loaded directly from a real
// compiled program via $readmemh: `riscv-none-elf-objcopy -O verilog`
// emits exactly one byte value per array entry, which only lines up
// with a byte-wide array like this one - a 32-bit-wide word array
// (the original design) would need every 4 bytes manually repacked
// first.
//
// addr is a byte address (matches pc.v, which advances by 4 each
// step); reads reassemble 4 consecutive bytes little-endian, same as
// dmem.v's word-read case.
//
// Without a loaded hex file, a testbench can still populate mem[]
// directly via hierarchical reference (e.g. uut.mem[0] = 8'h...) with
// hand-written bytes, same as before.

module imem (
    input  [31:0] addr,
    output [31:0] instr
);

    // 8192 bytes = 8KB of instruction space. Originally 1KB; enlarged
    // after real riscv-tests compliance binaries (which include
    // pipeline-bypass sub-tests this core doesn't even need yet)
    // turned out to exceed 1KB.
    reg [7:0] mem [0:8191];

    assign instr = {mem[addr+3], mem[addr+2], mem[addr+1], mem[addr]};

endmodule
