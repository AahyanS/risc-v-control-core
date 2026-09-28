// bringup_top.v
// First design to load onto a new Basys3 - deliberately unrelated to
// the RISC-V core. If this works, Vivado, the USB-JTAG connection, and
// the board are all confirmed good, so any later problem is in the
// real design rather than the toolchain.
//
// LD0-LD14 follow switches SW0-SW14. LD15 blinks at about 1.5 Hz,
// proving the clock is running and the FPGA is actually configured
// (a switch-to-LED path alone would look identical to a short).
// Holding the center button freezes the blink.

module bringup_top (
    input         clk,       // 100 MHz
    input         btnC,
    input  [14:0] sw,
    output [15:0] led
);

    reg [25:0] count = 26'd0;

    always @(posedge clk)
        if (!btnC) count <= count + 26'd1;

    assign led = {count[25], sw};

endmodule
