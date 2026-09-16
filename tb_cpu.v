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

        // Load/store extension to the same program:
        //   addi x1, x0, 100  -> x1 = 100 (base address)
        //   addi x2, x0, 42   -> x2 = 42  (value to store)
        //   sw   x2, 0(x1)    -> mem[100] = 42
        //   lw   x3, 0(x1)    -> x3 = 42  (read back)
        //   addi x4, x0, -5   -> x4 = 0xFFFFFFFB
        //   sb   x4, 4(x1)    -> mem[104] = 0xFB (low byte of x4)
        //   lb   x5, 4(x1)    -> x5 = 0xFFFFFFFB (sign-extended)
        //   lbu  x6, 4(x1)    -> x6 = 0x000000FB (zero-extended)
        uut.imem_inst.mem[7]  = 32'h06400093;
        uut.imem_inst.mem[8]  = 32'h02A00113;
        uut.imem_inst.mem[9]  = 32'h0020A023;
        uut.imem_inst.mem[10] = 32'h0000A183;
        uut.imem_inst.mem[11] = 32'hFFB00213;
        uut.imem_inst.mem[12] = 32'h00408223;
        uut.imem_inst.mem[13] = 32'h00408283;
        uut.imem_inst.mem[14] = 32'h0040C303;

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

        @(posedge clk); @(negedge clk);
        check_reg(5'd1, 32'd100, "ADDI_X1_BASE");

        @(posedge clk); @(negedge clk);
        check_reg(5'd2, 32'd42, "ADDI_X2_VAL");

        @(posedge clk); @(negedge clk);
        // SW doesn't write a register - check the memory word directly
        #1;
        if (uut.dmem_inst.mem[100] !== 8'd42 || uut.dmem_inst.mem[101] !== 8'd0 ||
            uut.dmem_inst.mem[102] !== 8'd0  || uut.dmem_inst.mem[103] !== 8'd0)
            $display("FAIL [SW_STORED_WORD]: mem[100..103] got=%0h %0h %0h %0h",
                      uut.dmem_inst.mem[100], uut.dmem_inst.mem[101],
                      uut.dmem_inst.mem[102], uut.dmem_inst.mem[103]);
        else
            $display("PASS [SW_STORED_WORD]: mem[100..103] = 42,0,0,0");

        @(posedge clk); @(negedge clk);
        check_reg(5'd3, 32'd42, "LW_READBACK");

        @(posedge clk); @(negedge clk);
        check_reg(5'd4, 32'hFFFFFFFB, "ADDI_X4_NEG5");

        @(posedge clk); @(negedge clk);
        #1;
        if (uut.dmem_inst.mem[104] !== 8'hFB)
            $display("FAIL [SB_STORED_BYTE]: mem[104] got=%0h expected=fb",
                      uut.dmem_inst.mem[104]);
        else
            $display("PASS [SB_STORED_BYTE]: mem[104] = fb");

        @(posedge clk); @(negedge clk);
        check_reg(5'd5, 32'hFFFFFFFB, "LB_SIGN_EXTEND");

        @(posedge clk); @(negedge clk);
        check_reg(5'd6, 32'h000000FB, "LBU_ZERO_EXTEND");

        // pc should now sit past all 15 instructions: 15 * 4 = 60
        #1;
        if (uut.pc_curr !== 32'd60)
            $display("FAIL [PC_FINAL]: got=%0d expected=60", uut.pc_curr);
        else
            $display("PASS [PC_FINAL]: pc=%0d", uut.pc_curr);

        $display("Testbench complete.");
        $finish;
    end

endmodule
