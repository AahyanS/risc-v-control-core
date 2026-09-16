// cpu.v
// Single-cycle RV32I core (R-type/I-type ALU instructions, loads,
// stores)
//
// Wires together pc + imem + control + regfile + alu + dmem into a
// working (if limited) CPU. No branches/jumps yet - those need
// PC-relative branch-target logic that doesn't exist yet.

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

    // S-type immediate: split across instr[31:25] (high bits) and
    // instr[11:7] (low bits) - those positions are rs2/rd for R-type,
    // so S-type reassembles its immediate around them. Same 20-bit
    // sign extension as imm_i once reassembled.
    wire [31:0] imm_s = {{20{instr[31]}}, instr[31:25], instr[11:7]};

    // ---- Control ----

    wire [3:0] alu_ctrl;
    wire       alu_src;
    wire       reg_write;
    wire       mem_write;
    wire       mem_to_reg;
    wire       imm_sel;

    control control_inst (
        .opcode(opcode),
        .funct3(funct3),
        .funct7(funct7),
        .alu_ctrl(alu_ctrl),
        .alu_src(alu_src),
        .reg_write(reg_write),
        .mem_write(mem_write),
        .mem_to_reg(mem_to_reg),
        .imm_sel(imm_sel)
    );

    // Selects which immediate format to use, per control's decode.
    // Only I-type and S-type exist so far.
    wire [31:0] imm = imm_sel ? imm_s : imm_i;

    // ---- Register read / Execute / Register write-back ----

    wire [31:0] rs1_data;
    wire [31:0] rs2_data;
    wire [31:0] alu_b;
    wire [31:0] alu_result;
    wire        alu_zero;

    // ALU's 2nd operand: rs2 for R-type, the selected immediate for
    // I-type/load/store (load/store both use it as an address offset)
    assign alu_b = alu_src ? imm : rs2_data;

    alu alu_inst (
        .a(rs1_data),
        .b(alu_b),
        .alu_ctrl(alu_ctrl),
        .result(alu_result),
        .zero(alu_zero)
    );

    // ---- Data memory ----

    wire [31:0] dmem_read_data;

    dmem dmem_inst (
        .clk(clk),
        .addr(alu_result),       // rs1 + imm, computed by the ALU above
        .write_data(rs2_data),   // the value a store writes
        .mem_write(mem_write),
        .funct3(funct3),         // raw width/signedness encoding
        .read_data(dmem_read_data)
    );

    // Write-back source: the ALU result normally, or a memory read for
    // loads
    wire [31:0] reg_write_data = mem_to_reg ? dmem_read_data : alu_result;

    regfile regfile_inst (
        .clk(clk),
        .we(reg_write),
        .rs1_addr(rs1),
        .rs2_addr(rs2),
        .rd_addr(rd),
        .rd_data(reg_write_data),
        .rs1_data(rs1_data),
        .rs2_data(rs2_data)
    );

endmodule
