// tb_pwm.v
// Drives pwm.v at several duty_cycle settings and measures the
// ACTUAL fraction of cycles pwm_out is high over a full period -
// not just "it toggles," but that the measured duty cycle matches
// what was programmed, including the 0% and 100% edge cases.
//
// Uses a small PERIOD (20) for fast simulation - the counter/compare
// logic doesn't care about the numeric period size, so a small one
// exercises the same logic a larger real one would.
//
// Run with:
//   iverilog -o sim_pwm rtl/pwm.v tb/tb_pwm.v
//   vvp sim_pwm

`timescale 1ns/1ps

module tb_pwm;

    reg clk, reset;
    reg [31:0] duty_cycle;
    wire pwm_out;
    integer i, high_count;

    pwm #(.PERIOD(20)) uut (
        .clk(clk),
        .reset(reset),
        .duty_cycle(duty_cycle),
        .pwm_out(pwm_out)
    );

    always #5 clk = ~clk;

    task measure_duty(input [31:0] set_duty, input [31:0] expected_high_count, input [63:0] label);
        begin
            duty_cycle = set_duty;
            reset = 1'b1;
            @(negedge clk); @(negedge clk);
            reset = 1'b0;

            high_count = 0;
            for (i = 0; i < 20; i = i + 1) begin
                @(posedge clk);
                if (pwm_out) high_count = high_count + 1;
                @(negedge clk);
            end

            if (high_count !== expected_high_count)
                $display("FAIL [%0s]: duty_cycle=%0d high_count=%0d/20 expected=%0d/20",
                          label, set_duty, high_count, expected_high_count);
            else
                $display("PASS [%0s]: duty_cycle=%0d -> %0d/20 cycles high, as expected",
                          label, set_duty, high_count);
        end
    endtask

    initial begin
        clk = 1'b0;

        measure_duty(0,  0,  "ZERO_PERCENT");
        measure_duty(10, 10, "FIFTY_PERCENT");
        measure_duty(20, 20, "HUNDRED_PERCENT_EXACT");
        measure_duty(25, 20, "OVER_PERIOD_SATURATES_TO_100");
        measure_duty(5,  5,  "TWENTYFIVE_PERCENT");
        measure_duty(1,  1,  "MINIMUM_NONZERO");

        $display("Testbench complete.");
        $finish;
    end

endmodule
