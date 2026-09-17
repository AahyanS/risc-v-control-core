// cpu.v
// Single-cycle RV32I core (R-type/I-type ALU instructions, loads,
// stores, branches, JAL/JALR)
//
// Wires together pc + imem + control + regfile + alu + dmem into a
// working single-cycle CPU covering essentially all of base RV32I.
// LUI/AUIPC are the remaining gap before real assembled programs can
// run without hand-workarounds.

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

    // pc_next's real logic depends on the branch/jump decision, which
    // isn't known until control has decoded the instruction and the ALU
    // has run - see the assign near the bottom of this file.

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

    // B-type immediate (branch target offset): scattered across
    // instr[31] (sign/imm[12]), instr[7] (imm[11]), instr[30:25]
    // (imm[10:5]), instr[11:8] (imm[4:1]). imm[0] is never encoded -
    // it's always 0, since branch targets are halfword-aligned, so the
    // low bit is redundant and the freed encoding space extends range
    // instead. 20 sign-extension bits + 1(imm[11]) + 6(imm[10:5]) +
    // 4(imm[4:1]) + 1(imm[0]=0) = 32.
    wire [31:0] imm_b = {{20{instr[31]}}, instr[7], instr[30:25], instr[11:8], 1'b0};

    // J-type immediate (JAL target offset): same "imm[0] always 0"
    // trick as B-type, scattered even further - instr[31] (imm[20]),
    // instr[19:12] (imm[19:12]), instr[20] (imm[11]), instr[30:21]
    // (imm[10:1]). 12 sign-extension bits + 8(imm[19:12]) + 1(imm[11])
    // + 10(imm[10:1]) + 1(imm[0]=0) = 32.
    wire [31:0] imm_j = {{12{instr[31]}}, instr[19:12], instr[20], instr[30:21], 1'b0};

    // U-type immediate (LUI/AUIPC): the top 20 bits of the instruction
    // ARE the top 20 bits of the result, with the low 12 bits zero-
    // filled - no sign extension needed, since instr[31] already sits
    // exactly where the result's own sign bit belongs.
    wire [31:0] imm_u = {instr[31:12], 12'b0};

    // ---- Control ----

    wire [3:0] alu_ctrl;
    wire       alu_src;
    wire       reg_write;
    wire       mem_write;
    wire       mem_to_reg;
    wire       imm_sel;
    wire       branch;
    wire       jump;
    wire       lui;
    wire       auipc;

    control control_inst (
        .opcode(opcode),
        .funct3(funct3),
        .funct7(funct7),
        .alu_ctrl(alu_ctrl),
        .alu_src(alu_src),
        .reg_write(reg_write),
        .mem_write(mem_write),
        .mem_to_reg(mem_to_reg),
        .imm_sel(imm_sel),
        .branch(branch),
        .jump(jump),
        .lui(lui),
        .auipc(auipc)
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

    // ---- Branch/jump target and pc_next ----

    // Base condition, before accounting for which of a pair is
    // "inverted": funct3[2]=0 selects the equal/not-equal family
    // (control.v picked ALU_SUB, so alu_zero tells us rs1==rs2);
    // funct3[2]=1 selects one of the less-than families (control.v
    // picked SLT or SLTU, whose 1-bit result lives in alu_result[0]).
    wire base_cond = funct3[2] ? alu_result[0] : alu_zero;

    // funct3[0] is the "invert this comparison" bit (BNE vs BEQ,
    // BGE vs BLT, BGEU vs BLTU) - XOR flips base_cond when it's set.
    wire branch_taken = branch & (base_cond ^ funct3[0]);

    // JALR's target is rs1+imm (already computed by the ALU above),
    // with the low bit forced to 0 per the spec; JAL's target is
    // pc-relative instead and never touches the ALU at all.
    wire is_jalr       = (opcode == 7'b1100111);
    wire [31:0] jump_target = is_jalr ? (alu_result & ~32'd1)
                                       : (pc_curr + imm_j);

    assign pc_next = jump         ? jump_target :
                      branch_taken ? (pc_curr + imm_b) :
                                     (pc_curr + 32'd4);

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

    // Write-back source: LUI writes the U-type immediate directly,
    // AUIPC writes pc+imm_u, JAL/JALR write pc+4 (the return address),
    // loads write a memory read, and everything else writes the ALU
    // result.
    wire [31:0] reg_write_data = lui        ? imm_u               :
                                  auipc      ? (pc_curr + imm_u)   :
                                  jump       ? (pc_curr + 32'd4)   :
                                  mem_to_reg ? dmem_read_data      :
                                               alu_result;

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
