// control.v
// Control unit for RV32I
//
// Decodes the opcode/funct3/funct7 fields of a fetched instruction and
// drives the ALU operation select and datapath control signals.
// Currently handles R-type and I-type ALU instructions only (no
// branches/loads/stores/jumps yet - those need the PC and memory).

module control (
    input  [6:0] opcode,
    input  [2:0] funct3,
    input  [6:0] funct7,
    output reg [3:0] alu_ctrl,
    output reg       alu_src,
    output reg       reg_write
);

    // R-type and I-type opcodes (ALU-op instructions only, for now)
    localparam OPCODE_R_TYPE = 7'b0110011;
    localparam OPCODE_I_TYPE = 7'b0010011;

    // funct7 value that marks the "alternate" op within a funct3 group
    // (SUB instead of ADD, SRA instead of SRL)
    localparam FUNCT7_ALT = 7'b0100000;

    always @(*) begin
        // Defaults: behave like a NOP for any opcode not yet handled
        // (branches/loads/stores/jumps aren't wired up yet)
        alu_ctrl  = 4'b0000;
        alu_src   = 1'b0;
        reg_write = 1'b0;

        case (opcode)
            OPCODE_R_TYPE: begin
                reg_write = 1'b1;
                alu_src   = 1'b0; // ALU's 2nd operand is rs2
                case (funct3)
                    3'b000:  alu_ctrl = (funct7 == FUNCT7_ALT) ? 4'b0001 : 4'b0000; // SUB : ADD
                    3'b001:  alu_ctrl = 4'b0101; // SLL
                    3'b010:  alu_ctrl = 4'b1000; // SLT
                    3'b011:  alu_ctrl = 4'b1001; // SLTU
                    3'b100:  alu_ctrl = 4'b0100; // XOR
                    3'b101:  alu_ctrl = (funct7 == FUNCT7_ALT) ? 4'b0111 : 4'b0110; // SRA : SRL
                    3'b110:  alu_ctrl = 4'b0011; // OR
                    3'b111:  alu_ctrl = 4'b0010; // AND
                    default: alu_ctrl = 4'b0000;
                endcase
            end

            OPCODE_I_TYPE: begin
                reg_write = 1'b1;
                alu_src   = 1'b1; // ALU's 2nd operand is the immediate
                case (funct3)
                    3'b000:  alu_ctrl = 4'b0000; // ADDI
                    3'b001:  alu_ctrl = 4'b0101; // SLLI
                    3'b010:  alu_ctrl = 4'b1000; // SLTI
                    3'b011:  alu_ctrl = 4'b1001; // SLTIU
                    3'b100:  alu_ctrl = 4'b0100; // XORI
                    3'b101:  alu_ctrl = (funct7 == FUNCT7_ALT) ? 4'b0111 : 4'b0110; // SRAI : SRLI
                    3'b110:  alu_ctrl = 4'b0011; // ORI
                    3'b111:  alu_ctrl = 4'b0010; // ANDI
                    default: alu_ctrl = 4'b0000;
                endcase
            end

            default: ; // unrecognized opcode: keep the NOP-like defaults above
        endcase
    end

endmodule
