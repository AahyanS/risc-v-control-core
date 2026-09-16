// tb_cpu.v
// Testbench for cpu.v
//
// Run with:
//   iverilog -o sim_cpu alu.v regfile.v control.v pc.v imem.v cpu.v tb_cpu.v
//   vvp sim_cpu
//
// Every line should print PASS. If any line prints FAIL, the printed
// "got" vs "expected" values tell you exactly which case broke.

`timescale 1ns/1ps

module tb_cpu;

    reg clk;
    reg reset;

    cpu uut (
        .clk(clk),
        .reset(reset)
    );

    always #5 clk = ~clk;

    // Reads a register directly out of the regfile submodule via
    // hierarchical reference - the same trick used to load imem.
    task check_reg(input [4:0] reg_num, input [31:0] exp_val,
                    input [63:0] opname);
        begin
            #1;
            if (uut.regfile_inst.regs[reg_num] !== exp_val)
                $display("FAIL [%0s]: x%0d got=%0h expected=%0h",
                          opname, reg_num,
                          uut.regfile_inst.regs[reg_num], exp_val);
            else
                $display("PASS [%0s]: x%0d = %0h",
                          opname, reg_num, uut.regfile_inst.regs[reg_num]);
        end
    endtask

    initial begin
        clk   = 1'b0;
        reset = 1'b1;

        // Hand-assembled test program, loaded directly into instruction
        // memory (no RISC-V toolchain yet). Encodings verified by hand
        // against the RV32I field layout:
        //   addi x1, x0, 5    -> x1 = 5
        //   addi x2, x0, 10   -> x2 = 10
        //   add  x3, x1, x2   -> x3 = 15
        //   sub  x4, x2, x1   -> x4 = 5
        //   and  x5, x1, x2   -> x5 = 0
        //   or   x6, x1, x2   -> x6 = 15
        //   addi x7, x0, -1   -> x7 = 0xFFFFFFFF
        uut.imem_inst.mem[0] = 32'h00500093;
        uut.imem_inst.mem[1] = 32'h00A00113;
        uut.imem_inst.mem[2] = 32'h002081B3;
        uut.imem_inst.mem[3] = 32'h40110233;
        uut.imem_inst.mem[4] = 32'h0020F2B3;
        uut.imem_inst.mem[5] = 32'h0020E333;
        uut.imem_inst.mem[6] = 32'hFFF00393;

        // Hold reset through one clock edge to establish pc = 0, then
        // release it at a safe (falling-edge) point
        @(negedge clk);
        @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        // Single-cycle core: each subsequent clock edge retires exactly
        // one instruction, in program order
        @(posedge clk); @(negedge clk);
        check_reg(5'd1, 32'd5, "ADDI_X1");

        @(posedge clk); @(negedge clk);
        check_reg(5'd2, 32'd10, "ADDI_X2");

        @(posedge clk); @(negedge clk);
        check_reg(5'd3, 32'd15, "ADD_X3");

        @(posedge clk); @(negedge clk);
        check_reg(5'd4, 32'd5, "SUB_X4");

        @(posedge clk); @(negedge clk);
        check_reg(5'd5, 32'd0, "AND_X5");

        @(posedge clk); @(negedge clk);
        check_reg(5'd6, 32'd15, "OR_X6");

        @(posedge clk); @(negedge clk);
        check_reg(5'd7, 32'hFFFFFFFF, "ADDI_X7_NEG1");

        // pc should now sit past all 7 instructions: 7 * 4 = 28
        #1;
        if (uut.pc_curr !== 32'd28)
            $display("FAIL [PC_FINAL]: got=%0d expected=28", uut.pc_curr);
        else
            $display("PASS [PC_FINAL]: pc=%0d", uut.pc_curr);

        $display("Testbench complete.");
        $finish;
    end

endmodule
