// tb_alu.v
// Testbench for alu.v
//
// Run with:
//   iverilog -o sim_alu alu.v tb_alu.v
//   vvp sim_alu
//
// Every line should print PASS. If any line prints FAIL, the printed
// "got" vs "expected" values tell you exactly which case broke.

`timescale 1ns/1ps

module tb_alu;

    reg  [31:0] a, b;
    reg  [3:0]  alu_ctrl;
    wire [31:0] result;
    wire        zero;

    // Instantiate the ALU under test
    alu uut (
        .a(a),
        .b(b),
        .alu_ctrl(alu_ctrl),
        .result(result),
        .zero(zero)
    );

    // opname is a plain reg sized to hold an 8-character ASCII string,
    // so this works in plain Verilog (no SystemVerilog string type needed)
    task check(input [31:0] exp_result, input [63:0] opname);
        begin
            #1; // let combinational logic settle
            if (result !== exp_result)
                $display("FAIL [%0s]: a=%0d b=%0d -> got=%0d expected=%0d",
                          opname, $signed(a), $signed(b), result, exp_result);
            else
                $display("PASS [%0s]: a=%0d b=%0d -> result=%0d",
                          opname, $signed(a), $signed(b), result);
        end
    endtask

    initial begin
        // ADD: 10 + 5 = 15
        a = 32'd10; b = 32'd5; alu_ctrl = 4'b0000;
        check(32'd15, "ADD");

        // SUB: 10 - 5 = 5
        a = 32'd10; b = 32'd5; alu_ctrl = 4'b0001;
        check(32'd5, "SUB");

        // AND
        a = 32'hFF00FF00; b = 32'h0F0F0F0F; alu_ctrl = 4'b0010;
        check(32'h0F000F00, "AND");

        // OR
        a = 32'hFF00FF00; b = 32'h0F0F0F0F; alu_ctrl = 4'b0011;
        check(32'hFF0FFF0F, "OR");

        // XOR
        a = 32'hFF00FF00; b = 32'h0F0F0F0F; alu_ctrl = 4'b0100;
        check(32'hF00FF00F, "XOR");

        // SLL: 1 << 4 = 16
        a = 32'h00000001; b = 32'd4; alu_ctrl = 4'b0101;
        check(32'h00000010, "SLL");

        // SRL: 0x80000000 >> 4 = 0x08000000 (zero-filled from the top)
        a = 32'h80000000; b = 32'd4; alu_ctrl = 4'b0110;
        check(32'h08000000, "SRL");

        // SRA: 0x80000000 (negative) >>> 4 = 0xF8000000 (sign-extended)
        a = 32'h80000000; b = 32'd4; alu_ctrl = 4'b0111;
        check(32'hF8000000, "SRA");

        // SLT (signed): -1 < 1 -> true (1)
        a = 32'hFFFFFFFF; b = 32'd1; alu_ctrl = 4'b1000;
        check(32'd1, "SLT");

        // SLTU (unsigned): 0xFFFFFFFF is huge unsigned, NOT < 1 -> false (0)
        a = 32'hFFFFFFFF; b = 32'd1; alu_ctrl = 4'b1001;
        check(32'd0, "SLTU");

        // zero flag check: SUB where a == b should give zero=1
        a = 32'd7; b = 32'd7; alu_ctrl = 4'b0001;
        #1;
        if (zero !== 1'b1)
            $display("FAIL [ZERO FLAG]: expected zero=1, got zero=%0b", zero);
        else
            $display("PASS [ZERO FLAG]: zero=1 as expected");

        $display("Testbench complete.");
        $finish;
    end

endmodule
