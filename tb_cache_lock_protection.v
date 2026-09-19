// tb_cache_lock_protection.v
// Proves cache-line locking actually protects a line from eviction,
// using sw/cache_lock_test.s against cpu_pipeline_cache_locked.v.
//
// Architectural correctness (x1==2, x2==111, x3==223) only proves the
// program ran right - it can't by itself prove locking worked, since
// flash is the source of truth and an evicted-then-refilled hot_code
// would produce the same register results, just slower. The real
// proof is internal cache state: snapshot the locked line's tag right
// after the warm-up call (before alias_setup runs), snapshot it again
// after the whole program finishes, and confirm it's UNCHANGED -
// meaning alias_setup's aliasing fetch (same index, different tag)
// never got to overwrite it. Also confirm the bypass path actually
// fired (alias_setup's own fetches had to go around the cache, not
// through it), so the test isn't just "nothing happened."
//
// Run with:
//   iverilog -o sim_lock_protect alu.v regfile.v control.v pc.v dmem.v spi_flash_ctrl.v spi_flash_model.v icache.v cpu_pipeline_cache_locked.v tb_cache_lock_protection.v
//   vvp sim_lock_protect

`timescale 1ns/1ps

module tb_cache_lock_protection;

    reg clk;
    reg reset;
    integer i;
    integer bypass_count;

    // Snapshot of the locked line's state, taken once we see the lock
    // bit get set.
    reg        snapshot_taken;
    reg [3:0]  locked_index;
    reg [15:0] locked_tag_before;
    reg        locked_valid_before;

    wire sck, cs_n, mosi, miso;

    cpu_pipeline_cache_locked uut (
        .clk(clk),
        .reset(reset),
        .sck(sck), .cs_n(cs_n), .mosi(mosi), .miso(miso)
    );

    spi_flash_model flash (
        .sck(sck), .cs_n(cs_n), .mosi(mosi), .miso(miso)
    );

    always #5 clk = ~clk;

    function [31:0] peek_reg(input [4:0] reg_num);
        peek_reg = (reg_num == 5'd0) ? 32'd0 : uut.regfile_inst.regs[reg_num];
    endfunction

    task check_reg(input [4:0] reg_num, input [31:0] exp_val,
                    input [63:0] opname);
        begin
            if (peek_reg(reg_num) !== exp_val)
                $display("FAIL [%0s]: x%0d got=%0h expected=%0h",
                          opname, reg_num, peek_reg(reg_num), exp_val);
            else
                $display("PASS [%0s]: x%0d = %0h",
                          opname, reg_num, peek_reg(reg_num));
        end
    endtask

    initial begin
        clk   = 1'b0;
        reset = 1'b1;
        bypass_count   = 0;
        snapshot_taken = 1'b0;

        $readmemh("sw/cache_lock_test.hex", flash.mem);

        @(negedge clk);
        @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        // 1st call (miss, ~512c) + lock setup (a handful of hits) +
        // alias_setup's two bypass fetches (~128c each) + 2nd call
        // (should hit, cheap) - budget generously.
        for (i = 0; i < 6000; i = i + 1) begin
            @(posedge clk);

            // The moment a lock actually lands, snapshot the locked
            // line's tag/valid before anything else can touch it.
            if (!snapshot_taken && uut.icache_inst.lock_cmd && uut.icache_inst.lock_set) begin
                locked_index         = uut.icache_inst.lock_addr[7:4];
                locked_tag_before    = uut.icache_inst.tag[locked_index];
                locked_valid_before  = uut.icache_inst.valid[locked_index];
                snapshot_taken       = 1'b1;
            end

            // Count every time the cache actually uses the bypass
            // path (entering ST_BYPASS from ST_IDLE on a locked-line
            // conflict).
            if (uut.icache_inst.state == 2'd0 && uut.icache_inst.req &&
                !uut.icache_inst.req_hit && uut.icache_inst.lock[uut.icache_inst.req_index])
                bypass_count = bypass_count + 1;

            @(negedge clk);
        end

        check_reg(5'd1, 32'd2,   "X1_HOT_PASS_COUNT");
        check_reg(5'd2, 32'd111, "X2_HOT_MARKER");
        check_reg(5'd3, 32'd223, "X3_ALIAS_MARKER");

        if (!snapshot_taken)
            $display("FAIL [LOCK_COMMAND_FIRED]: lock_cmd/lock_set never observed");
        else
            $display("PASS [LOCK_COMMAND_FIRED]: locked line index=%0d", locked_index);

        if (bypass_count == 0)
            $display("FAIL [BYPASS_USED]: alias_setup's fetches never triggered bypass - test isn't exercising the conflict");
        else
            $display("PASS [BYPASS_USED]: bypass path used %0d time(s) for the aliasing fetches", bypass_count);

        if (uut.icache_inst.lock[locked_index] !== 1'b1)
            $display("FAIL [LINE_STILL_LOCKED]: lock bit got cleared unexpectedly");
        else
            $display("PASS [LINE_STILL_LOCKED]: lock bit still set at program end");

        if (uut.icache_inst.tag[locked_index] !== locked_tag_before ||
            uut.icache_inst.valid[locked_index] !== locked_valid_before)
            $display("FAIL [LINE_PROTECTED_FROM_EVICTION]: tag/valid changed - locked line was evicted by the aliasing fetch (tag before=%0h now=%0h)",
                      locked_tag_before, uut.icache_inst.tag[locked_index]);
        else
            $display("PASS [LINE_PROTECTED_FROM_EVICTION]: tag=%0h valid=%0b unchanged despite an aliasing fetch to the same index",
                      locked_tag_before, locked_valid_before);

        $display("Testbench complete.");
        $finish;
    end

endmodule
