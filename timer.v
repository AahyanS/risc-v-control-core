// timer.v
// Free-running periodic timer - the trigger source for the control
// loop's timer interrupt. count increments every cycle; when it
// reaches compare, it reloads to 0 (periodic - this project only
// needs a repeating trigger, so one-shot mode is deliberately not
// built) and raises pending, which stays set until software
// acknowledges it via clear_pending.
//
// Deviates from real RISC-V CLINT convention on purpose: real
// hardware typically has software clear a pending timer interrupt by
// writing a new (future) value to mtimecmp, with no separate
// "acknowledge" register. A dedicated clear_pending address is
// simpler to reason about and use from an ISR, at the cost of not
// matching real CLINT semantics exactly - a documented simplification,
// same pattern as this project's other "simple correct version first"
// calls.
//
// clear_pending vs. a new match landing the same cycle: the new match
// wins. Silently losing a real interrupt event to a same-cycle
// acknowledgment race would be worse than occasionally requiring
// software to notice pending is still set after clearing it.

module timer (
    input         clk,
    input         reset,

    input  [31:0] compare,
    input         clear_pending,

    output reg [31:0] count,
    output reg        pending
);

    always @(posedge clk) begin
        if (reset) begin
            count   <= 32'd0;
            pending <= 1'b0;
        end else if (count == compare) begin
            count   <= 32'd0;
            pending <= 1'b1;
        end else begin
            count <= count + 32'd1;
            if (clear_pending)
                pending <= 1'b0;
        end
    end

endmodule
