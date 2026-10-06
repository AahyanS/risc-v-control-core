// tb_interference_locked.v
// Runs sw/interference_locked_test.s against
// cpu_pipeline_cache_locked.v (Configuration 3). Companion to
// tb_interference_unlocked.v - same workload, same interference
// pattern, hot_loop's line locked this time. Expect every measured
// hot_loop call to stay a hit despite interference running between
// each one (interference gets routed through the bypass path
// instead of evicting the locked line) - min and max should both be
// small AND close together, unlike the unlocked run.
//
// Run with:
//   iverilog -o sim_interf_locked rtl/alu.v rtl/regfile.v rtl/control.v rtl/pc.v rtl/dmem.v rtl/spi_flash_ctrl.v tb/spi_flash_model.v rtl/icache.v rtl/cpu_pipeline_cache_locked.v tb/tb_interference_locked.v
//   vvp sim_interf_locked

`timescale 1ns/1ps

module tb_interference_locked;

    reg clk;
    reg reset;
    integer i;

    wire sck, cs_n, mosi, miso;

    cpu_pipeline_cache_locked uut (
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

        $readmemh("sw/interference_locked_test.hex", flash.mem);

        @(negedge clk);
        @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        for (i = 0; i < 15000; i = i + 1) begin
            @(posedge clk); @(negedge clk);
        end

        $display("LOCKED: min=%0d cycles, max=%0d cycles, sum=%0d cycles over 5 iterations",
                  peek_reg(5'd1), peek_reg(5'd2), peek_reg(5'd3));

        if (peek_reg(5'd1) === 32'h7FFFFFFF)
            $display("FAIL [MIN_WAS_UPDATED]: min still at its sentinel - loop never ran");
        else
            $display("PASS [MIN_WAS_UPDATED]: min = %0d", peek_reg(5'd1));

        if (peek_reg(5'd2) !== peek_reg(5'd1))
            $display("INFO [JITTER_UNDER_LOCK]: max (%0d) != min (%0d) - some residual variation despite locking",
                      peek_reg(5'd2), peek_reg(5'd1));
        else
            $display("PASS [NO_JITTER_UNDER_LOCK]: max == min == %0d - zero jitter despite interference",
                      peek_reg(5'd1));

        $display("Testbench complete.");
        $finish;
    end

endmodule
