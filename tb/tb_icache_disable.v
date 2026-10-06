// tb_icache_disable.v
// Checks icache.v's cache_disable input, which turns the cache into
// Configuration 1 (plain XIP) at runtime. Drives the cache directly
// (no CPU) so every fetch's latency can be measured exactly:
//   - enabled: a repeat fetch is a 1-cycle hit (baseline)
//   - disabled: even a line that IS in the cache is fetched from flash
//     every time, one word, at the bypass cost - never a hit, never a
//     4-word line fill
//   - disabled: fetching an uncached line doesn't fill it (after
//     re-enabling, it still misses)
//   - re-enabled: lines cached before disabling are hits again
//   - the data returned is correct in every mode
//   - hit/miss counters: disabled fetches count as misses
//
//   iverilog -o sim_icache_disable rtl/icache.v rtl/spi_flash_ctrl.v tb/spi_flash_model.v tb/tb_icache_disable.v
//   vvp sim_icache_disable

`timescale 1ns/1ps

module tb_icache_disable;

    reg clk = 0;
    always #5 clk = ~clk;

    reg         reset = 1;
    reg  [23:0] addr = 0;
    reg         req = 0;
    reg         cache_disable = 0;
    wire        ready, busy;
    wire [31:0] rdata;
    wire [31:0] hit_count, miss_count;
    wire        sck, cs_n, mosi, miso;

    icache uut (
        .clk(clk), .reset(reset),
        .addr(addr), .req(req), .ready(ready), .rdata(rdata), .busy(busy),
        .lock_cmd(1'b0), .lock_set(1'b0), .lock_addr(24'd0),
        .cache_disable(cache_disable),
        .abort(1'b0),
        .hit_count(hit_count), .miss_count(miss_count), .stats_reset(1'b0),
        .sck(sck), .cs_n(cs_n), .mosi(mosi), .miso(miso)
    );

    spi_flash_model flash (
        .sck(sck), .cs_n(cs_n), .mosi(mosi), .miso(miso)
    );

    integer fails = 0;

    task check(input cond, input [8*48-1:0] msg);
        begin
            if (cond) $display("PASS [%0s]", msg);
            else begin $display("FAIL [%0s]", msg); fails = fails + 1; end
        end
    endtask

    // Word at byte address a, as the flash model holds it (little-endian).
    function [31:0] expect_word(input [23:0] a);
        expect_word = {flash.mem[a + 3], flash.mem[a + 2],
                       flash.mem[a + 1], flash.mem[a]};
    endfunction

    // One fetch: req for one cycle, then wait for ready. Returns the
    // data and the cycles from req to ready.
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
            @(negedge clk);          // let the cache return to idle
        end
    endtask

    integer i;
    integer hit_lat, bypass_lat, fill_lat;
    integer hits_before, misses_before;

    initial begin
        for (i = 0; i < 1024; i = i + 1) flash.mem[i] = (i * 37 + 11) & 8'hFF;

        repeat (3) @(negedge clk);
        reset = 0;

        // ---- Baseline, cache enabled ----
        fetch(24'h040);                      // cold: 4-word line fill
        fill_lat = latency;
        check(got == expect_word(24'h040), "ENABLED_FILL_DATA_CORRECT");
        fetch(24'h044);                      // same line: hit
        hit_lat = latency;
        check(got == expect_word(24'h044), "ENABLED_HIT_DATA_CORRECT");
        $display("enabled: line fill %0d cycles, hit %0d cycles", fill_lat, hit_lat);
        check(hit_lat == 1, "ENABLED_REPEAT_FETCH_IS_1_CYCLE_HIT");

        // ---- Disabled: the cached line is NOT used ----
        cache_disable = 1;
        hits_before   = hit_count;
        misses_before = miss_count;
        fetch(24'h044);
        bypass_lat = latency;
        $display("disabled: fetch of a cached word took %0d cycles", bypass_lat);
        check(got == expect_word(24'h044), "DISABLED_DATA_CORRECT");
        check(bypass_lat > 100, "DISABLED_CACHED_LINE_STILL_GOES_TO_FLASH");
        // One word from flash, not a 4-word fill: about a quarter of
        // the fill cost.
        check(bypass_lat * 3 < fill_lat, "DISABLED_FETCHES_ONE_WORD_NOT_A_LINE");

        fetch(24'h044);
        check(latency == bypass_lat, "DISABLED_REPEAT_IS_SAME_COST_NO_JITTER");
        check(hit_count == hits_before && miss_count == misses_before + 2,
              "DISABLED_FETCHES_COUNT_AS_MISSES");

        // ---- Disabled: an uncached line is not filled ----
        fetch(24'h080);
        check(got == expect_word(24'h080), "DISABLED_UNCACHED_DATA_CORRECT");
        fetch(24'h084);
        check(got == expect_word(24'h084) && latency == bypass_lat,
              "DISABLED_NEIGHBOR_WORD_ALSO_BYPASSES");

        // ---- Re-enabled ----
        cache_disable = 0;
        fetch(24'h080);
        check(latency == fill_lat, "REENABLED_LINE_FETCHED_WHILE_OFF_WAS_NOT_FILLED");
        check(got == expect_word(24'h080), "REENABLED_FILL_DATA_CORRECT");
        fetch(24'h048);
        check(latency == 1 && got == expect_word(24'h048),
              "REENABLED_LINE_CACHED_BEFORE_OFF_STILL_HITS");

        if (fails == 0) $display("ALL CHECKS PASSED");
        else            $display("%0d CHECK(S) FAILED", fails);
        $finish;
    end

endmodule
