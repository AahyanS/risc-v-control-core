// tb_mac_benchmark.v
// Reports the cycle cost of computing
// output = Kp*error + Ki*integral + Kd*derivative via the hardware
// MAC instruction. Companion to tb_software_mac_benchmark.v, which
// times the identical computation via software q16_mul - direct
// cycles-per-iteration comparison for the same workload.
//
// Run with:
//   iverilog -o sim_mac_bench rtl/alu.v rtl/regfile.v rtl/control.v rtl/pc.v rtl/dmem.v rtl/spi_flash_ctrl.v tb/spi_flash_model.v rtl/icache.v rtl/quad_decoder.v rtl/pwm.v rtl/timer.v rtl/cpu_pipeline_cache_locked.v tb/tb_mac_benchmark.v
//   vvp sim_mac_bench

`timescale 1ns/1ps

module tb_mac_benchmark;

    reg clk;
    reg reset;
    integer i;

    wire sck, cs_n, mosi, miso;

    cpu_pipeline_cache_locked uut (
        .clk(clk),
        .reset(reset),
        .sck(sck), .cs_n(cs_n), .mosi(mosi), .miso(miso),
        .enc_a(1'b0), .enc_b(1'b0),
        .pwm_out()
    );

    spi_flash_model flash (
        .sck(sck), .cs_n(cs_n), .mosi(mosi), .miso(miso)
    );

    always #5 clk = ~clk;

    function [31:0] peek_result(input [31:0] offset);
        peek_result = {uut.dmem_inst.peek(offset+3), uut.dmem_inst.peek(offset+2),
                        uut.dmem_inst.peek(offset+1), uut.dmem_inst.peek(offset+0)};
    endfunction

    initial begin
        clk   = 1'b0;
        reset = 1'b1;

        $readmemh("sw/mac_benchmark.hex", flash.mem);

        @(negedge clk);
        @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        for (i = 0; i < 5000; i = i + 1) begin
            @(posedge clk); @(negedge clk);
        end

        // 0.5*1.0 + 0.25*2.0 + 0.125*1.0 = 0.5 + 0.5 + 0.125 = 1.125
        if (peek_result(32'h300) !== 32'd73728)
            $display("FAIL [MAC_RESULT]: got=%0d expected=73728 (1.125)", $signed(peek_result(32'h300)));
        else
            $display("PASS [MAC_RESULT]: output = 1.125 (raw 73728), correct");

        $display("MAC hardware: %0d cycles for 3 accumulating multiply-adds", peek_result(32'h304));

        $display("Testbench complete.");
        $finish;
    end

endmodule
