// tb_cycle_timing_cache.v
// Runs sw/cycle_timing_test.s against cpu_pipeline_cache.v
// (Configuration 2: cache, no locking) and checks the min/max/sum
// results the program itself computed using the memory-mapped cycle
// counter - proving the instrumentation is actually usable for real
// measurement, not just that the counter increments.
//
// Expected story: iteration 0's loop body is an uncached miss (the
// first time these addresses are fetched), so its delta should be
// much larger than later iterations, which hit the now-warm cache.
// max should therefore be substantially bigger than min - a direct,
// concrete demonstration of the exact "average case great, first
// time is a jitter spike" behavior this project's thesis is about.
//
// Run with:
//   iverilog -o sim_timing_cache rtl/alu.v rtl/regfile.v rtl/control.v rtl/pc.v rtl/dmem.v rtl/spi_flash_ctrl.v tb/spi_flash_model.v rtl/icache.v rtl/cpu_pipeline_cache.v tb/tb_cycle_timing_cache.v
//   vvp sim_timing_cache

`timescale 1ns/1ps

module tb_cycle_timing_cache;

    reg clk;
    reg reset;
    integer i;

    wire sck, cs_n, mosi, miso;

    cpu_pipeline_cache uut (
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

        // 5 iterations, worst case ~7 instructions each with at least
        // one line-fill miss (~512c) among them - budget generously.
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

        if (peek_reg(5'd2) <= peek_reg(5'd1))
            $display("FAIL [JITTER_OBSERVED]: max (%0d) is not greater than min (%0d) - expected a cold-miss/warm-hit gap",
                      peek_reg(5'd2), peek_reg(5'd1));
        else
            $display("PASS [JITTER_OBSERVED]: max (%0d) > min (%0d) - cold-miss first iteration visible in the data",
                      peek_reg(5'd2), peek_reg(5'd1));

        $display("Testbench complete.");
        $finish;
    end

endmodule
