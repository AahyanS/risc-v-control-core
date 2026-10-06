// tb_interrupt_stress.v
// Runs sw/interrupt_stress_test.s on cpu_pipeline_cache_locked: timer
// ticks landing at every point in the pipeline, over cached code, over
// code fetched straight from flash (ticks abort one-word reads), and
// over code that thrashes the cache (ticks abort line fills).
//
// Two kinds of check:
//   - architectural: the loop's sum must equal its iteration count, so
//     an instruction executed twice, skipped, or run with a stale
//     value is caught in the result
//   - a pipeline property, checked every cycle: after a trap, the
//     first instruction to execute is the handler's first; after an
//     mret, the first is the one at mepc. Nothing from the interrupted
//     program may execute in between.
// (Load-use stalls turned out to be unreachable in this core - fetch
// delivers at most one instruction per two cycles, so a dependent
// instruction never reaches ID while its load is still in EX. The
// count is still reported, so a change that makes them reachable shows
// up here.)
//
//   iverilog -o sim_interrupt_stress rtl/alu.v rtl/regfile.v rtl/control.v rtl/pc.v rtl/dmem.v \
//     rtl/spi_flash_ctrl.v tb/spi_flash_model.v rtl/icache.v rtl/quad_decoder.v rtl/pwm.v rtl/timer.v \
//     rtl/uart_tx.v rtl/cpu_pipeline_cache_locked.v tb/tb_interrupt_stress.v
//   vvp sim_interrupt_stress

`timescale 1ns/1ps

module tb_interrupt_stress;

    reg clk = 0;
    reg reset = 1;
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

    integer fails = 0;

    task check(input cond, input [8*56-1:0] msg);
        begin
            if (cond) $display("PASS [%0s]", msg);
            else begin $display("FAIL [%0s]", msg); fails = fails + 1; end
        end
    endtask

    // ---- Pipeline property checker ----
    // expect_pc: the PC the next instruction to execute must have
    // (set by a trap or an mret), or none.
    reg         expecting = 0;
    reg  [31:0] expect_pc;
    integer     traps = 0, traps_in_load_use = 0, violations = 0;
    integer     load_use_cycles = 0, cycles = 0;
    integer     mislabeled = 0;
    integer     aborted_fills = 0, aborted_bypasses = 0;

    always @(posedge clk) begin
        if (!reset) begin
            cycles = cycles + 1;
            if (uut.load_use_hazard) load_use_cycles = load_use_cycles + 1;
            if (uut.icache_inst.abort_now && uut.icache_inst.state == 2'd1)
                aborted_fills = aborted_fills + 1;
            if (uut.icache_inst.abort_now && uut.icache_inst.state == 2'd3)
                aborted_bypasses = aborted_bypasses + 1;
            // Every instruction entering decode must be the one flash
            // holds at its PC - catches an instruction labeled with the
            // wrong PC, which the PC-only checks below can't see.
            if (uut.if_id_valid &&
                uut.if_id_instr !== {flash.mem[uut.if_id_pc + 3], flash.mem[uut.if_id_pc + 2],
                                     flash.mem[uut.if_id_pc + 1], flash.mem[uut.if_id_pc]}) begin
                mislabeled = mislabeled + 1;
                if (mislabeled <= 3)
                    $display("MISLABELED at %0t: pc=%h holds %h", $time, uut.if_id_pc, uut.if_id_instr);
            end
            if (uut.id_ex_valid && expecting) begin
                if (uut.id_ex_pc !== expect_pc) begin
                    violations = violations + 1;
                    if (violations <= 5)
                        $display("VIOLATION at %0t: executed pc=%h, expected %h",
                                 $time, uut.id_ex_pc, expect_pc);
                end
                expecting = 0;
            end
            if (uut.trap_taken) begin
                traps = traps + 1;
                if (uut.load_use_hazard) traps_in_load_use = traps_in_load_use + 1;
                expecting = 1;
                expect_pc = uut.mtvec;
            end else if (uut.id_ex_valid && uut.id_ex_is_mret) begin
                expecting = 1;
                expect_pc = uut.mepc;
            end
        end
    end

    initial begin
        $readmemh("sw/interrupt_stress_test.hex", flash.mem);
        repeat (3) @(negedge clk);
        reset = 0;

        for (i = 0; i < 8000000 && peek_result(32'h310) !== 32'h600D; i = i + 1)
            @(negedge clk);

        $display("%0d cycles, %0d with a load-use stall", cycles, load_use_cycles);
        $display("sums: cached %0d (expect 1500), no cache %0d (expect 60), thrash %0d (expect 60)",
                 peek_result(32'h300), peek_result(32'h304), peek_result(32'h308));
        $display("ticks handled=%0d, traps=%0d (%0d during a load-use stall), aborted line fills=%0d, aborted bypass reads=%0d",
                 peek_result(32'h30C), traps, traps_in_load_use, aborted_fills, aborted_bypasses);

        check(peek_result(32'h310) === 32'h600D, "ALL_THREE_PHASES_FINISHED_FORWARD_PROGRESS");
        check(peek_result(32'h30C) > 100,        "MANY_INTERRUPTS_TAKEN");
        check(aborted_fills > 0,                 "COVERED_TICK_ABORTING_A_LINE_FILL");
        check(aborted_bypasses > 0,              "COVERED_TICK_ABORTING_A_BYPASS_READ");
        check(peek_result(32'h300) == 1500 && peek_result(32'h304) == 60 &&
              peek_result(32'h308) == 60,       "ALL_SUMS_EXACT_NO_DOUBLE_OR_STALE_EXECUTION");
        check(violations == 0,                   "NOTHING_EXECUTES_BETWEEN_TRAP_AND_HANDLER");
        check(mislabeled == 0,                   "EVERY_INSTRUCTION_MATCHES_FLASH_AT_ITS_PC");

        if (fails == 0) $display("ALL CHECKS PASSED");
        else            $display("%0d CHECK(S) FAILED", fails);
        $finish;
    end

endmodule
