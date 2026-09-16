// cpu.v
// Single-cycle RV32I core (R-type/I-type ALU instructions only)
//
// Wires together pc + imem + control + regfile + alu into a working
// (if limited) CPU. No branches/jumps/loads/stores yet - those need
// data memory and branch-target logic that don't exist yet.

module cpu (
    input clk,
    input reset
);

    // ---- Fetch ----

    wire [31:0] pc_curr;
    wire [31:0] pc_next;
    wire [31:0] instr;

    pc pc_reg (
        .clk(clk),
        .reset(reset),
        .pc_next(pc_next),
        .pc(pc_curr)
    );

    imem imem_inst (
        .addr(pc_curr),
        .instr(instr)
    );

    // No branches/jumps decoded yet, so always step forward by 4
    assign pc_next = pc_curr + 32'd4;

    // ---- Decode ----

    wire [6:0] opcode = instr[6:0];
    wire [4:0] rd     = instr[11:7];
    wire [2:0] funct3 = instr[14:12];
    wire [4:0] rs1    = instr[19:15];
    wire [4:0] rs2    = instr[24:20];
    wire [6:0] funct7 = instr[31:25];

    // I-type immediate (instr[31:20]), sign-extended to 32 bits
    wire [31:0] imm_i = {{20{instr[31]}}, instr[31:20]};

    // ---- Control ----

    wire [3:0] alu_ctrl;
    wire       alu_src;
    wire       reg_write;

    control control_inst (
        .opcode(opcode),
        .funct3(funct3),
        .funct7(funct7),
        .alu_ctrl(alu_ctrl),
        .alu_src(alu_src),
        .reg_write(reg_write)
    );

    // ---- Register read / Execute / Register write-back ----

    wire [31:0] rs1_data;
    wire [31:0] rs2_data;
    wire [31:0] alu_b;
    wire [31:0] alu_result;
    wire        alu_zero;

    // ALU's 2nd operand: rs2 for R-type, sign-extended imm for I-type
    assign alu_b = alu_src ? imm_i : rs2_data;

    alu alu_inst (
        .a(rs1_data),
        .b(alu_b),
        .alu_ctrl(alu_ctrl),
        .result(alu_result),
        .zero(alu_zero)
    );

    regfile regfile_inst (
        .clk(clk),
        .we(reg_write),
        .rs1_addr(rs1),
        .rs2_addr(rs2),
        .rd_addr(rd),
        .rd_data(alu_result),
        .rs1_data(rs1_data),
        .rs2_data(rs2_data)
    );

endmodule
