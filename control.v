// control.v
// Control unit for RV32I
//
// Decodes the opcode/funct3/funct7 fields of a fetched instruction and
// drives the ALU operation select and datapath control signals.
// Handles R-type/I-type ALU instructions, loads/stores, branches,
// jumps (JAL/JALR), and LUI/AUIPC - this is essentially all of base
// RV32I.
//
// funct3 is not needed here for loads/stores beyond what's already
// covered by opcode - dmem.v consumes the raw funct3 directly for
// width/signedness, since it's already the exact ISA encoding it needs.
//
// Branch condition evaluation and the pc_next/write-back muxes live in
// cpu.v, not here - this module only decodes "what kind of instruction
// is this," not "was the branch taken."
//
// CSRRW/CSRRS (SYSTEM opcode) are decoded here like any other
// instruction; MRET is NOT, since distinguishing it from ECALL/EBREAK
// needs the raw immediate bits (rs2 field + funct7 combined into
// funct12), which this module doesn't see (only funct7 alone) - kept
// consistent with the existing pattern of raw-bit-pattern decisions
// (immediate assembly, MRET's) living in the CPU top-level file, not
// here.

module control (
    input  [6:0] opcode,
    input  [2:0] funct3,
    input  [6:0] funct7,
    output reg [3:0] alu_ctrl,
    output reg       alu_src,
    output reg       reg_write,
    output reg       mem_write,
    output reg       mem_to_reg,
    output reg       imm_sel,
    output reg       branch,
    output reg       jump,
    output reg       lui,
    output reg       auipc,
    output reg       is_csr,
    output reg       csr_set_mode   // 0 = CSRRW (write rs1 verbatim), 1 = CSRRS (write old|rs1)
);

    // Opcodes handled so far
    localparam OPCODE_R_TYPE = 7'b0110011;
    localparam OPCODE_I_TYPE = 7'b0010011;
    localparam OPCODE_LOAD   = 7'b0000011;
    localparam OPCODE_STORE  = 7'b0100011;
    localparam OPCODE_BRANCH = 7'b1100011;
    localparam OPCODE_JAL    = 7'b1101111;
    localparam OPCODE_JALR   = 7'b1100111;
    localparam OPCODE_LUI    = 7'b0110111;
    localparam OPCODE_AUIPC  = 7'b0010111;
    localparam OPCODE_SYSTEM = 7'b1110011;

    // ALU op used for address calculation on every load/store/JALR:
    // rs1 + imm
    localparam ALU_ADD  = 4'b0000;
    localparam ALU_SUB  = 4'b0001;
    localparam ALU_SLT  = 4'b1000;
    localparam ALU_SLTU = 4'b1001;

    // funct7 value that marks the "alternate" op within a funct3 group
    // (SUB instead of ADD, SRA instead of SRL)
    localparam FUNCT7_ALT = 7'b0100000;

    always @(*) begin
        // Defaults: behave like a NOP for any opcode not yet handled
        // (branches/jumps aren't wired up yet)
        alu_ctrl   = 4'b0000;
        alu_src    = 1'b0;
        reg_write  = 1'b0;
        mem_write  = 1'b0;
        mem_to_reg = 1'b0;
        imm_sel    = 1'b0; // 0 = I-type immediate (the only format used so far)
        branch     = 1'b0;
        jump       = 1'b0;
        lui        = 1'b0;
        auipc      = 1'b0;
        is_csr     = 1'b0;
        csr_set_mode = 1'b0;

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

            OPCODE_LOAD: begin
                reg_write  = 1'b1;
                alu_src    = 1'b1;    // ALU computes rs1 + imm (address)
                alu_ctrl   = ALU_ADD;
                mem_to_reg = 1'b1;    // write-back comes from dmem, not the ALU
            end

            OPCODE_STORE: begin
                reg_write  = 1'b0;    // stores don't write a register
                alu_src    = 1'b1;    // ALU computes rs1 + imm (address)
                alu_ctrl   = ALU_ADD;
                mem_write  = 1'b1;
                imm_sel    = 1'b1; // S-type immediate, not I-type
            end

            OPCODE_BRANCH: begin
                branch  = 1'b1;
                alu_src = 1'b0; // compare rs1 directly against rs2
                // funct3[2:1] picks the comparison family; funct3[0]
                // (whether this branch is the "inverted" variant, e.g.
                // BNE vs BEQ) is handled in cpu.v, not here - this
                // only needs to pick which ALU op computes the
                // underlying comparison.
                case (funct3[2:1])
                    2'b00:   alu_ctrl = ALU_SUB;  // BEQ/BNE: compare via subtraction + zero flag
                    2'b10:   alu_ctrl = ALU_SLT;  // BLT/BGE: signed less-than
                    2'b11:   alu_ctrl = ALU_SLTU; // BLTU/BGEU: unsigned less-than
                    default: alu_ctrl = ALU_SUB;
                endcase
            end

            OPCODE_JAL: begin
                reg_write = 1'b1; // writes pc+4 into rd (the return address)
                jump      = 1'b1;
            end

            OPCODE_JALR: begin
                reg_write = 1'b1; // writes pc+4 into rd (the return address)
                jump      = 1'b1;
                alu_src   = 1'b1; // ALU computes rs1 + imm (jump target)
                alu_ctrl  = ALU_ADD;
                // imm_sel stays 0 (I-type immediate) - JALR reuses the
                // same contiguous 12-bit layout as loads/ADDI
            end

            OPCODE_LUI: begin
                reg_write = 1'b1; // rd = imm_u directly, no ALU involved
                lui       = 1'b1;
            end

            OPCODE_AUIPC: begin
                reg_write = 1'b1; // rd = pc + imm_u, computed in cpu.v
                auipc     = 1'b1;
            end

            OPCODE_SYSTEM: begin
                // funct3==000 (ECALL/EBREAK/MRET/WFI) is deliberately
                // NOT decoded here - MRET is picked out directly from
                // the raw instruction bits in the CPU top-level file
                // (see this file's header comment); ECALL/EBREAK/WFI
                // aren't used by anything in this project (the
                // compliance suite uses its own memory-mapped
                // pass/fail harness, not ECALL) and fall through to
                // the NOP-like defaults, same as any other
                // unrecognized encoding.
                case (funct3)
                    3'b001: begin // CSRRW
                        reg_write = 1'b1;
                        is_csr    = 1'b1;
                    end
                    3'b010: begin // CSRRS
                        reg_write    = 1'b1;
                        is_csr       = 1'b1;
                        csr_set_mode = 1'b1;
                    end
                    default: ; // CSRRC and the immediate-operand CSR
                               // variants aren't needed by anything
                               // this project writes - deferred, same
                               // as other "simple subset first" calls
                endcase
            end

            default: ; // unrecognized opcode: keep the NOP-like defaults above
        endcase
    end

endmodule
