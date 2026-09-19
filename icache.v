// icache.v
// Direct-mapped instruction cache, sitting between the CPU and
// spi_flash_ctrl.v. Presents the exact same req/ready/rdata/busy
// interface spi_flash_ctrl.v does, so it's a drop-in replacement -
// cpu_pipeline_xip.v's IF stage doesn't need to change at all to use
// this instead of talking to flash directly.
//
// 16 lines x 4 words (16 bytes) per line = 256 bytes of cache. Address
// breakdown (addr is a 24-bit byte address, word-aligned so addr[1:0]
// is always 0):
//   addr[3:2]  - word offset within the line (0-3)
//   addr[7:4]  - line index (which of the 16 lines)
//   addr[23:8] - tag (confirms the line actually holds THIS address,
//                not a different one that happens to map to the same
//                index)
//
// On a hit: answers in 1 cycle - not 0. ready can't fire the same
// cycle as req: the CPU's fetch_issued logic (`if (flash_req)
// fetch_issued<=1; else if (flash_ready) fetch_issued<=0;`) only
// checks the flash_ready branch when flash_req is NOT also true that
// same cycle - a same-cycle hit response would set fetch_issued=1 and
// never clear it, silently deadlocking fetch forever. This is a real
// interface constraint, not an arbitrary choice.
//
// On a miss: fetches all 4 words of the line, one spi_flash_ctrl.v
// transaction at a time (not yet using flash's native continuous-read
// capability to fetch all 4 in one transaction - a real optimization,
// deferred for the same reason quad-SPI/fast-read was: correctness
// first, matching this project's established pattern), then answers
// with the specific word originally requested.
//
// ---- Cache line locking ----
// A lock bit per line, set/cleared by software via lock_cmd/lock_set/
// lock_addr (driven from a memory-mapped store at the CPU level - see
// cpu_pipeline_cache_locked.v). A locked line can never be evicted: on
// a miss where the target line is locked, the cache does a BYPASS
// fetch instead of a normal fill - it gets the single requested word
// straight from flash without touching cache_data/valid/tag for that
// line at all. This is the real, unavoidable tradeoff of locking a
// slot in a direct-mapped cache: any OTHER address that aliases to
// that same line (shares addr[7:4]) becomes permanently uncacheable
// for as long as the lock holds - there's no associativity to fall
// back on. That's not a limitation of this implementation; it's the
// actual hardware cost locking buys determinism with, which is the
// whole point of this project.
//
// Locking assumes software already warmed the target line (fetched it
// at least once) before issuing the lock command - the command only
// sets a bit, it doesn't force a fill. Locking code that was never
// fetched is a software usage error, not something the hardware
// guards against here.

