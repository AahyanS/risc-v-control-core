// imem.v
// Instruction memory for RV32I
//
// Combinational read-only memory, addressed by the PC. addr is a byte
// address (matches pc.v, which advances by 4 each step); since every
// instruction is a 4-byte-aligned 32-bit word, the bottom 2 bits of
// addr are always 0 and are dropped when indexing the word array.
//
// No RISC-V toolchain is installed yet, so there's no loader here -
// a testbench populates mem[] directly via hierarchical reference
// (e.g. uut.mem[0] = 32'h...) with hand-written instruction words.

module imem (
    input  [31:0] addr,
    output [31:0] instr
);

    // 256 words = 1KB of instruction space - arbitrary, resize later
    reg [31:0] mem [0:255];

    // addr[9:2]: drop the 2 byte-offset bits, keep 8 bits -> 256 entries
    assign instr = mem[addr[9:2]];

endmodule
