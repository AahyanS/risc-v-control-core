// alu.v
// 32-bit ALU for RV32I
//
// Supports the core arithmetic/logic operations RV32I needs:
// ADD, SUB, AND, OR, XOR, SLL, SRL, SRA, SLT, SLTU
//
// alu_ctrl selects the operation. Encoding is arbitrary here -
// you'll wire it up to your control unit later, once you design
// how instructions map to ALU operations.

module alu (
    input  [31:0] a,          // first operand (e.g. rs1)
    input  [31:0] b,          // second operand (e.g. rs2 or immediate)
    input  [3:0]  alu_ctrl,   // operation select
    output reg [31:0] result, // ALU output
    output        zero        // 1 if result == 0 (used for branches later)
);

    // Operation encodings
    localparam ALU_ADD  = 4'b0000;
    localparam ALU_SUB  = 4'b0001;
    localparam ALU_AND  = 4'b0010;
    localparam ALU_OR   = 4'b0011;
    localparam ALU_XOR  = 4'b0100;
    localparam ALU_SLL  = 4'b0101; // shift left logical
    localparam ALU_SRL  = 4'b0110; // shift right logical
    localparam ALU_SRA  = 4'b0111; // shift right arithmetic
    localparam ALU_SLT  = 4'b1000; // set less than (signed)
    localparam ALU_SLTU = 4'b1001; // set less than (unsigned)

    always @(*) begin
        case (alu_ctrl)
            ALU_ADD:  result = a + b;
            ALU_SUB:  result = a - b;
            ALU_AND:  result = a & b;
            ALU_OR:   result = a | b;
            ALU_XOR:  result = a ^ b;
            // RV32I only uses the low 5 bits of the shift amount (shifts 0-31)
            ALU_SLL:  result = a << b[4:0];
            ALU_SRL:  result = a >> b[4:0];
            ALU_SRA:  result = $signed(a) >>> b[4:0];
            ALU_SLT:  result = ($signed(a) < $signed(b)) ? 32'd1 : 32'd0;
            ALU_SLTU: result = (a < b) ? 32'd1 : 32'd0;
            default:  result = 32'd0;
        endcase
    end

    assign zero = (result == 32'd0);

endmodule
