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

    // Traps taken up to the moment the ISR count is stored (the store
    // to 0x304 reaching MEM).
    integer traps_so_far = 0, traps_before_store = -1;
    always @(posedge clk) begin
        if (uut.trap_taken) traps_so_far = traps_so_far + 1;
        if (uut.ex_mem_mem_write && uut.ex_mem_alu_result == 32'h304 && traps_before_store < 0)
            traps_before_store = traps_so_far;
    end

    function [31:0] peek_result(input [31:0] offset);
        peek_result = {uut.dmem_inst.peek(offset+3), uut.dmem_inst.peek(offset+2),
                        uut.dmem_inst.peek(offset+1), uut.dmem_inst.peek(offset+0)};
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

        // main_loop's exit check races the ISR: interrupts stay
        // enabled after the loop exits, and the result stores that
        // follow are cold flash fetches (~520 cycles each against a
        // 200-cycle timer), so more ticks can land before x28 is
        // stored. The first version of this check allowed "5 or 6",
        // which described the original core's timing - it couldn't take
        // an interrupt until a fetch finished - rather than
        // correctness, and broke when interrupts became able to cut a
        // fetch short. Now exact and timing-independent: the stored
        // count must equal the traps actually taken before that store
        // executed, and be at least 5.
        if (peek_result(32'h304) < 32'd5 || peek_result(32'h304) != traps_before_store)
            $display("FAIL [ISR_RAN_ENOUGH_TIMES]: stored %0d, traps before the store %0d (need equal, >= 5)",
                      peek_result(32'h304), traps_before_store);
        else
            $display("PASS [ISR_RAN_ENOUGH_TIMES]: handler ran %0d times (= traps taken before the store), each resuming correctly via mret",
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
