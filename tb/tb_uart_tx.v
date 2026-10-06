// tb_uart_tx.v
// Checks uart_tx.v only through its tx pin, the way a PC's UART sees
// it: a receiver model waits for the start bit's falling edge, then
// samples each bit in the middle of its period. Also measures the
// exact length of every bit, since the PC is timing the bits itself
// and a wrong length would corrupt later bits even if the first ones
// look fine.
//
// Two instances: CLKS_PER_BIT = 8 for fast, thorough checks, and the
// real 217 (25 MHz / 115200 baud) for one byte, so the value the
// hardware uses is exercised too.
//
//   iverilog -o sim_uart_tx rtl/uart_tx.v tb/tb_uart_tx.v
//   vvp sim_uart_tx

`timescale 1ns/1ps

module tb_uart_tx;

    localparam CPB = 8;

    reg clk = 0;
    always #5 clk = ~clk;

    reg        reset = 1;
    reg  [7:0] data = 0;
    reg        start = 0;
    wire       tx, busy;

    uart_tx #(.CLKS_PER_BIT(CPB)) uut (
        .clk(clk), .reset(reset), .data(data), .start(start),
        .tx(tx), .busy(busy)
    );

    reg  [7:0] data_r = 0;
    reg        start_r = 0;
    wire       tx_r, busy_r;

    uart_tx #(.CLKS_PER_BIT(217)) uut_real (
        .clk(clk), .reset(reset), .data(data_r), .start(start_r),
        .tx(tx_r), .busy(busy_r)
    );

    integer fails = 0;

    task check(input cond, input [8*48-1:0] msg);
        begin
            if (cond) $display("PASS [%0s]", msg);
            else begin $display("FAIL [%0s]", msg); fails = fails + 1; end
        end
    endtask

    // ---- Receiver model (for the CPB = 8 instance) ----
    // Records every byte received, whether its stop bit was high, and
    // whether every bit lasted exactly CPB cycles.
    reg  [7:0] rx_bytes [0:63];
    integer    rx_count = 0;
    integer    framing_errors = 0;
    integer    timing_errors = 0;

    integer    b, len;
    reg  [7:0] shift;
    reg        level;

    always begin
        @(negedge tx);                  // start bit begins
        if (!reset) begin
            // Sample mid-bit: half a bit into the start bit, then one
            // full bit period for each following bit.
            repeat (CPB / 2) @(posedge clk);
            if (tx !== 1'b0) framing_errors = framing_errors + 1;
            for (b = 0; b < 8; b = b + 1) begin
                repeat (CPB) @(posedge clk);
                shift[b] = tx;
            end
            repeat (CPB) @(posedge clk);
            if (tx !== 1'b1) framing_errors = framing_errors + 1;
            rx_bytes[rx_count] = shift;
            rx_count = rx_count + 1;
        end
    end

    // Bit-length checker: every run of the same level on tx inside a
    // frame must be a whole multiple of CPB cycles (consecutive equal
    // bits merge into one longer run). Low runs always end inside a
    // frame. A high run is skipped when it ends in a start bit
    // (bits_left == 10): that run includes idle time, which can be
    // any length.
    integer run = 0;
    reg     prev_tx = 1;
    always @(posedge clk) begin
        if (tx !== prev_tx) begin
            if (!reset && prev_tx == 1'b0 && run % CPB != 0)
                timing_errors = timing_errors + 1;
            if (!reset && prev_tx == 1'b1 && uut.bits_left != 4'd10 &&
                run % CPB != 0)
                timing_errors = timing_errors + 1;
            run = 1;
        end else begin
            run = run + 1;
        end
        prev_tx <= tx;
    end

    task send(input [7:0] v);
        begin
            @(negedge clk);
            data = v; start = 1;
            @(negedge clk);
            start = 0;
        end
    endtask

    task wait_idle;
        begin
            @(negedge clk);
            while (busy) @(negedge clk);
        end
    endtask

    integer i, errs, start_len, ignored_before;
    integer busy_cycles;

    initial begin
        // ---- Reset: line must idle high, never look like a start bit ----
        repeat (5) @(negedge clk);
        check(tx === 1'b1 && tx_r === 1'b1, "TX_IDLES_HIGH_DURING_RESET");
        reset = 0;
        repeat (20) @(negedge clk);
        check(tx === 1'b1 && busy === 1'b0, "TX_IDLES_HIGH_AFTER_RESET");
        check(rx_count == 0, "NO_SPURIOUS_BYTE_AFTER_RESET");

        // ---- One byte ----
        send(8'hA5);
        check(busy === 1'b1, "BUSY_RISES_AFTER_START");
        wait_idle;
        repeat (CPB) @(negedge clk);
        check(rx_count == 1 && rx_bytes[0] == 8'hA5, "SINGLE_BYTE_A5_RECEIVED");

        // ---- Busy lasts exactly one frame (10 bits) ----
        send(8'h3C);
        busy_cycles = 0;           // send() returns on the first busy cycle,
                                   // which the loop below counts
        while (busy) begin @(negedge clk); busy_cycles = busy_cycles + 1; end
        $display("busy for %0d cycles (expect %0d)", busy_cycles, 10 * CPB);
        check(busy_cycles == 10 * CPB, "BUSY_LASTS_EXACTLY_ONE_FRAME");

        // ---- Edge-case bytes: all zeros (longest low run, 9 bits),
        //      all ones (no edges in the data at all), alternating ----
        send(8'h00); wait_idle;
        send(8'hFF); wait_idle;
        send(8'h55); wait_idle;
        send(8'h80); wait_idle;    // only the last data bit set
        send(8'h01); wait_idle;    // only the first data bit set
        repeat (CPB) @(negedge clk);
        check(rx_bytes[2] == 8'h00 && rx_bytes[3] == 8'hFF &&
              rx_bytes[4] == 8'h55 && rx_bytes[5] == 8'h80 &&
              rx_bytes[6] == 8'h01, "EDGE_CASE_BYTES_RECEIVED");

        // ---- start while busy must be ignored, not corrupt the frame ----
        ignored_before = rx_count;
        send(8'h42);
        repeat (3 * CPB) @(negedge clk);
        send(8'hEE);               // mid-frame: should be dropped
        wait_idle;
        repeat (4 * CPB) @(negedge clk);
        check(rx_count == ignored_before + 1 && rx_bytes[ignored_before] == 8'h42,
              "START_WHILE_BUSY_IGNORED");

        // ---- Back-to-back: next byte starts the cycle busy drops,
        //      the way software polling busy will drive it ----
        ignored_before = rx_count;
        for (i = 0; i < 16; i = i + 1) begin
            send(i * 17);
            while (busy) @(negedge clk);
        end
        wait_idle;
        repeat (2 * CPB) @(negedge clk);
        errs = 0;
        for (i = 0; i < 16; i = i + 1)
            if (rx_bytes[ignored_before + i] != ((i * 17) & 8'hFF)) errs = errs + 1;
        check(rx_count == ignored_before + 16 && errs == 0,
              "BACK_TO_BACK_16_BYTES_RECEIVED");

        check(framing_errors == 0, "ALL_START_AND_STOP_BITS_CORRECT");
        check(timing_errors == 0,  "EVERY_BIT_EXACTLY_CLKS_PER_BIT_LONG");

        // ---- The real 115200-baud setting: measure the start bit and
        //      decode one byte at 217 cycles per bit ----
        @(negedge clk);
        data_r = 8'h6B; start_r = 1;
        @(negedge clk);
        start_r = 0;
        start_len = 0;             // tx_r is low now; the loop counts
                                   // this cycle too
        while (tx_r === 1'b0) begin @(negedge clk); start_len = start_len + 1; end
        $display("217-cycle instance: start bit lasted %0d cycles", start_len);
        check(start_len == 217, "REAL_BAUD_START_BIT_217_CYCLES");
        // Now in data bit 0 (1, since 0x6B is odd). Sample mid-bit.
        repeat (108) @(negedge clk);
        shift[0] = tx_r;
        for (b = 1; b < 8; b = b + 1) begin
            repeat (217) @(negedge clk);
            shift[b] = tx_r;
        end
        repeat (217) @(negedge clk);
        check(shift == 8'h6B && tx_r === 1'b1, "REAL_BAUD_BYTE_6B_RECEIVED");

        if (fails == 0) $display("ALL CHECKS PASSED");
        else            $display("%0d CHECK(S) FAILED", fails);
        $finish;
    end

endmodule
