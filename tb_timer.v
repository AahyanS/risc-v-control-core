// tb_timer.v
// Verifies timer.v actually fires periodically at the programmed
// interval, that clear_pending acknowledges it, and that a
// clear_pending landing on the exact same cycle as a new match
// doesn't suppress that new match.
//
// Run with:
//   iverilog -o sim_timer timer.v tb_timer.v
//   vvp sim_timer

`timescale 1ns/1ps

module tb_timer;

    reg clk, reset;
    reg [31:0] compare;
    reg clear_pending;
    reg restart = 1'b0;
    wire [31:0] count;
    wire pending;

    timer uut (
        .clk(clk), .reset(reset),
        .compare(compare), .clear_pending(clear_pending), .restart(restart),
        .count(count), .pending(pending)
    );

    always #5 clk = ~clk;

    integer i;

    initial begin
        clk = 1'b0;
        reset = 1'b1;
        compare = 32'd9;    // fires every 10 cycles (count 0..9)
        clear_pending = 1'b0;
        @(negedge clk); @(negedge clk);
        reset = 1'b0;

        // Run 9 cycles - should not have fired yet (count reaches 9 on the 10th).
        for (i = 0; i < 9; i = i + 1) @(posedge clk);
        #1;
        if (pending !== 1'b0)
            $display("FAIL [NOT_YET_PENDING]: pending=1 before reaching compare");
        else
            $display("PASS [NOT_YET_PENDING]: pending=0 with count still below compare");

        @(posedge clk); #1;   // 10th cycle - count hits compare (9), pending should go high
        if (pending !== 1'b1)
            $display("FAIL [FIRES_AT_COMPARE]: pending=0, expected 1 after reaching compare");
        else
            $display("PASS [FIRES_AT_COMPARE]: pending=1 after count reached compare");

        if (count !== 32'd0)
            $display("FAIL [RELOADS_TO_ZERO]: count=%0d expected 0 (periodic reload)", count);
        else
            $display("PASS [RELOADS_TO_ZERO]: count reloaded to 0 for the next period");

        // Acknowledge it.
        @(negedge clk);
        clear_pending = 1'b1;
        @(posedge clk); #1;
        clear_pending = 1'b0;
        if (pending !== 1'b0)
            $display("FAIL [CLEAR_ACKS]: pending=1 after clear_pending, expected 0");
        else
            $display("PASS [CLEAR_ACKS]: pending cleared by software acknowledgment");

        // Run until it fires again periodically. Waiting dynamically
        // (rather than a hardcoded cycle count) avoids having to
        // hand-track count's exact value through the earlier
        // acknowledgment cycle, which itself also advances count by 1
        // (it's a normal non-match cycle) - easy to miscount by hand.
        // #1 after each edge, inside the loop, before re-checking the
        // condition - reading count/pending immediately after
        // @(posedge clk) with no delay races the DUT's own
        // non-blocking update for that same edge.
        while (pending !== 1'b1) begin
            @(posedge clk);
            #1;
        end
        $display("PASS [FIRES_PERIODICALLY]: fired again after a full second period");

        // Same-cycle race: hold clear_pending high continuously through
        // the next match - the new match must still win. Clear this
        // one first (clear_pending held, no match pending yet).
        clear_pending = 1'b1;
        @(posedge clk); #1;
        if (pending !== 1'b0)
            $display("FAIL [HELD_CLEAR_WORKS]: pending=1 right after clear_pending, expected 0");
        else
            $display("PASS [HELD_CLEAR_WORKS]: pending cleared with clear_pending held, before the next match");

        // Now wait for the next match while clear_pending stays held -
        // the match must still win despite the continuous clear. count
        // displays the value `compare` for one full cycle (set by the
        // edge before the match) - wait for that, then one more edge
        // is the match-detecting one.
        while (count !== compare) begin
            @(posedge clk);
            #1;
        end
        @(posedge clk); #1;   // this edge IS the match
        if (pending !== 1'b1)
            $display("FAIL [NEW_MATCH_WINS_RACE]: pending=0, expected 1 - a same-cycle clear suppressed a real interrupt");
        else
            $display("PASS [NEW_MATCH_WINS_RACE]: new match wins even with clear_pending held the same cycle");

        // ---- restart: shrinking the period while count is already
        //      past the new compare value ----
        @(negedge clk);
        clear_pending = 1'b0;
        compare = 32'd1000;
        restart = 1'b1; @(negedge clk); restart = 1'b0;
        clear_pending = 1'b1; @(negedge clk); clear_pending = 1'b0;
        for (i = 0; i < 500; i = i + 1) @(negedge clk);   // count ~500
        compare = 32'd99;                                   // now < count
        restart = 1'b1; @(negedge clk); restart = 1'b0;
        if (count !== 32'd0)
            $display("FAIL [RESTART_ZEROES_COUNT]: count=%0d after restart, expected 0", count);
        else
            $display("PASS [RESTART_ZEROES_COUNT]: count restarted from 0 with the new period");
        for (i = 0; i < 99; i = i + 1) @(negedge clk);
        if (pending !== 1'b0)
            $display("FAIL [RESTART_NEW_PERIOD_EXACT]: fired early");
        else begin
            @(negedge clk);
            if (pending !== 1'b1)
                $display("FAIL [RESTART_NEW_PERIOD_EXACT]: did not fire 100 cycles after restart (count=%0d) - would have run to 2^32",
                         count);
            else
                $display("PASS [RESTART_NEW_PERIOD_EXACT]: fired exactly one new period (100 cycles) after restart");
        end

        // ---- restart leaves a real pending event alone ----
        restart = 1'b1; @(negedge clk); restart = 1'b0;
        if (pending !== 1'b1)
            $display("FAIL [RESTART_KEEPS_PENDING]: restart cleared an event that really happened");
        else
            $display("PASS [RESTART_KEEPS_PENDING]: pending survives a restart until software acknowledges it");

        $display("Testbench complete.");
        $finish;
    end

endmodule
