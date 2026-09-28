// xilinx_stubs.v
// Simulation-only stand-ins for the Xilinx primitives basys3_top.v
// uses, so the board wrapper can be simulated with Icarus Verilog.
// Never read by Vivado (fpga/build.tcl doesn't include this file) -
// Vivado has the real primitives.
//
// MMCME2_BASE: passes the input clock straight through (frequency
//   doesn't matter functionally) and raises LOCKED a few cycles after
//   reset is released, like the real one.
// BUFG: a wire.
// STARTUPE2: models the one behavior the wrapper depends on - per
//   Xilinx UG470, the first three USRCCLKO cycles after configuration
//   never reach the CCLK pin. The pin value is exposed as cclk_pin for
//   the testbench to connect to the flash model (the real primitive
//   drives a physical pin, not a port).

`timescale 1ns/1ps

module MMCME2_BASE #(
    parameter CLKIN1_PERIOD    = 10.0,
    parameter CLKFBOUT_MULT_F  = 10.0,
    parameter DIVCLK_DIVIDE    = 1,
    parameter CLKOUT0_DIVIDE_F = 10.0
) (
    input  CLKIN1,
    input  CLKFBIN,
    output CLKFBOUT,
    output CLKOUT0,
    output reg LOCKED,
    input  PWRDWN,
    input  RST
);
    reg [3:0] lock_count;

    assign CLKOUT0  = CLKIN1;
    assign CLKFBOUT = CLKIN1;

    always @(posedge CLKIN1 or posedge RST) begin
        if (RST) begin
            lock_count <= 4'd0;
            LOCKED     <= 1'b0;
        end else if (lock_count == 4'd10) begin
            LOCKED <= 1'b1;
        end else begin
            lock_count <= lock_count + 4'd1;
        end
    end
endmodule

module BUFG (
    input  I,
    output O
);
    assign O = I;
endmodule

module STARTUPE2 #(
    parameter PROG_USR      = "FALSE",
    parameter SIM_CCLK_FREQ = 0.0
) (
    output CFGCLK,
    output CFGMCLK,
    output reg EOS,
    output PREQ,
    input  CLK,
    input  GSR,
    input  GTS,
    input  KEYCLEARB,
    input  PACK,
    input  USRCCLKO,
    input  USRCCLKTS,
    input  USRDONEO,
    input  USRDONETS
);
    assign CFGCLK  = 1'b0;
    assign CFGMCLK = 1'b0;
    assign PREQ    = 1'b0;

    // End of startup a little after time zero.
    initial begin
        EOS = 1'b0;
        #200 EOS = 1'b1;
    end

    // Swallow the first three USRCCLKO cycles after EOS; pass the rest.
    reg [1:0] swallowed = 2'd0;
    reg       passing   = 1'b0;

    always @(posedge USRCCLKO)
        if (EOS && !passing && swallowed != 2'd3)
            swallowed <= swallowed + 2'd1;

    always @(negedge USRCCLKO)
        if (swallowed == 2'd3)
            passing <= 1'b1;

    wire cclk_pin = passing ? USRCCLKO : 1'b0;
endmodule
