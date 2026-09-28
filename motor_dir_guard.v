// motor_dir_guard.v
// Sits between the CPU's PWM/direction outputs and the Pmod DHB1's
// EN/DIR pins. Digilent's DHB1 documentation warns that changing a
// motor's DIR pin while its EN pin is active can short the H-bridge
// and damage the board. This enforces the safe sequence in hardware,
// so no software bug - a PID output flipping sign every loop, say -
// can ever violate it:
//
//   1. direction request changes -> force EN low, keep old DIR,
//      wait DEAD_CYCLES (motor current decays)
//   2. switch DIR, keep EN low, wait DEAD_CYCLES again (DIR settles
//      at the pin before the bridge is re-enabled)
//   3. release EN back to the PWM signal
//
// If the request flips back to the current direction during step 1,
// nothing needs to change and it returns straight to running. A
// request change during step 2 is handled after step 2 completes, by
// starting the sequence over - DIR never changes while EN is high.
//
// The cost is a short window with the motor unpowered on every
// reversal (2 * DEAD_CYCLES), which shows up as a small dead zone in
// a position loop hovering around its setpoint. fpga/basys3_top.v
// sets DEAD_CYCLES for 100 us per phase at 25 MHz.

module motor_dir_guard #(
    parameter DEAD_CYCLES = 2500
) (
    input      clk,
    input      reset,

    input      pwm_in,    // raw PWM from pwm.v
    input      dir_req,   // direction requested by software

    output     en_out,    // to DHB1 EN
    output reg dir_out    // to DHB1 DIR
);

    localparam ST_RUN  = 2'd0;
    localparam ST_OFF1 = 2'd1;   // EN forced low, old direction still applied
    localparam ST_OFF2 = 2'd2;   // EN forced low, new direction applied

    reg [1:0]  state;
    reg [31:0] count;

    assign en_out = (state == ST_RUN) ? pwm_in : 1'b0;

    always @(posedge clk) begin
        if (reset) begin
            state   <= ST_RUN;
            count   <= 32'd0;
            dir_out <= 1'b0;
        end else begin
            case (state)
                ST_RUN: begin
                    if (dir_req != dir_out) begin
                        state <= ST_OFF1;
                        count <= 32'd0;
                    end
                end

                ST_OFF1: begin
                    if (dir_req == dir_out) begin
                        state <= ST_RUN;
                    end else if (count == DEAD_CYCLES - 1) begin
                        dir_out <= dir_req;
                        state   <= ST_OFF2;
                        count   <= 32'd0;
                    end else begin
                        count <= count + 32'd1;
                    end
                end

                ST_OFF2: begin
                    if (count == DEAD_CYCLES - 1)
                        state <= ST_RUN;
                    else
                        count <= count + 32'd1;
                end

                default: state <= ST_RUN;
            endcase
        end
    end

endmodule
