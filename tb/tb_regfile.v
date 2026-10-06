// tb_regfile.v
// Testbench for regfile.v
//
// Run with:
//   iverilog -o sim_regfile rtl/regfile.v tb/tb_regfile.v
//   vvp sim_regfile
//
// Every line should print PASS. If any line prints FAIL, the printed
// "got" vs "expected" values tell you exactly which case broke.

`timescale 1ns/1ps

module tb_regfile;

    reg         clk;
    reg         we;
    reg  [4:0]  rs1_addr, rs2_addr, rd_addr;
    reg  [31:0] rd_data;
    wire [31:0] rs1_data, rs2_data;

    regfile uut (
        .clk(clk),
        .we(we),
        .rs1_addr(rs1_addr),
        .rs2_addr(rs2_addr),
        .rd_addr(rd_addr),
        .rd_data(rd_data),
        .rs1_data(rs1_data),
        .rs2_data(rs2_data)
    );

    // 10ns period clock
    always #5 clk = ~clk;

    task check_rs1(input [31:0] exp_result, input [63:0] opname);
        begin
            #1; // let combinational reads settle
            if (rs1_data !== exp_result)
                $display("FAIL [%0s]: rs1_addr=%0d -> got=%0d expected=%0d",
                          opname, rs1_addr, rs1_data, exp_result);
            else
                $display("PASS [%0s]: rs1_addr=%0d -> rs1_data=%0d",
                          opname, rs1_addr, rs1_data);
        end
    endtask

    task check_rs2(input [31:0] exp_result, input [63:0] opname);
        begin
            #1;
            if (rs2_data !== exp_result)
                $display("FAIL [%0s]: rs2_addr=%0d -> got=%0d expected=%0d",
                          opname, rs2_addr, rs2_data, exp_result);
            else
                $display("PASS [%0s]: rs2_addr=%0d -> rs2_data=%0d",
                          opname, rs2_addr, rs2_data);
        end
    endtask

    // Writes a value into rd_addr on one posedge, with we held high.
    task write_reg(input [4:0] addr, input [31:0] data);
        begin
            @(negedge clk);
            rd_addr = addr;
            rd_data = data;
            we      = 1'b1;
            @(posedge clk);
            @(negedge clk);
            we      = 1'b0;
        end
    endtask

    initial begin
        clk      = 1'b0;
        we       = 1'b0;
        rs1_addr = 5'd0;
        rs2_addr = 5'd0;
        rd_addr  = 5'd0;
        rd_data  = 32'd0;

        // x0 reads zero before anything is ever written
        rs1_addr = 5'd0;
        check_rs1(32'd0, "X0_INITIAL");

        // Write 0xDEADBEEF into x5, then read it back on rs1
        write_reg(5'd5, 32'hDEADBEEF);
        rs1_addr = 5'd5;
        check_rs1(32'hDEADBEEF, "WRITE_THEN_READ_RS1");

        // Same value should be visible on rs2 (independent read port)
        rs2_addr = 5'd5;
        check_rs2(32'hDEADBEEF, "WRITE_THEN_READ_RS2");

        // Attempt to write x0 - must be ignored, x0 still reads zero
        write_reg(5'd0, 32'hFFFFFFFF);
        rs1_addr = 5'd0;
        check_rs1(32'd0, "X0_WRITE_IGNORED");

        // Two different registers read simultaneously on the two ports
        write_reg(5'd10, 32'h11111111);
        write_reg(5'd20, 32'h22222222);
        rs1_addr = 5'd10;
        rs2_addr = 5'd20;
        check_rs1(32'h11111111, "DUAL_PORT_RS1");
        check_rs2(32'h22222222, "DUAL_PORT_RS2");

        // Both read ports pointed at the same nonzero register
        rs1_addr = 5'd10;
        rs2_addr = 5'd10;
        check_rs1(32'h11111111, "SAME_ADDR_RS1");
        check_rs2(32'h11111111, "SAME_ADDR_RS2");

        // With we deasserted, a write attempt must not change the register
        @(negedge clk);
        rd_addr = 5'd10;
        rd_data = 32'hBAD00BAD;
        we      = 1'b0;
        @(posedge clk);
        @(negedge clk);
        rs1_addr = 5'd10;
        check_rs1(32'h11111111, "WRITE_DISABLED_NO_CHANGE");

        // Overwrite an already-written register with a new value
        write_reg(5'd10, 32'h33333333);
        rs1_addr = 5'd10;
        check_rs1(32'h33333333, "OVERWRITE");

        $display("Testbench complete.");
        $finish;
    end

endmodule
