// uart_tx.v
// UART transmitter: sends one byte at a time as a standard 8N1 frame
// (1 start bit, 8 data bits least-significant first, 1 stop bit, no
// parity). On the Basys3 the tx pin goes to the board's USB-UART
// bridge, so the CPU can print text to a serial terminal on the PC
// over the same USB cable used for programming - the way this project
// gets measurements off real hardware.
//
// UART has no clock wire. The line idles high; the receiver watches
// for the falling edge of the start bit and then times every
// following bit itself, so both ends must agree on the bit length:
// CLKS_PER_BIT clock cycles. At 25 MHz and 115200 baud that's
// 25_000_000 / 115_200 = 217.01 -> 217, a 0.006% rate error (UART
// tolerates a few percent).
//
// Interface: pulse `start` for one cycle with `data` valid to send a
// byte. `busy` is high from the cycle after `start` until the stop
// bit has finished; a `start` while busy is ignored, so software must
// poll busy before writing the next byte (see the 0xFFFFFF30 register
// in cpu_pipeline_cache_locked.v).

module uart_tx #(
    parameter CLKS_PER_BIT = 217
) (
    input            clk,
    input            reset,

    input      [7:0] data,
    input            start,

    output reg       tx,
    output           busy
);

    // The whole frame lives in one shift register: {stop, data, start}.
    // Each bit period the lowest bit goes out on tx and the rest shift
    // down, so sending a frame is just "shift 10 times." Shifting in
    // 1s from the top means the line is already at the idle level once
    // the frame is done.
    reg [9:0]  frame;
    reg [3:0]  bits_left;     // bits of the frame not yet finished
    reg [15:0] clk_count;     // cycles spent on the current bit

    assign busy = (bits_left != 4'd0);

    always @(posedge clk) begin
        if (reset) begin
            tx        <= 1'b1;   // idle high - a low line during reset
                                 // would look like a start bit
            frame     <= 10'h3FF;
            bits_left <= 4'd0;
            clk_count <= 16'd0;
        end else if (!busy) begin
            if (start) begin
                frame     <= {1'b1, data, 1'b0};
                bits_left <= 4'd10;
                clk_count <= 16'd0;
                tx        <= 1'b0;             // start bit goes out now
            end
        end else if (clk_count == CLKS_PER_BIT - 1) begin
            // Current bit has lasted a full bit period: move to the
            // next one.
            clk_count <= 16'd0;
            bits_left <= bits_left - 4'd1;
            frame     <= {1'b1, frame[9:1]};
            tx        <= frame[1];             // the bit that's about to
                                               // become frame[0]
        end else begin
            clk_count <= clk_count + 16'd1;
        end
    end

endmodule
