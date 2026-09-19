// tb_cpu_pipeline_xip.v
// Testbench for cpu_pipeline_xip.v - verifies XIP-from-flash control-
// flow correctness, using sw/pipeline_test.s (the same program
// tb_cpu_pipeline.v uses). Identical checks; the only real
// differences are the flash-model instantiation/wiring in place of
// direct BRAM loading, and a much larger cycle budget, since each
// fetch now costs ~128 cycles instead of 1, and a misprediction costs
// one extra wasted fetch (the speculatively-fetched, now-discarded
// instruction) on top of that.
//
// Run with:
//   iverilog -o sim_xip alu.v regfile.v control.v pc.v dmem.v spi_flash_ctrl.v spi_flash_model.v cpu_pipeline_xip.v tb_cpu_pipeline_xip.v
//   vvp sim_xip

`timescale 1ns/1ps

module tb_cpu_pipeline_xip;

    reg clk;
    reg reset;
    integer i;

    wire sck, cs_n, mosi, miso;

    cpu_pipeline_xip uut (
        .clk(clk),
        .reset(reset),
        .sck(sck), .cs_n(cs_n), .mosi(mosi), .miso(miso)
    );

    spi_flash_model flash (
        .sck(sck), .cs_n(cs_n), .mosi(mosi), .miso(miso)
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

    initial begin
        clk   = 1'b0;
        reset = 1'b1;

        $readmemh("sw/pipeline_test.hex", flash.mem);

        @(negedge clk);
        @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        // ~22 real instructions plus 1 misprediction-driven wasted
        // fetch, at ~130 cycles each - budget generously.
        for (i = 0; i < 4000; i = i + 1) begin
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
