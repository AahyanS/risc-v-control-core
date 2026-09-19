// tb_encoder_test.v
// End-to-end test of the quadrature encoder peripheral wired into
// cpu_pipeline_cache_locked.v: drives real quadrature transitions on
// the CPU's physical enc_a/enc_b pins (not a hierarchical peek into
// quad_decoder_inst), then runs sw/encoder_test.s and checks that
// software actually read the resulting position back correctly via
// MMIO, and that clearing it via a store also works end to end.
//
// Run with:
//   iverilog -o sim_encoder alu.v regfile.v control.v pc.v dmem.v spi_flash_ctrl.v spi_flash_model.v icache.v quad_decoder.v cpu_pipeline_cache_locked.v tb_encoder_test.v
//   vvp sim_encoder

`timescale 1ns/1ps

module tb_encoder_test;

    reg clk;
    reg reset;
    reg enc_a, enc_b;
    integer i;

    wire sck, cs_n, mosi, miso;

    cpu_pipeline_cache_locked uut (
        .clk(clk),
        .reset(reset),
        .sck(sck), .cs_n(cs_n), .mosi(mosi), .miso(miso),
        .enc_a(enc_a),
        .enc_b(enc_b)
    );

    spi_flash_model flash (
        .sck(sck), .cs_n(cs_n), .mosi(mosi), .miso(miso)
    );

    always #5 clk = ~clk;

    function [31:0] peek_result(input [31:0] offset);
        peek_result = {uut.dmem_inst.mem[offset+3], uut.dmem_inst.mem[offset+2],
                        uut.dmem_inst.mem[offset+1], uut.dmem_inst.mem[offset+0]};
    endfunction

    task settle;
        begin
            @(negedge clk); @(negedge clk); @(negedge clk); @(negedge clk);
        end
    endtask

    task step_forward;   // one full quadrature line: +1 count (4x decoding)
        begin
            enc_a=0; enc_b=0; settle;
            enc_a=0; enc_b=1; settle;
            enc_a=1; enc_b=1; settle;
            enc_a=1; enc_b=0; settle;
            enc_a=0; enc_b=0; settle;
        end
    endtask

    initial begin
        clk   = 1'b0;
        reset = 1'b1;
        enc_a = 1'b0;
        enc_b = 1'b0;

        $readmemh("sw/encoder_test.hex", flash.mem);

        @(negedge clk);
        @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        // Drive 5 full forward lines = 20 counts (4x decoding), right
        // after reset releases - easily finishes well before the
        // program's first lw actually executes (XIP fetch is ~128
        // cycles for even the first instruction).
        for (i = 0; i < 5; i = i + 1)
            step_forward;

        // Run the program - XIP fetch for ~9 instructions, generous budget.
        for (i = 0; i < 4000; i = i + 1) begin
            @(posedge clk); @(negedge clk);
        end

        if (peek_result(32'h200) !== 32'd20)
            $display("FAIL [POSITION_READ]: got=%0d expected=20", $signed(peek_result(32'h200)));
        else
            $display("PASS [POSITION_READ]: software read position=20 via MMIO");

        if (peek_result(32'h204) !== 32'd0)
            $display("FAIL [ERROR_COUNT]: got=%0d expected=0 (clean transitions)", peek_result(32'h204));
        else
            $display("PASS [ERROR_COUNT]: 0 invalid transitions, as expected for clean quadrature signals");

        if (peek_result(32'h208) !== 32'd0)
            $display("FAIL [POSITION_CLEARED]: got=%0d expected=0 after software-issued clear", $signed(peek_result(32'h208)));
        else
            $display("PASS [POSITION_CLEARED]: position reads back 0 after the software-issued clear");

        $display("Testbench complete.");
        $finish;
    end

endmodule
