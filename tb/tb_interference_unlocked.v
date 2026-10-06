// tb_interference_unlocked.v
// Runs sw/interference_unlocked_test.s against cpu_pipeline_cache.v
// (Configuration 2, cache without locking). Companion to
// tb_interference_locked.v - same workload, same interference
// pattern, different cache-locking policy. Comparing this test's
// min/max against the locked version's is the direct, concrete
// evidence for what cache-line locking buys a real-time control loop
// under realistic competing traffic (not just the no-contention
// cold/warm case tb_cycle_timing_cache.v already showed).
//
// Run with:
//   iverilog -o sim_interf_unlocked rtl/alu.v rtl/regfile.v rtl/control.v rtl/pc.v rtl/dmem.v rtl/spi_flash_ctrl.v tb/spi_flash_model.v rtl/icache.v rtl/cpu_pipeline_cache.v tb/tb_interference_unlocked.v
//   vvp sim_interf_unlocked

`timescale 1ns/1ps

module tb_interference_unlocked;

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

        $readmemh("sw/interference_unlocked_test.hex", flash.mem);

        @(negedge clk);
        @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        // Every measured hot_loop call is expected to miss (evicted
        // by interference each time) - budget generously for 5
        // rounds of miss+miss.
        for (i = 0; i < 15000; i = i + 1) begin
            @(posedge clk); @(negedge clk);
        end

        $display("UNLOCKED: min=%0d cycles, max=%0d cycles, sum=%0d cycles over 5 iterations",
                  peek_reg(5'd1), peek_reg(5'd2), peek_reg(5'd3));

        if (peek_reg(5'd1) === 32'h7FFFFFFF)
            $display("FAIL [MIN_WAS_UPDATED]: min still at its sentinel - loop never ran");
        else
            $display("PASS [MIN_WAS_UPDATED]: min = %0d", peek_reg(5'd1));

        $display("Testbench complete.");
        $finish;
    end

endmodule
