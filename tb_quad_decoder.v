// tb_quad_decoder.v
// Drives quad_decoder.v through real quadrature sequences (not just
// checking it "doesn't crash") - forward rotation, reverse rotation, a
// direction reversal mid-stream, an idle period, and a deliberately
// illegal double transition - and checks position/error_count against
// hand-computed expected values at each stage.
// Then the single-channel mode (B edges, sign from dir) the project
// uses since its encoder lost channel A.
//
// Run with:
//   iverilog -o sim_quad quad_decoder.v tb_quad_decoder.v
//   vvp sim_quad

`timescale 1ns/1ps

module tb_quad_decoder;

    reg clk, reset;
    reg a, b;
    reg single = 1'b0, dir = 1'b0;
    wire signed [31:0] position;
    wire [31:0] error_count;

    quad_decoder uut (
        .clk(clk),
        .reset(reset),
        .a(a),
        .b(b),
        .clear_position(1'b0),
        .single_channel(single),
        .dir(dir),
        .position(position),
        .error_count(error_count)
    );

    always #5 clk = ~clk;

    // Each state change needs several clock edges to propagate through
    // the 2-flop synchronizer and the decode register before it's
    // reflected in position/error_count - settle() gives it plenty.
    task settle;
        begin
            @(negedge clk); @(negedge clk); @(negedge clk); @(negedge clk);
        end
    endtask

    task step_forward;   // 00 -> 01 -> 11 -> 10 -> 00 (one full line)
        begin
            a=0; b=0; settle;
            a=0; b=1; settle;
            a=1; b=1; settle;
            a=1; b=0; settle;
            a=0; b=0; settle;
        end
    endtask

    task step_reverse;   // 00 -> 10 -> 11 -> 01 -> 00 (one full line)
        begin
            a=0; b=0; settle;
            a=1; b=0; settle;
            a=1; b=1; settle;
            a=0; b=1; settle;
            a=0; b=0; settle;
        end
    endtask

    task check_position(input signed [31:0] expected, input [8*40-1:0] label);
        begin
            if (position !== expected)
                $display("FAIL [%0s]: position=%0d expected=%0d", label, position, expected);
            else
                $display("PASS [%0s]: position=%0d", label, position);
        end
    endtask

    task check_errors(input [31:0] expected, input [8*40-1:0] label);
        begin
            if (error_count !== expected)
                $display("FAIL [%0s]: error_count=%0d expected=%0d", label, error_count, expected);
            else
                $display("PASS [%0s]: error_count=%0d", label, error_count);
        end
    endtask

    initial begin
        clk = 1'b0;
        reset = 1'b1;
        a = 1'b0; b = 1'b0;
        settle;
        reset = 1'b0;
        settle;

        check_position(0, "INITIAL_POSITION");
        check_errors(0, "INITIAL_ERRORS");

        // ---- 3 full forward lines = 12 counts (4x decoding) ----
        step_forward; step_forward; step_forward;
        check_position(12, "FORWARD_3_LINES");
        check_errors(0, "FORWARD_NO_ERRORS");

        // ---- idle: no transitions, position must not drift ----
        settle; settle; settle;
        check_position(12, "IDLE_NO_DRIFT");

        // ---- 2 full reverse lines = -8 counts, net = 12-8=4 ----
        step_reverse; step_reverse;
        check_position(4, "REVERSE_2_LINES");
        check_errors(0, "REVERSE_NO_ERRORS");

        // ---- direction reversal mid-stream: one forward, one
        // reverse, should cancel back to the same net position ----
        step_forward;
        check_position(8, "MID_FORWARD");
        step_reverse;
        check_position(4, "MID_REVERSE_CANCELS");

        // ---- illegal double transition (00 -> 11 directly) - both
        // bits flip in one cycle, not a real encoder move ----
        a = 0; b = 0; settle;
        a = 1; b = 1; settle;   // illegal jump
        check_position(4, "GLITCH_POSITION_UNCHANGED");
        check_errors(1, "GLITCH_COUNTED");

        // recover back to 00 legally (11 -> 10 -> 00, half a forward line)
        a = 1; b = 0; settle;
        a = 0; b = 0; settle;
        check_position(6, "RECOVERY_AFTER_GLITCH");

        // ---- Reset released while the encoder rests at 11 ----
        // A shaft can stop in any of the four states, and the DHB1's
        // Schmitt-trigger buffers invert both channels, so a shaft
        // resting at 00 reaches the FPGA as 11. Coming out of reset
        // must not log a false invalid transition from an assumed 00.
        a = 1; b = 1;
        reset = 1'b1;
        settle; settle;
        reset = 1'b0;
        settle; settle;
        check_errors(0, "RESET_AT_11_NO_FALSE_ERROR");
        check_position(0, "RESET_AT_11_POSITION_ZERO");

        // ---- Both channels inverted, as the DHB1 delivers them ----
        // Forward 00->01->11->10 inverted is 11->10->00->01, which is
        // the same cyclic order, so one full forward line must still
        // count +4, not -4.
        a = 1; b = 0; settle;
        a = 0; b = 0; settle;
        a = 0; b = 1; settle;
        a = 1; b = 1; settle;
        check_position(4, "INVERTED_CHANNELS_KEEP_DIRECTION");
        check_errors(0, "INVERTED_CHANNELS_NO_ERRORS");

        // ---- Single-channel mode: B edges only, sign from dir ----
        // Position is 4 here. A is held stuck, as on this project's
        // encoder.
        single = 1'b1;
        a = 1; b = 1; settle;
        b = 0; settle;  b = 1; settle;  b = 0; settle;  b = 1; settle;
        check_position(8, "SINGLE_FWD_EACH_B_EDGE_PLUS_1");
        dir = 1'b1;
        b = 0; settle;  b = 1; settle;  b = 0; settle;
        check_position(5, "SINGLE_DIR1_EACH_B_EDGE_MINUS_1");
        // A toggling alone must be ignored (it's the dead channel - any
        // noise on it must not count), and no errors are logged.
        a = 0; settle;  a = 1; settle;  a = 0; settle;
        check_position(5, "SINGLE_IGNORES_A");
        // A and B changing in the same cycle: an illegal jump in
        // quadrature mode, just one B edge here.
        dir = 1'b0;
        a = 1; b = 1; settle;
        check_position(6, "SINGLE_AB_TOGETHER_IS_ONE_B_EDGE");
        check_errors(0, "SINGLE_LOGS_NO_ERRORS");
        // Back to quadrature: normal decoding resumes from the current
        // pin state (11), no false count or error from the mode switch.
        single = 1'b0;
        settle;
        a = 1; b = 0; settle;         // 11 -> 10: forward in quadrature
        check_position(7, "BACK_TO_QUADRATURE_DECODES");
        check_errors(0, "MODE_SWITCH_NO_FALSE_ERROR");

        $display("Testbench complete.");
        $finish;
    end

endmodule
