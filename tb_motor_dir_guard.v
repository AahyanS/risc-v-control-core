// tb_motor_dir_guard.v
// Checks motor_dir_guard.v's one safety property continuously, every
// cycle, across normal reversals, a request that flips back mid-
// sequence, a request that flips during the second phase, and a
// request toggling every single cycle: DIR must never change while EN
// is high, and EN must have been low for at least DEAD_CYCLES before
// and after every DIR change. Any violation anywhere is counted.
//
// Run with:
//   iverilog -o sim_motor_dir_guard motor_dir_guard.v tb_motor_dir_guard.v
//   vvp sim_motor_dir_guard

`timescale 1ns/1ps

module tb_motor_dir_guard;

    localparam DEAD = 5;

    reg  clk, reset;
    reg  pwm_in, dir_req;
    wire en_out, dir_out;

    motor_dir_guard #(.DEAD_CYCLES(DEAD)) uut (
        .clk(clk), .reset(reset),
        .pwm_in(pwm_in), .dir_req(dir_req),
        .en_out(en_out), .dir_out(dir_out)
    );

    always #5 clk = ~clk;

    // ---- Continuous property checker ----
    reg     prev_en, prev_dir;
    integer low_run;          // consecutive cycles EN has been low
    integer low_before_flip;  // low_run at the moment DIR last flipped
    integer awaiting_after;   // 1 while checking the post-flip low window
    integer violations;
    integer flips;

    initial begin
        violations = 0; flips = 0; low_run = 0;
        awaiting_after = 0; low_before_flip = 0;
    end

    always @(negedge clk) begin
        if (!reset) begin
            if (dir_out !== prev_dir) begin
                flips = flips + 1;
                if (en_out || prev_en) begin
                    violations = violations + 1;
                    $display("VIOLATION t=%0t: DIR changed while EN high", $time);
                end
                if (low_run < DEAD) begin
                    violations = violations + 1;
                    $display("VIOLATION t=%0t: only %0d low cycles before DIR change", $time, low_run);
                end
                awaiting_after = 1;
                low_run = 0;
            end

            if (en_out) begin
                if (awaiting_after && low_run < DEAD) begin
                    violations = violations + 1;
                    $display("VIOLATION t=%0t: EN re-enabled after only %0d low cycles", $time, low_run);
                end
                awaiting_after = 0;
                low_run = 0;
            end else begin
                low_run = low_run + 1;
            end
        end
        prev_en  = en_out;
        prev_dir = dir_out;
    end

    task wait_cycles(input integer n);
        integer k;
        begin
            for (k = 0; k < n; k = k + 1) @(negedge clk);
        end
    endtask

    integer i;
    integer seed;
    integer hold;

    initial begin
        clk = 0; reset = 1; pwm_in = 1; dir_req = 0;
        prev_en = 0; prev_dir = 0;
        wait_cycles(3);
        reset = 0;
        wait_cycles(3);

        if (en_out !== 1'b1 || dir_out !== 1'b0)
            $display("FAIL [PASSTHROUGH]: en=%b dir=%b, expected en=1 dir=0", en_out, dir_out);
        else
            $display("PASS [PASSTHROUGH]: PWM passes straight through when no reversal is pending");

        // ---- Normal reversal ----
        dir_req = 1;
        wait_cycles(1);
        if (en_out !== 1'b0)
            $display("FAIL [EN_DROPS_IMMEDIATELY]: en=%b one cycle after the request", en_out);
        else
            $display("PASS [EN_DROPS_IMMEDIATELY]: EN forced low right after the direction request");
        wait_cycles(3 * DEAD);
        if (dir_out !== 1'b1 || en_out !== 1'b1)
            $display("FAIL [REVERSAL_COMPLETES]: dir=%b en=%b after the sequence", dir_out, en_out);
        else
            $display("PASS [REVERSAL_COMPLETES]: new direction applied and EN restored");

        // ---- Request flips back during phase 1: nothing should change ----
        dir_req = 0;
        wait_cycles(2);
        dir_req = 1;
        wait_cycles(3 * DEAD);
        if (dir_out !== 1'b1)
            $display("FAIL [ABORT_IN_PHASE1]: dir=%b, expected the direction to stay 1", dir_out);
        else
            $display("PASS [ABORT_IN_PHASE1]: a request withdrawn mid-sequence left DIR untouched");

        // ---- Request flips during phase 2 ----
        dir_req = 0;
        wait_cycles(DEAD + 2);    // now inside phase 2 (dir already 0)
        dir_req = 1;
        wait_cycles(6 * DEAD);
        if (dir_out !== 1'b1 || en_out !== 1'b1)
            $display("FAIL [FLIP_IN_PHASE2]: dir=%b en=%b, expected to settle at dir=1 en=1", dir_out, en_out);
        else
            $display("PASS [FLIP_IN_PHASE2]: a flip during phase 2 was resequenced and settled");

        // ---- Worst case: request toggles every cycle, PWM toggling too ----
        for (i = 0; i < 200; i = i + 1) begin
            dir_req = ~dir_req;
            pwm_in  = ~pwm_in;
            wait_cycles(1);
        end
        // ---- Randomized hold times, so many reversals actually complete
        // (the every-cycle storm above always withdraws each request
        // before phase 1 finishes, which is correct but never flips) ----
        seed = 32'd12345;
        for (i = 0; i < 400; i = i + 1) begin
            dir_req = ~dir_req;
            pwm_in  = $random(seed);
            hold    = 1 + ({$random(seed)} % (3 * DEAD));
            wait_cycles(hold);
        end
        pwm_in = 1;
        wait_cycles(4 * DEAD);

        if (flips < 50)
            $display("FAIL [STRESS_EXERCISED]: only %0d completed reversals - stress test too weak", flips);
        else
            $display("PASS [STRESS_EXERCISED]: %0d completed reversals under randomized request timing", flips);

        if (violations != 0)
            $display("FAIL [SAFETY_PROPERTY]: %0d violations across %0d direction changes", violations, flips);
        else
            $display("PASS [SAFETY_PROPERTY]: 0 violations across %0d direction changes - DIR never changed with EN high", flips);

        $display("Testbench complete.");
        $finish;
    end

endmodule
