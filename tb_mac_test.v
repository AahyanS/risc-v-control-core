// tb_mac_test.v
// Verifies the custom MAC instruction end-to-end against
// cpu_pipeline_cache_locked.v: basic multiply-accumulate correctness,
// back-to-back accumulation into the same rd (the real use case,
// exercising the new EX-stage forwarding path for the accumulator
// read), and a load-use hazard on MAC's implicit rd read.
//
// Run with:
//   iverilog -o sim_mac alu.v regfile.v control.v pc.v dmem.v spi_flash_ctrl.v spi_flash_model.v icache.v quad_decoder.v pwm.v timer.v cpu_pipeline_cache_locked.v tb_mac_test.v
//   vvp sim_mac

`timescale 1ns/1ps

module tb_mac_test;

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
        peek_result = {uut.dmem_inst.mem[offset+3], uut.dmem_inst.mem[offset+2],
                        uut.dmem_inst.mem[offset+1], uut.dmem_inst.mem[offset+0]};
    endfunction

    initial begin
        clk   = 1'b0;
        reset = 1'b1;

        $readmemh("sw/mac_test.hex", flash.mem);

        @(negedge clk);
        @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        for (i = 0; i < 10000; i = i + 1) begin
            @(posedge clk); @(negedge clk);
        end

        if (peek_result(32'h300) !== 32'd245760)
            $display("FAIL [BASIC_MAC]: got=%0d expected=245760 (0 + 1.5*2.5 = 3.75)", $signed(peek_result(32'h300)));
        else
            $display("PASS [BASIC_MAC]: 0 + 1.5*2.5 = 3.75 (raw 245760)");

        if (peek_result(32'h304) !== 32'd262144)
            $display("FAIL [ACCUMULATE_FORWARDING]: got=%0d expected=262144 (1.0+2.0+1.0=4.0)", $signed(peek_result(32'h304)));
        else
            $display("PASS [ACCUMULATE_FORWARDING]: three back-to-back MACs into the same rd = 4.0 (raw 262144), forwarding correct");

        if (peek_result(32'h308) !== 32'd196608)
            $display("FAIL [LOAD_USE_ON_ACC]: got=%0d expected=196608 (loaded 1.0 + 2.0*1.0 = 3.0)", $signed(peek_result(32'h308)));
        else
            $display("PASS [LOAD_USE_ON_ACC]: load-use hazard on MAC's accumulator read handled correctly, result = 3.0 (raw 196608)");

        $display("Testbench complete.");
        $finish;
    end

endmodule
