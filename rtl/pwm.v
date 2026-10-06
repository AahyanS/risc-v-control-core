// pwm.v
// PWM (pulse-width modulation) output generator - the PID's actuator
// side, the counterpart to quad_decoder.v's sensor side.
//
// A free-running counter cycles 0..PERIOD-1; the output is high while
// counter < duty_cycle, low otherwise - the standard "compare counter
// against a threshold" PWM generator. Runs continuously off clk
// regardless of what the CPU is doing, same as quad_decoder.v - once
// software sets duty_cycle, the waveform keeps running on its own; the
// CPU doesn't need to service it every period the way a
// software-bit-banged PWM would.
//
// duty_cycle is clamped internally: >= PERIOD reads as 100% (output
// always high, since counter < PERIOD is always true across the full
// range 0..PERIOD-1), and since duty_cycle is unsigned, 0 already
// means 0% (counter < 0 is never true) with no clamping needed on
// that side.
//
// PERIOD is a parameter, not runtime-configurable - fixed switching
// frequency, only duty cycle varies at runtime. Real hardware timing
// (matching a specific target PWM frequency in kHz) is a Phase 5
// concern once real motor driver hardware is in the loop; this is the
// generator itself, parameterized so that tuning is a one-line change
// later rather than a redesign.

module pwm #(
    parameter PERIOD = 1024   // clock cycles per PWM period
) (
    input         clk,
    input         reset,
    input  [31:0] duty_cycle,   // 0..PERIOD-1 for a proper fraction; >=PERIOD saturates to 100%
    output        pwm_out
);

    reg [31:0] counter;

    always @(posedge clk) begin
        if (reset)
            counter <= 32'd0;
        else if (counter == PERIOD - 1)
            counter <= 32'd0;
        else
            counter <= counter + 32'd1;
    end

    assign pwm_out = (counter < duty_cycle);

endmodule
