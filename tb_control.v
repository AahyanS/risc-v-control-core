// tb_control.v
// Testbench for control.v
//
// Run with:
//   iverilog -o sim_control control.v tb_control.v
//   vvp sim_control
//
// Every line should print PASS. If any line prints FAIL, the printed
// "got" vs "expected" values tell you exactly which case broke.

`timescale 1ns/1ps

module tb_control;

    reg  [6:0] opcode;
    reg  [2:0] funct3;
    reg  [6:0] funct7;
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

    control uut (
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

    task check(input [3:0] exp_alu_ctrl, input exp_alu_src,
               input exp_reg_write, input exp_mem_write,
               input exp_mem_to_reg, input exp_imm_sel,
               input exp_branch, input exp_jump,
               input exp_lui, input exp_auipc,
               input [63:0] opname);
        begin
            #1; // let combinational decode logic settle
            if (alu_ctrl   !== exp_alu_ctrl   || alu_src  !== exp_alu_src  ||
                reg_write  !== exp_reg_write  || mem_write !== exp_mem_write ||
                mem_to_reg !== exp_mem_to_reg || imm_sel   !== exp_imm_sel   ||
                branch     !== exp_branch     || jump      !== exp_jump     ||
                lui        !== exp_lui        || auipc     !== exp_auipc)
                $display("FAIL [%0s]: opcode=%0b funct3=%0b funct7=%0b -> got(alu_ctrl=%0b alu_src=%0b reg_write=%0b mem_write=%0b mem_to_reg=%0b imm_sel=%0b branch=%0b jump=%0b lui=%0b auipc=%0b) expected(alu_ctrl=%0b alu_src=%0b reg_write=%0b mem_write=%0b mem_to_reg=%0b imm_sel=%0b branch=%0b jump=%0b lui=%0b auipc=%0b)",
                          opname, opcode, funct3, funct7,
                          alu_ctrl, alu_src, reg_write, mem_write, mem_to_reg, imm_sel, branch, jump, lui, auipc,
                          exp_alu_ctrl, exp_alu_src, exp_reg_write, exp_mem_write, exp_mem_to_reg, exp_imm_sel, exp_branch, exp_jump, exp_lui, exp_auipc);
            else
                $display("PASS [%0s]: opcode=%0b funct3=%0b funct7=%0b -> alu_ctrl=%0b alu_src=%0b reg_write=%0b mem_write=%0b mem_to_reg=%0b imm_sel=%0b branch=%0b jump=%0b lui=%0b auipc=%0b",
                          opname, opcode, funct3, funct7,
                          alu_ctrl, alu_src, reg_write, mem_write, mem_to_reg, imm_sel, branch, jump, lui, auipc);
        end
    endtask

    initial begin
        // ---- R-type (opcode 0110011): alu_src=0, reg_write=1, all
        // memory/branch/jump/lui/auipc signals stay at their defaults (0) ----

        // ADD: funct3=000, funct7=0000000
        opcode = 7'b0110011; funct3 = 3'b000; funct7 = 7'b0000000;
        check(4'b0000, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, "ADD");

        // SUB: funct3=000, funct7=0100000 (the funct7 tiebreaker)
        opcode = 7'b0110011; funct3 = 3'b000; funct7 = 7'b0100000;
        check(4'b0001, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, "SUB");

        // AND: funct3=111
        opcode = 7'b0110011; funct3 = 3'b111; funct7 = 7'b0000000;
        check(4'b0010, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, "AND");

        // OR: funct3=110
        opcode = 7'b0110011; funct3 = 3'b110; funct7 = 7'b0000000;
        check(4'b0011, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, "OR");

        // XOR: funct3=100
        opcode = 7'b0110011; funct3 = 3'b100; funct7 = 7'b0000000;
        check(4'b0100, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, "XOR");

        // SLL: funct3=001
        opcode = 7'b0110011; funct3 = 3'b001; funct7 = 7'b0000000;
        check(4'b0101, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, "SLL");

        // SRL: funct3=101, funct7=0000000
        opcode = 7'b0110011; funct3 = 3'b101; funct7 = 7'b0000000;
        check(4'b0110, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, "SRL");

        // SRA: funct3=101, funct7=0100000 (the funct7 tiebreaker)
        opcode = 7'b0110011; funct3 = 3'b101; funct7 = 7'b0100000;
        check(4'b0111, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, "SRA");

        // SLT: funct3=010
        opcode = 7'b0110011; funct3 = 3'b010; funct7 = 7'b0000000;
        check(4'b1000, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, "SLT");

        // SLTU: funct3=011
        opcode = 7'b0110011; funct3 = 3'b011; funct7 = 7'b0000000;
        check(4'b1001, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, "SLTU");

        // ---- I-type (opcode 0010011): alu_src=1, reg_write=1 ----

        // ADDI: funct3=000
        opcode = 7'b0010011; funct3 = 3'b000; funct7 = 7'b0000000;
        check(4'b0000, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, "ADDI");

        // ANDI: funct3=111
        opcode = 7'b0010011; funct3 = 3'b111; funct7 = 7'b0000000;
        check(4'b0010, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, "ANDI");

        // ORI: funct3=110
        opcode = 7'b0010011; funct3 = 3'b110; funct7 = 7'b0000000;
        check(4'b0011, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, "ORI");

        // XORI: funct3=100
        opcode = 7'b0010011; funct3 = 3'b100; funct7 = 7'b0000000;
        check(4'b0100, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, "XORI");

        // SLLI: funct3=001
        opcode = 7'b0010011; funct3 = 3'b001; funct7 = 7'b0000000;
        check(4'b0101, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, "SLLI");

        // SRLI: funct3=101, imm[11:5]=0000000
        opcode = 7'b0010011; funct3 = 3'b101; funct7 = 7'b0000000;
        check(4'b0110, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, "SRLI");

        // SRAI: funct3=101, imm[11:5]=0100000
        opcode = 7'b0010011; funct3 = 3'b101; funct7 = 7'b0100000;
        check(4'b0111, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, "SRAI");

        // SLTI: funct3=010
        opcode = 7'b0010011; funct3 = 3'b010; funct7 = 7'b0000000;
        check(4'b1000, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, "SLTI");

        // SLTIU: funct3=011
        opcode = 7'b0010011; funct3 = 3'b011; funct7 = 7'b0000000;
        check(4'b1001, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, "SLTIU");

        // ---- Load (opcode 0000011): always ADD/alu_src=1/reg_write=1/
        // mem_to_reg=1, regardless of funct3 - width is dmem's problem,
        // not control's. Test a few funct3 values to confirm that
        // funct3-independence directly. ----

        opcode = 7'b0000011; funct3 = 3'b010; funct7 = 7'b0000000; // LW
        check(4'b0000, 1'b1, 1'b1, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, "LW");

        opcode = 7'b0000011; funct3 = 3'b000; funct7 = 7'b0000000; // LB
        check(4'b0000, 1'b1, 1'b1, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, "LB");

        opcode = 7'b0000011; funct3 = 3'b100; funct7 = 7'b0000000; // LBU
        check(4'b0000, 1'b1, 1'b1, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, "LBU");

        // ---- Store (opcode 0100011): always ADD/alu_src=1/reg_write=0/
        // mem_write=1/imm_sel=1 (S-type), regardless of funct3 ----

        opcode = 7'b0100011; funct3 = 3'b010; funct7 = 7'b0000000; // SW
        check(4'b0000, 1'b1, 1'b0, 1'b1, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, "SW");

        opcode = 7'b0100011; funct3 = 3'b000; funct7 = 7'b0000000; // SB
        check(4'b0000, 1'b1, 1'b0, 1'b1, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, "SB");

        // ---- Branch (opcode 1100011): alu_src=0, reg_write=0, branch=1.
        // funct3[2:1] selects the ALU op; funct3[0] (the invert bit) is
        // NOT control's job, so BEQ/BNE share alu_ctrl, as do BLT/BGE
        // and BLTU/BGEU. ----

        opcode = 7'b1100011; funct3 = 3'b000; funct7 = 7'b0000000; // BEQ
        check(4'b0001, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, "BEQ");

        opcode = 7'b1100011; funct3 = 3'b001; funct7 = 7'b0000000; // BNE
        check(4'b0001, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, "BNE");

        opcode = 7'b1100011; funct3 = 3'b100; funct7 = 7'b0000000; // BLT
        check(4'b1000, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, "BLT");

        opcode = 7'b1100011; funct3 = 3'b101; funct7 = 7'b0000000; // BGE
        check(4'b1000, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, "BGE");

        opcode = 7'b1100011; funct3 = 3'b110; funct7 = 7'b0000000; // BLTU
        check(4'b1001, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, "BLTU");

        opcode = 7'b1100011; funct3 = 3'b111; funct7 = 7'b0000000; // BGEU
        check(4'b1001, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, "BGEU");

        // ---- JAL (opcode 1101111): reg_write=1, jump=1, ALU signals
        // irrelevant (default) since the target is pc-relative, not
        // ALU-computed ----

        opcode = 7'b1101111; funct3 = 3'b000; funct7 = 7'b0000000;
        check(4'b0000, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, "JAL");

        // ---- JALR (opcode 1100111): reg_write=1, jump=1, alu_src=1,
        // alu_ctrl=ADD (computes rs1+imm for the target) ----

        opcode = 7'b1100111; funct3 = 3'b000; funct7 = 7'b0000000;
        check(4'b0000, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, "JALR");

        // ---- LUI (opcode 0110111): reg_write=1, lui=1, ALU signals
        // irrelevant - rd = imm_u directly, computed entirely in cpu.v ----

        opcode = 7'b0110111; funct3 = 3'b000; funct7 = 7'b0000000;
        check(4'b0000, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0, "LUI");

        // ---- AUIPC (opcode 0010111): reg_write=1, auipc=1, ALU signals
        // irrelevant - rd = pc + imm_u, computed entirely in cpu.v ----

        opcode = 7'b0010111; funct3 = 3'b000; funct7 = 7'b0000000;
        check(4'b0000, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1, "AUIPC");

        // ---- Unrecognized opcode: NOP-like defaults ----
        opcode = 7'b1111111; funct3 = 3'b000; funct7 = 7'b0000000;
        check(4'b0000, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, "UNKNOWN_OPCODE");

        $display("Testbench complete.");
        $finish;
    end

endmodule
