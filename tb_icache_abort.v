// tb_icache_abort.v
// Checks icache.v's abort input (used when an interrupt redirects
// fetch while a flash read is in flight):
//   - aborting a line fill returns (a dummy) ready within a couple of
//     cycles instead of hundreds, and ends the flash transaction
//   - the half-filled line is never treated as valid: the line's old
//     occupant must not hit afterward (its data was partly overwritten),
//     and the aborted address refills correctly
//   - aborting a bypass (cache disabled) works the same way
//   - abort while a hit is being returned changes nothing
//
//   iverilog -o sim_icache_abort icache.v spi_flash_ctrl.v spi_flash_model.v tb_icache_abort.v
//   vvp sim_icache_abort

`timescale 1ns/1ps

module tb_icache_abort;

    reg clk = 0;
    always #5 clk = ~clk;

    reg         reset = 1;
    reg  [23:0] addr = 0;
    reg         req = 0;
    reg         abort = 0;
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
        .abort(abort),
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

    // Start a fetch, abort it `after` cycles later, return the cycles
    // from abort to ready.
    task fetch_and_abort(input [23:0] a, input integer after);
        begin
            @(negedge clk);
            addr = a; req = 1;
            @(negedge clk);
            req = 0;
            repeat (after) @(negedge clk);
            abort = 1;
            latency = 0;
            while (!ready && latency < 1000) begin @(negedge clk); latency = latency + 1; end
            @(negedge clk);
            abort = 0;
            @(negedge clk);
        end
    endtask

    // Y and Z share line index 2 (addr[7:4]) with different tags.
    localparam [23:0] Y = 24'h000020, Z = 24'h000120;

    integer i;

    initial begin
        for (i = 0; i < 1024; i = i + 1) flash.mem[i] = (i * 29 + 3) & 8'hFF;
        repeat (3) @(negedge clk);
        reset = 0;

        // ---- Abort a line fill over a line that held other code ----
        fetch(Y);
        fetch(Y + 4);
        check(latency == 1, "Y_CACHED");
        fetch_and_abort(Z, 300);                 // ~2.5 words into Z's fill
        $display("fill aborted: ready %0d cycle(s) after abort", latency);
        check(latency <= 2, "ABORTED_FILL_RETURNS_WITHIN_2_CYCLES");
        check(cs_n === 1'b1 && !busy, "FLASH_TRANSACTION_ENDED_CACHE_IDLE");
        fetch(Y + 8);
        check(latency > 400 && got == expect_word(Y + 8),
              "OLD_OCCUPANT_REFILLS_NOT_HIT_ON_PARTIAL_LINE");
        fetch(Z);
        fetch(Z + 12);
        check(got == expect_word(Z + 12), "ABORTED_ADDRESS_REFILLS_CORRECTLY");

        // ---- Abort a bypass ----
        cache_disable = 1;
        fetch_and_abort(24'h000300, 60);
        check(latency <= 2, "ABORTED_BYPASS_RETURNS_WITHIN_2_CYCLES");
        fetch(24'h000304);
        check(got == expect_word(24'h000304), "FETCH_AFTER_ABORTED_BYPASS_CORRECT");
        cache_disable = 0;

        // ---- Abort during a hit changes nothing ----
        fetch(Y);                                  // Y cached again
        @(negedge clk);
        addr = Y + 4; req = 1; abort = 1;
        @(negedge clk);
        req = 0;
        latency = 1;
        while (!ready) begin @(negedge clk); latency = latency + 1; end
        got = rdata;
        abort = 0;
        check(latency == 1 && got == expect_word(Y + 4), "ABORT_DURING_HIT_IGNORED");

        if (fails == 0) $display("ALL CHECKS PASSED");
        else            $display("%0d CHECK(S) FAILED", fails);
        $finish;
    end

endmodule