module icache (
    input         clk,
    input         reset,

    input  [23:0] addr,
    input         req,
    output reg    ready,
    output reg [31:0] rdata,
    output        busy,

    // Cache line locking control (driven from a memory-mapped store
    // at the CPU level).
    input         lock_cmd,   // pulse: apply a lock/unlock this cycle
    input         lock_set,   // 1 = lock, 0 = unlock
    input  [23:0] lock_addr,  // any address inside the target line

    // Instrumentation: running totals, readable/resettable from the
    // CPU level via memory-mapped registers - see cpu_pipeline_cache.v
    // / cpu_pipeline_cache_locked.v. A "miss" here counts both normal
    // fills and locked-line bypasses - both left the 1-cycle hit path.
    output reg [31:0] hit_count,
    output reg [31:0] miss_count,
    input             stats_reset,

    output sck,
    output cs_n,
    output mosi,
    input  miso
);

    localparam ST_IDLE    = 2'd0;
    localparam ST_FILL    = 2'd1;
    localparam ST_RETURN  = 2'd2;
    localparam ST_BYPASS  = 2'd3;

    reg [1:0] state;
    assign busy = (state != ST_IDLE);

    // ---- Cache storage ----
    reg [31:0] cache_data [0:15][0:3];
    reg        valid      [0:15];
    reg [15:0] tag        [0:15];
    reg        lock       [0:15];

    integer reset_i;

    // ---- Address breakdown for the CURRENT request ----
    wire [1:0]  req_word_offset = addr[3:2];
    wire [3:0]  req_index       = addr[7:4];
    wire [15:0] req_tag         = addr[23:8];
    wire        req_hit         = valid[req_index] && (tag[req_index] == req_tag);

    // Whether req_index is locked, including a lock command landing on
    // THIS index in THIS very cycle. Needed because lock[] is only
    // updated via non-blocking assignment below - a lock_cmd this
    // cycle doesn't actually change lock[req_index]'s readable value
    // until next cycle. Without this, a lock command arriving the same
    // cycle as a conflicting miss on the line being locked would still
    // see the old (unlocked) value and evict the line it was just
    // asked to protect - a real race, not a hypothetical one (found by
    // tracing tb_cache_lock_protection.v: the lock write and the
    // aliasing fetch's miss landed in the exact same cycle).
    wire req_index_locked = lock[req_index] ||
        (lock_cmd && lock_set && (lock_addr[7:4] == req_index));

    // ---- Line-fill bookkeeping (only meaningful during ST_FILL/ST_RETURN) ----
    reg [1:0]  fill_word_idx;        // which word of the line we're on (0-3)
    reg [3:0]  fill_line_index;
    reg [15:0] fill_line_tag;
    reg [1:0]  fill_req_word_offset; // which word the ORIGINAL request wanted

    // ---- Underlying flash controller ----
    reg  [23:0] flash_addr_r;
    reg         flash_req_r;
    wire [31:0] flash_rdata;
    wire        flash_ready;
    wire        flash_busy;

    spi_flash_ctrl flash_ctrl_inst (
        .clk(clk),
        .reset(reset),
        .addr(flash_addr_r),
        .req(flash_req_r),
        .ready(flash_ready),
        .rdata(flash_rdata),
        .busy(flash_busy),
        .sck(sck), .cs_n(cs_n), .mosi(mosi), .miso(miso)
    );

    always @(posedge clk) begin
        ready       <= 1'b0; // default: pulses for exactly 1 cycle
        flash_req_r <= 1'b0; // default: pulses for exactly 1 cycle

        if (reset) begin
            state <= ST_IDLE;
            for (reset_i = 0; reset_i < 16; reset_i = reset_i + 1) begin
                valid[reset_i] <= 1'b0;
                lock[reset_i]  <= 1'b0;
            end
        end else begin
            // Lock commands are just a bit set/clear - handled here,
            // outside the state case, since they can land on any cycle
            // regardless of fetch activity. The miss-routing decision
            // below uses req_index_locked (not the raw lock[] read) so
            // a lock landing the same cycle as a conflicting miss is
            // still honored - see req_index_locked's comment above.
            if (lock_cmd)
                lock[lock_addr[7:4]] <= lock_set;

            case (state)
                ST_IDLE: begin
                    if (req) begin
                        if (req_hit) begin
                            rdata <= cache_data[req_index][req_word_offset];
                            ready <= 1'b1;
                            // stays in ST_IDLE - a hit is just this
                            // one cycle of latency, nothing to track
                        end else if (req_index_locked) begin
                            // Miss, but this slot is locked to
                            // different code - can't evict it. Fetch
                            // just the requested word directly,
                            // bypassing the cache entirely.
                            flash_addr_r <= addr;
                            flash_req_r  <= 1'b1;
                            state        <= ST_BYPASS;
                        end else begin
                            // Miss: start filling the whole line,
                            // starting at word 0 (offset bits cleared).
                            fill_line_index      <= req_index;
                            fill_line_tag        <= req_tag;
                            fill_req_word_offset <= req_word_offset;
                            fill_word_idx         <= 2'd0;
                            flash_addr_r          <= {addr[23:4], 4'b0000};
                            flash_req_r           <= 1'b1;
                            state                 <= ST_FILL;
                        end
                    end
                end

                ST_BYPASS: begin
                    if (flash_ready) begin
                        rdata <= flash_rdata;
                        ready <= 1'b1;
                        state <= ST_IDLE;
                    end
                end

                ST_FILL: begin
                    if (flash_ready) begin
                        cache_data[fill_line_index][fill_word_idx] <= flash_rdata;
                        if (fill_word_idx == 2'd3) begin
                            // Whole line filled - mark it valid and
                            // move to returning the requested word.
                            // Read cache_data fresh in ST_RETURN
                            // (rather than trying to short-circuit
                            // here) so there's no ambiguity about
                            // whether the word we want is the one
                            // that just arrived or one filled earlier.
                            valid[fill_line_index] <= 1'b1;
                            tag[fill_line_index]   <= fill_line_tag;
                            state                  <= ST_RETURN;
                        end else begin
                            fill_word_idx <= fill_word_idx + 2'd1;
                            flash_addr_r  <= flash_addr_r + 24'd4;
                            flash_req_r   <= 1'b1;
                        end
                    end
                end

                ST_RETURN: begin
                    // cache_data is now fully and consistently
                    // populated (the last fill write took effect at
                    // the edge that brought us here) - safe to read
                    // normally.
                    rdata <= cache_data[fill_line_index][fill_req_word_offset];
                    ready <= 1'b1;
                    state <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

    // ---- Instrumentation: hit/miss totals ----
    // Kept in its own always block, separate from the FSM above, so
    // stats_reset can zero the counters without touching state/cache
    // contents. Counts each ST_IDLE request exactly once, at the same
    // point the FSM itself decides hit vs. everything-else.
    always @(posedge clk) begin
        if (reset || stats_reset) begin
            hit_count  <= 32'd0;
            miss_count <= 32'd0;
        end else if (state == ST_IDLE && req) begin
            if (req_hit)
                hit_count <= hit_count + 32'd1;
            else
                miss_count <= miss_count + 32'd1;
        end
    end

endmodule
