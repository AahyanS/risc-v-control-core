// tb_cpu_pipeline.v
// Testbench for cpu_pipeline.v - verifies the pipeline skeleton and
// its control-flow flush mechanism, using sw/pipeline_test.s, a
// program deliberately spaced out to avoid data hazards (this
// pipeline version has no forwarding yet).
//
// Run with:
//   iverilog -o sim_pipeline rtl/alu.v rtl/regfile.v rtl/control.v rtl/pc.v rtl/imem.v rtl/dmem.v rtl/cpu_pipeline.v tb/tb_cpu_pipeline.v
//   vvp sim_pipeline

`timescale 1ns/1ps

module tb_cpu_pipeline;

    reg clk;
    reg reset;

    cpu_pipeline uut (
        .clk(clk),
        .reset(reset)
    );

    always #5 clk = ~clk;

    function [31:0] peek_reg(input [4:0] reg_num);
        peek_reg = (reg_num == 5'd0) ? 32'd0 : uut.regfile_inst.regs[reg_num];
    endfunction

    task check_reg(input [4:0] reg_num, input [31:0] exp_val,
                    input [63:0] opname);
        begin
            if (peek_reg(reg_num) !== exp_val)
                $display("FAIL [%0s]: x%0d got=%0h expected=%0h",
                          opname, reg_num, peek_reg(reg_num), exp_val);
            else
                $display("PASS [%0s]: x%0d = %0h",
                          opname, reg_num, peek_reg(reg_num));
        end
    endtask

    // For a register a squashed instruction WOULD have written: this
    // core never resets general-purpose registers (only x0's read is
    // hardwired - see docs/DESIGN_LOG.md/cosim's own mismatch that found the
    // same thing), so if the squash worked, the register is simply
    // never written at all (reads as 'x', not 0). The real invariant
    // to check is "the skipped value never landed."
    task check_reg_not(input [4:0] reg_num, input [31:0] bad_val,
                        input [63:0] opname);
        begin
            if (peek_reg(reg_num) === bad_val)
                $display("FAIL [%0s]: x%0d got=%0h - squashed write escaped!",
                          opname, reg_num, peek_reg(reg_num));
            else
                $display("PASS [%0s]: x%0d = %0h (not the skipped value %0h)",
                          opname, reg_num, peek_reg(reg_num), bad_val);
        end
    endtask

    integer i;

    initial begin
        clk   = 1'b0;
        reset = 1'b1;

        $readmemh("sw/pipeline_test.hex", uut.imem_inst.mem);

        @(negedge clk);
        @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        // The program ends in an infinite self-loop, so run a
        // generous number of cycles rather than hand-counting the
        // exact retirement schedule (pipeline fill latency plus two
        // 2-cycle flush bubbles makes that fiddly and easy to get
        // wrong by one).
        for (i = 0; i < 80; i = i + 1) begin
            @(posedge clk); @(negedge clk);
        end

        check_reg(5'd1,  32'd5,   "X1_BASE");
        check_reg(5'd5,  32'd15,  "X5_HAZARD_FREE_READ");
        check_reg_not(5'd7, 32'd999, "X7_SKIPPED_BY_TAKEN_BRANCH");
        check_reg(5'd8,  32'd111, "X8_TAKEN_BRANCH_TARGET");
        check_reg(5'd9,  32'd222, "X9_NOT_TAKEN_BRANCH_FALLTHROUGH");
        check_reg(5'd10, 32'd333, "X10_ALWAYS_RUNS");
        check_reg(5'd11, 32'd84,  "X11_JAL_LINK_ADDR");
        check_reg_not(5'd12, 32'd444, "X12_SKIPPED_BY_JAL");
        check_reg(5'd13, 32'd555, "X13_JAL_TARGET");

        $display("Testbench complete.");
        $finish;
    end

endmodule
