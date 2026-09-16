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
// Reads are combinational (single-cycle design: a loaded value must be
// ready for write-back in the same cycle it's fetched). Writes are
// synchronous, like regfile's write port.

module dmem (
    input         clk,
    input  [31:0] addr,
    input  [31:0] write_data,
    input         mem_write,
    input  [2:0]  funct3,
    output reg [31:0] read_data
);

    // 1024 bytes = 1KB, byte-addressable - same total capacity as
    // imem's 256 words, just a different addressing granularity
    reg [7:0] mem [0:1023];

    // ---- Read (combinational) ----
    always @(*) begin
        case (funct3[1:0])
            2'b00: // byte
                read_data = funct3[2] ? {24'd0, mem[addr]}
                                       : {{24{mem[addr][7]}}, mem[addr]};
            2'b01: // halfword
                read_data = funct3[2] ? {16'd0, mem[addr+1], mem[addr]}
                                       : {{16{mem[addr+1][7]}}, mem[addr+1], mem[addr]};
            2'b10: // word
                read_data = {mem[addr+3], mem[addr+2], mem[addr+1], mem[addr]};
            default:
                read_data = 32'd0;
        endcase
    end

    // ---- Write (synchronous) ----
    always @(posedge clk) begin
        if (mem_write) begin
            case (funct3[1:0])
                2'b00: begin // byte
                    mem[addr] <= write_data[7:0];
                end
                2'b01: begin // halfword
                    mem[addr]   <= write_data[7:0];
                    mem[addr+1] <= write_data[15:8];
                end
                2'b10: begin // word
                    mem[addr]   <= write_data[7:0];
                    mem[addr+1] <= write_data[15:8];
                    mem[addr+2] <= write_data[23:16];
                    mem[addr+3] <= write_data[31:24];
                end
                default: ; // do nothing
            endcase
        end
    end

endmodule
