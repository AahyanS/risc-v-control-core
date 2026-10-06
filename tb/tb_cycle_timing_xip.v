// tb_cycle_timing_xip.v
// Runs sw/cycle_timing_test.s against cpu_pipeline_xip.v
// (Configuration 1: XIP from flash, no cache at all) - the contrast
// case to tb_cycle_timing_cache.v. With no cache, every fetch pays
// full flash latency every time, so min and max should come out
// close together (no cold/warm split to create a gap) - slower
// overall than the cached configuration, but far more PREDICTABLE,
// which is exactly the tradeoff this project's thesis is about:
// average-case speed vs. worst-case determinism aren't the same
// axis.
//
// Run with:
//   iverilog -o sim_timing_xip rtl/alu.v rtl/regfile.v rtl/control.v rtl/pc.v rtl/dmem.v rtl/spi_flash_ctrl.v tb/spi_flash_model.v rtl/cpu_pipeline_xip.v tb/tb_cycle_timing_xip.v
//   vvp sim_timing_xip

`timescale 1ns/1ps

module tb_cycle_timing_xip;

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

    initial begin
        clk   = 1'b0;
        reset = 1'b1;

        $readmemh("sw/cycle_timing_test.hex", flash.mem);

        @(negedge clk);
        @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        // No caching at all here - every one of ~35 instruction
        // fetches (5 iterations x 7ish instrs) pays full flash
        // latency (~128c). Budget generously.
        for (i = 0; i < 15000; i = i + 1) begin
            @(posedge clk); @(negedge clk);
        end

        $display("min=%0d cycles, max=%0d cycles, sum=%0d cycles over 5 iterations",
                  peek_reg(5'd1), peek_reg(5'd2), peek_reg(5'd3));

        if (peek_reg(5'd1) === 32'h7FFFFFFF)
            $display("FAIL [MIN_WAS_UPDATED]: min still at its sentinel - loop never ran or never updated it");
        else
            $display("PASS [MIN_WAS_UPDATED]: min = %0d", peek_reg(5'd1));

        if (peek_reg(5'd2) === 32'd0)
            $display("FAIL [MAX_WAS_UPDATED]: max still at its initial 0");
        else
            $display("PASS [MAX_WAS_UPDATED]: max = %0d", peek_reg(5'd2));

        // No cache means no cold/warm split - min and max should be
        // close. "Close" here means within 20% of max, a generous
        // margin (loop-carried branch/forwarding timing still varies
        // slightly instruction to instruction).
        if ((peek_reg(5'd2) - peek_reg(5'd1)) * 5 > peek_reg(5'd2))
            $display("FAIL [UNIFORM_TIMING]: max (%0d) and min (%0d) differ by more than 20%% - expected uniform per-fetch cost with no cache",
                      peek_reg(5'd2), peek_reg(5'd1));
        else
            $display("PASS [UNIFORM_TIMING]: max (%0d) and min (%0d) are close - no cache means no cold/warm gap",
                      peek_reg(5'd2), peek_reg(5'd1));

        $display("Testbench complete.");
        $finish;
    end

endmodule
