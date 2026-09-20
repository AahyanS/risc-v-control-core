// tb_interrupt_test.v
// End-to-end test of M-mode interrupt support: runs sw/interrupt_test.s,
// which configures mtvec/mie/mstatus and a timer compare value, then
// spins doing background work while the timer interrupts it
// periodically. Checks that the handler actually ran 5 times (not
// just once - proving execution correctly resumes via mret each time,
// not just that a single trap can be taken), and that the background
// work counter kept advancing throughout - the main program wasn't
// derailed by the interrupts, just briefly paused for each one.
//
// Run with:
//   iverilog -o sim_interrupt alu.v regfile.v control.v pc.v dmem.v spi_flash_ctrl.v spi_flash_model.v icache.v quad_decoder.v pwm.v timer.v cpu_pipeline_cache_locked.v tb_interrupt_test.v
//   vvp sim_interrupt

`timescale 1ns/1ps

module tb_interrupt_test;

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

        $readmemh("sw/interrupt_test.hex", flash.mem);

        @(negedge clk);
        @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        // Setup is ~10 instructions (each an XIP fetch, ~128-512c
        // depending on hit/miss), then main_loop spins until 5
        // interrupts land, each ~200 cycles apart per the compare
        // value, plus handler overhead each time. Budget generously.
        for (i = 0; i < 40000; i = i + 1) begin
            @(posedge clk); @(negedge clk);
        end

        // main_loop's exit check (blt x28,x7,main_loop) races the
        // asynchronous ISR incrementing x28 - the loop can overshoot
        // the threshold by one iteration if an interrupt lands between
        // a check and the next one, since the two aren't synchronized.
        // Traced and confirmed this is exactly what happens (x28
        // increments correctly and monotonically on every real
        // interrupt, no corruption) rather than assuming it away -
        // the real guarantee is "at least 5, and not many more,"
        // not "exactly 5."
        if (peek_result(32'h304) < 32'd5 || peek_result(32'h304) > 32'd6)
            $display("FAIL [ISR_RAN_ENOUGH_TIMES]: got=%0d, expected 5 or 6 (5 plus at most one race overshoot)",
                      peek_result(32'h304));
        else
            $display("PASS [ISR_RAN_ENOUGH_TIMES]: handler ran %0d times, each resuming correctly via mret",
                      peek_result(32'h304));

        if (peek_result(32'h300) < 32'd5)
            $display("FAIL [MAIN_LOOP_PROGRESSED]: background counter=%0d - main program barely ran",
                      peek_result(32'h300));
        else
            $display("PASS [MAIN_LOOP_PROGRESSED]: background counter=%0d - main program kept running between interrupts",
                      peek_result(32'h300));

        $display("Testbench complete.");
        $finish;
    end

endmodule
