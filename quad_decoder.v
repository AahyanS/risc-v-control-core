// quad_decoder.v
// Quadrature encoder decoder. Two input channels (a, b), 90 degrees
// out of phase, cycle through 4 states per encoder line:
//   00 -> 01 -> 11 -> 10 -> 00   (forward)
//   00 -> 10 -> 11 -> 01 -> 00   (reverse)
// Decoding every transition (not just one channel's rising edge)
// gives 4 counts per physical line - "4x decoding," the standard
// approach.
//
// Runs entirely in hardware, sampling every clock cycle regardless of
// what the CPU is doing - the same determinism argument as cache
// locking, applied to a different subsystem. A software-polled
// decoder would be exactly as vulnerable to CPU-side jitter (cache
// misses, whatever else is running) as anything else on the CPU; this
// peripheral sidesteps that by not depending on CPU timing at all.
//
// a/b are raw external signals - asynchronous to clk, so sampling
// them directly risks metastability. Passed through a 2-flop
// synchronizer before use, standard practice for any signal crossing
// into this clock domain from outside the chip.

module quad_decoder (
    input  clk,
    input  reset,

    input  a,
    input  b,

    // Zeroes position ONLY, on the cycle it's asserted - deliberately
    // separate from reset. Clearing prev_state/the synchronizer
    // together with position (i.e. folding this into reset) would
    // lose track of the actual current a/b state; the next real
    // transition afterward could then be misread as a spurious move,
    // or even flagged as an invalid double-transition, purely because
    // decoding restarted from an assumed 00 that might not match
    // reality.
    input  clear_position,

    output reg signed [31:0] position,
    output reg [31:0]        error_count   // counts invalid (double) transitions - diagnostic only
);

    // ---- Synchronizer ----
    reg a_sync1, a_sync2;
    reg b_sync1, b_sync2;

    always @(posedge clk) begin
        if (reset) begin
            a_sync1 <= 1'b0; a_sync2 <= 1'b0;
            b_sync1 <= 1'b0; b_sync2 <= 1'b0;
        end else begin
            a_sync1 <= a;       a_sync2 <= a_sync1;
            b_sync1 <= b;       b_sync2 <= b_sync1;
        end
    end

    wire [1:0] curr_state = {a_sync2, b_sync2};
    reg  [1:0] prev_state;

    // ---- Decode: compare this cycle's state to last cycle's ----
    always @(posedge clk) begin
        if (reset) begin
            prev_state  <= 2'b00;
            position    <= 32'sd0;
            error_count <= 32'd0;
        end else begin
            prev_state <= curr_state;

            case ({prev_state, curr_state})
                // forward sequence
                4'b00_01, 4'b01_11, 4'b11_10, 4'b10_00:
                    position <= clear_position ? 32'sd0 : position + 32'sd1;
                // reverse sequence
                4'b00_10, 4'b10_11, 4'b11_01, 4'b01_00:
                    position <= clear_position ? 32'sd0 : position - 32'sd1;
                // no change
                4'b00_00, 4'b01_01, 4'b10_10, 4'b11_11:
                    if (clear_position) position <= 32'sd0;
                // anything else is a double transition - both bits
                // flipped in one cycle, which a real quadrature signal
                // can't do (this clock is far faster than any real
                // encoder edge rate) - a glitch or a missed sample,
                // not a legal move. Counted (independent of
                // clear_position - error tracking is unrelated to
                // software resetting the position reference), not
                // acted on otherwise.
                default: begin
                    if (clear_position) position <= 32'sd0;
                    error_count <= error_count + 32'd1;
                end
            endcase
        end
    end

endmodule
