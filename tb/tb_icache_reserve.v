// tb_icache_reserve.v
// Checks that a cache lock reserves its line for the address it was
// issued with (icache.v header, "Cache line locking"):
//   - locking BEFORE the code ever runs: the owner's first fetch fills
//     the line, later fetches hit
//   - other code aliasing the locked line bypasses and can't evict it
//   - locking a line that currently holds OTHER code: the owner's
//     fetch replaces it, and the old occupant is locked out from then on
//   - unlocking returns the line to normal replacement
// Drives the cache directly so each fetch's latency is exact:
// 1 cycle = hit, ~130 = one-word bypass, ~520 = 4-word line fill.
//
//   iverilog -o sim_icache_reserve rtl/icache.v rtl/spi_flash_ctrl.v tb/spi_flash_model.v tb/tb_icache_reserve.v
//   vvp sim_icache_reserve

`timescale 1ns/1ps

module tb_icache_reserve;

    reg clk = 0;
    always #5 clk = ~clk;

    reg         reset = 1;
    reg  [23:0] addr = 0;
    reg         req = 0;
    reg         lock_cmd = 0, lock_set = 0;
    reg  [23:0] lock_addr = 0;
    wire        ready, busy;
    wire [31:0] rdata;
    wire [31:0] hit_count, miss_count;
    wire        sck, cs_n, mosi, miso;

    icache uut (
        .clk(clk), .reset(reset),
        .addr(addr), .req(req), .ready(ready), .rdata(rdata), .busy(busy),
        .lock_cmd(lock_cmd), .lock_set(lock_set), .lock_addr(lock_addr),
        .cache_disable(1'b0),
        .abort(1'b0),
        .hit_count(hit_count), .miss_count(miss_count), .stats_reset(1'b0),
        .sck(sck), .cs_n(cs_n), .mosi(mosi), .miso(miso)
    );

    spi_flash_model flash (
        .sck(sck), .cs_n(cs_n), .mosi(mosi), .miso(miso)
    );

    integer fails = 0;

    task check(input cond, input [8*56-1:0] msg);
        begin
            if (cond) $display("PASS [%0s]", msg);
            else begin $display("FAIL [%0s]", msg); fails = fails + 1; end
        end
    endtask

    function [31:0] expect_word(input [23:0] a);
        expect_word = {flash.mem[a + 3], flash.mem[a + 2],
                       flash.mem[a + 1], flash.mem[a]};
    endfunction

    reg  [31:0] got;
    integer     latency;

    task fetch(input [23:0] a);
        begin
            @(negedge clk);
            addr = a; req = 1;
            @(negedge clk);
            req = 0;
            latency = 1;
            while (!ready) begin @(negedge clk); latency = latency + 1; end
            got = rdata;
            @(negedge clk);
        end
    endtask

    task lock(input [23:0] a, input set);
        begin
            @(negedge clk);
            lock_addr = a; lock_set = set; lock_cmd = 1;
            @(negedge clk);
            lock_cmd = 0;
        end
    endtask

    // Classify a latency.
    function is_hit(input integer l);    is_hit    = (l == 1);              endfunction
    function is_bypass(input integer l); is_bypass = (l > 100 && l < 200);  endfunction
    function is_fill(input integer l);   is_fill   = (l > 400);             endfunction

    // A and B share line index 3 (addr[7:4]) with different tags; so
    // do C and D, on index 5.
    localparam [23:0] A = 24'h000130, B = 24'h000230;
    localparam [23:0] C = 24'h000150, D = 24'h000350;

    integer i;

    initial begin
        for (i = 0; i < 1024; i = i + 1) flash.mem[i] = (i * 53 + 7) & 8'hFF;
        repeat (3) @(negedge clk);
        reset = 0;

        // ---- Lock before the code has ever run ----
        lock(A, 1);
        fetch(A);
        $display("owner's first fetch after locking an empty line: %0d cycles", latency);
        check(is_fill(latency) && got == expect_word(A), "LOCKED_EMPTY_LINE_FILLS_FOR_ITS_OWNER");
        fetch(A + 4);
        check(is_hit(latency) && got == expect_word(A + 4), "OWNER_THEN_HITS");

        // ---- Other code aliasing the locked line ----
        fetch(B);
        check(is_bypass(latency) && got == expect_word(B), "ALIAS_BYPASSES_WITH_CORRECT_DATA");
        fetch(B + 8);
        check(is_bypass(latency), "ALIAS_NEVER_CACHED");
        fetch(A + 8);
        check(is_hit(latency) && got == expect_word(A + 8), "OWNER_STILL_HITS_AFTER_ALIAS_TRAFFIC");

        // ---- Lock a line that currently holds OTHER code ----
        fetch(D);                              // D occupies index 5
        fetch(D + 4);
        check(is_hit(latency), "D_CACHED_BEFORE_LOCK");
        lock(C, 1);                            // reserve index 5 for C
        fetch(C);
        check(is_fill(latency) && got == expect_word(C), "OWNER_REPLACES_PREVIOUS_OCCUPANT");
        fetch(D + 4);
        check(is_bypass(latency) && got == expect_word(D + 4), "PREVIOUS_OCCUPANT_NOW_LOCKED_OUT");
        fetch(C + 12);
        check(is_hit(latency), "OWNER_HITS");

        // ---- Unlock: normal replacement again ----
        lock(A, 0);
        fetch(B);
        check(is_fill(latency) && got == expect_word(B), "UNLOCKED_ALIAS_FILLS_NORMALLY");
        fetch(A);
        check(is_fill(latency), "UNLOCKED_OWNER_CAN_BE_EVICTED");

        if (fails == 0) $display("ALL CHECKS PASSED");
        else            $display("%0d CHECK(S) FAILED", fails);
        $finish;
    end

endmodule
