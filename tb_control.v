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

    control uut (
        .opcode(opcode),
        .funct3(funct3),
        .funct7(funct7),
        .alu_ctrl(alu_ctrl),
        .alu_src(alu_src),
        .reg_write(reg_write)
    );

    task check(input [3:0] exp_alu_ctrl, input exp_alu_src,
               input exp_reg_write, input [63:0] opname);
        begin
            #1; // let combinational decode logic settle
            if (alu_ctrl !== exp_alu_ctrl || alu_src !== exp_alu_src ||
                reg_write !== exp_reg_write)
                $display("FAIL [%0s]: opcode=%0b funct3=%0b funct7=%0b -> got(alu_ctrl=%0b alu_src=%0b reg_write=%0b) expected(alu_ctrl=%0b alu_src=%0b reg_write=%0b)",
                          opname, opcode, funct3, funct7,
                          alu_ctrl, alu_src, reg_write,
                          exp_alu_ctrl, exp_alu_src, exp_reg_write);
            else
                $display("PASS [%0s]: opcode=%0b funct3=%0b funct7=%0b -> alu_ctrl=%0b alu_src=%0b reg_write=%0b",
                          opname, opcode, funct3, funct7,
                          alu_ctrl, alu_src, reg_write);
        end
    endtask

    initial begin
        // ---- R-type (opcode 0110011): alu_src=0, reg_write=1 ----

        // ADD: funct3=000, funct7=0000000
        opcode = 7'b0110011; funct3 = 3'b000; funct7 = 7'b0000000;
        check(4'b0000, 1'b0, 1'b1, "ADD");

        // SUB: funct3=000, funct7=0100000 (the funct7 tiebreaker)
        opcode = 7'b0110011; funct3 = 3'b000; funct7 = 7'b0100000;
        check(4'b0001, 1'b0, 1'b1, "SUB");

        // AND: funct3=111
        opcode = 7'b0110011; funct3 = 3'b111; funct7 = 7'b0000000;
        check(4'b0010, 1'b0, 1'b1, "AND");

        // OR: funct3=110
        opcode = 7'b0110011; funct3 = 3'b110; funct7 = 7'b0000000;
        check(4'b0011, 1'b0, 1'b1, "OR");

        // XOR: funct3=100
        opcode = 7'b0110011; funct3 = 3'b100; funct7 = 7'b0000000;
        check(4'b0100, 1'b0, 1'b1, "XOR");

        // SLL: funct3=001
        opcode = 7'b0110011; funct3 = 3'b001; funct7 = 7'b0000000;
        check(4'b0101, 1'b0, 1'b1, "SLL");

        // SRL: funct3=101, funct7=0000000
        opcode = 7'b0110011; funct3 = 3'b101; funct7 = 7'b0000000;
        check(4'b0110, 1'b0, 1'b1, "SRL");

        // SRA: funct3=101, funct7=0100000 (the funct7 tiebreaker)
        opcode = 7'b0110011; funct3 = 3'b101; funct7 = 7'b0100000;
        check(4'b0111, 1'b0, 1'b1, "SRA");

        // SLT: funct3=010
        opcode = 7'b0110011; funct3 = 3'b010; funct7 = 7'b0000000;
        check(4'b1000, 1'b0, 1'b1, "SLT");

        // SLTU: funct3=011
        opcode = 7'b0110011; funct3 = 3'b011; funct7 = 7'b0000000;
        check(4'b1001, 1'b0, 1'b1, "SLTU");

        // ---- I-type (opcode 0010011): alu_src=1, reg_write=1 ----

        // ADDI: funct3=000
        opcode = 7'b0010011; funct3 = 3'b000; funct7 = 7'b0000000;
        check(4'b0000, 1'b1, 1'b1, "ADDI");

        // ANDI: funct3=111
        opcode = 7'b0010011; funct3 = 3'b111; funct7 = 7'b0000000;
        check(4'b0010, 1'b1, 1'b1, "ANDI");

        // ORI: funct3=110
        opcode = 7'b0010011; funct3 = 3'b110; funct7 = 7'b0000000;
        check(4'b0011, 1'b1, 1'b1, "ORI");

        // XORI: funct3=100
        opcode = 7'b0010011; funct3 = 3'b100; funct7 = 7'b0000000;
        check(4'b0100, 1'b1, 1'b1, "XORI");

        // SLLI: funct3=001
        opcode = 7'b0010011; funct3 = 3'b001; funct7 = 7'b0000000;
        check(4'b0101, 1'b1, 1'b1, "SLLI");

        // SRLI: funct3=101, imm[11:5]=0000000
        opcode = 7'b0010011; funct3 = 3'b101; funct7 = 7'b0000000;
        check(4'b0110, 1'b1, 1'b1, "SRLI");

        // SRAI: funct3=101, imm[11:5]=0100000
        opcode = 7'b0010011; funct3 = 3'b101; funct7 = 7'b0100000;
        check(4'b0111, 1'b1, 1'b1, "SRAI");

        // SLTI: funct3=010
        opcode = 7'b0010011; funct3 = 3'b010; funct7 = 7'b0000000;
        check(4'b1000, 1'b1, 1'b1, "SLTI");

        // SLTIU: funct3=011
        opcode = 7'b0010011; funct3 = 3'b011; funct7 = 7'b0000000;
        check(4'b1001, 1'b1, 1'b1, "SLTIU");

        // ---- Unrecognized opcode: NOP-like defaults ----
        opcode = 7'b1111111; funct3 = 3'b000; funct7 = 7'b0000000;
        check(4'b0000, 1'b0, 1'b0, "UNKNOWN_OPCODE");

        $display("Testbench complete.");
        $finish;
    end

endmodule
