// dmem.v
// Data memory for RV32I loads/stores
//
// Byte-addressable, little-endian (lowest address = least-significant
// byte), supporting byte/halfword/word access widths per funct3 - the
// raw RV32I load/store funct3 encoding is used directly, not re-decoded:
//   funct3[1:0]: 00=byte, 01=halfword, 10=word
//   funct3[2]:   0=sign-extend (loads only), 1=zero-extend
// Store funct3 values (000/001/010) only ever use the width bits;
// funct3[2] is meaningless for stores and simply ignored on writes.
//
// Reads are combinational (a loaded value must be ready in the same
// cycle it's read). Writes are synchronous, like regfile's write port.
//
// ---- Storage: four byte lanes ----
// 8 KB, stored as four 2048 x 8 banks, one per byte position within a
// 32-bit word (lane N holds byte N of every word). Each lane has one
// write port and one combinational read port, which Vivado maps onto
// the FPGA's LUT RAM. The original version was a single 8192 x 8
// array written up to four times per store (mem[addr], mem[addr+1],
// ...); Vivado can't build RAM with four write ports, so it fell back
// to 65,536 individual flip-flops - more than the XC7A35T has. Found
// by the first real synthesis run, not by simulation, which is
// indifferent to how a memory would be built.
//
// The cost of lanes: halfword and word accesses must be naturally
// aligned (halfwords on even addresses, words on multiples of 4). A
// misaligned access reads/writes the wrong bytes rather than
// trapping. RISC-V lets an implementation choose how it handles
// misaligned access; compiled code aligns every access, and the
// riscv-tests rv32ui suite this core passes uses only aligned
// accesses.
//
// Addresses wrap every 8 KB (addr[12:0] is used).

module dmem (
    input         clk,
    input  [31:0] addr,
    input  [31:0] write_data,
    input         mem_write,
    input  [2:0]  funct3,
    output reg [31:0] read_data
);

    reg [7:0] lane0 [0:2047];
    reg [7:0] lane1 [0:2047];
    reg [7:0] lane2 [0:2047];
    reg [7:0] lane3 [0:2047];

    wire [10:0] word_idx = addr[12:2];
    wire [1:0]  offset   = addr[1:0];

    // ---- Read (combinational) ----
    wire [31:0] word = {lane3[word_idx], lane2[word_idx],
                        lane1[word_idx], lane0[word_idx]};

    wire [7:0]  rd_byte = (offset == 2'd0) ? word[7:0]   :
                          (offset == 2'd1) ? word[15:8]  :
                          (offset == 2'd2) ? word[23:16] :
                                             word[31:24];
    wire [15:0] rd_half = offset[1] ? word[31:16] : word[15:0];

    always @(*) begin
        case (funct3[1:0])
            2'b00:   read_data = funct3[2] ? {24'd0, rd_byte} : {{24{rd_byte[7]}}, rd_byte};
            2'b01:   read_data = funct3[2] ? {16'd0, rd_half} : {{16{rd_half[15]}}, rd_half};
            2'b10:   read_data = word;
            default: read_data = 32'd0;
        endcase
    end

    // ---- Write (synchronous, byte enables) ----
    reg [3:0]  byte_en;
    reg [31:0] wr_data;

    always @(*) begin
        case (funct3[1:0])
            2'b00: begin
                byte_en = 4'b0001 << offset;
                wr_data = {4{write_data[7:0]}};
            end
            2'b01: begin
                byte_en = offset[1] ? 4'b1100 : 4'b0011;
                wr_data = {2{write_data[15:0]}};
            end
            2'b10: begin
                byte_en = 4'b1111;
                wr_data = write_data;
            end
            default: begin
                byte_en = 4'b0000;
                wr_data = write_data;
            end
        endcase
    end

    always @(posedge clk) if (mem_write && byte_en[0]) lane0[word_idx] <= wr_data[7:0];
    always @(posedge clk) if (mem_write && byte_en[1]) lane1[word_idx] <= wr_data[15:8];
    always @(posedge clk) if (mem_write && byte_en[2]) lane2[word_idx] <= wr_data[23:16];
    always @(posedge clk) if (mem_write && byte_en[3]) lane3[word_idx] <= wr_data[31:24];

    // ---- Simulation-only access for testbenches ----
    // Byte-addressed view of the lanes, so testbenches can preload,
    // clear, and inspect memory without knowing its internal layout.
    // Excluded from synthesis; the storage and logic above are the same
    // in simulation and on hardware.
    // synthesis translate_off
    reg [7:0] load_buf [0:8191];
    integer   k;

    function [7:0] peek(input [12:0] a);
        case (a[1:0])
            2'd0: peek = lane0[a[12:2]];
            2'd1: peek = lane1[a[12:2]];
            2'd2: peek = lane2[a[12:2]];
            2'd3: peek = lane3[a[12:2]];
        endcase
    endfunction

    task poke(input [12:0] a, input [7:0] v);
        case (a[1:0])
            2'd0: lane0[a[12:2]] = v;
            2'd1: lane1[a[12:2]] = v;
            2'd2: lane2[a[12:2]] = v;
            2'd3: lane3[a[12:2]] = v;
        endcase
    endtask

    // Same semantics as $readmemh into a byte array: bytes the file
    // doesn't mention keep their current values.
    task load_hex(input [8*256-1:0] filename);
        begin
            for (k = 0; k < 8192; k = k + 1) load_buf[k] = peek(k);
            $readmemh(filename, load_buf);
            for (k = 0; k < 8192; k = k + 1) poke(k, load_buf[k]);
        end
    endtask
    // synthesis translate_on

endmodule
