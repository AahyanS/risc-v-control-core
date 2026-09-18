// spi_flash_ctrl.v
// QSPI-capable flash controller, single-bit (plain SPI) mode for this
// first version - PROJECT.md calls for starting with plain 0x03 reads
// before optimizing to quad/fast-read.
//
// Speaks standard SPI mode 0 (CPOL=0, CPHA=0), the convention SPI NOR
// flash chips use for the 0x03 "Read Data" command: SCK idles low,
// data is presented on the falling edge and sampled on the following
// rising edge (both master->slave on MOSI and slave->master on MISO
// follow this same convention). One transaction = 8 bits of command
// (0x03) + 24 bits of address + 32 bits of returned data = 64 bits
// total, 2 clk cycles per bit (SCK toggles once per clk cycle) = ~128
// clk cycles per 32-bit read.
//
// SCK here mirrors the system clock while a transaction is active
// (toggled every clk cycle) rather than using an independent, slower
// SPI clock domain - correct and sufficient for simulation, but real
// flash chips have a maximum SPI clock frequency lower than a typical
// FPGA system clock, so this will need a real clock divider once
// hardware bring-up (Phase 5) is underway and the actual chip's
// timing limits are known. Flagged here deliberately, not hidden.

module spi_flash_ctrl (
    input         clk,
    input         reset,

    // Simple request/response interface to the rest of the core
    input  [23:0] addr,     // byte address in flash, word-aligned
    input         req,      // pulse: start a 32-bit read at addr
    output reg    ready,    // pulses high for 1 cycle when rdata is valid
    output reg [31:0] rdata,
    output reg    busy,     // high for the whole transaction

    // Physical SPI pins
    output reg    sck,
    output reg    cs_n,
    output reg    mosi,
    input         miso
);

    localparam CMD_READ = 8'h03;

    reg        xfer_active;
    reg        out_phase;   // 1 = sending cmd+addr, 0 = receiving data
    reg [31:0] out_shift;   // cmd+addr, shifted out from the top bit
    reg [31:0] in_shift;    // data, shifted in from the bottom bit
    reg [5:0]  bits_left;   // bits remaining in the current phase

    always @(posedge clk) begin
        ready <= 1'b0; // default: only asserted for exactly 1 cycle

        if (reset) begin
            xfer_active <= 1'b0;
            cs_n        <= 1'b1;
            sck         <= 1'b0;
            busy        <= 1'b0;
        end else if (!xfer_active) begin
            sck <= 1'b0;
            if (req) begin
                cs_n        <= 1'b0;
                busy        <= 1'b1;
                xfer_active <= 1'b1;
                out_phase   <= 1'b1;
                out_shift   <= {CMD_READ, addr};
                bits_left   <= 6'd32;
                // First bit set directly (not via out_shift) since it
                // must already be stable before the first rising edge,
                // one cycle before out_shift's own shifting begins.
                mosi        <= CMD_READ[7];
            end else begin
                cs_n <= 1'b1;
                busy <= 1'b0;
            end
        end else if (sck == 1'b0) begin
            // This edge is SCK's rising edge: sample miso now, if
            // we've reached the data phase.
            sck <= 1'b1;
            if (!out_phase)
                in_shift <= {in_shift[30:0], miso};
        end else begin
            // This edge is SCK's falling edge: advance to the next
            // bit, well ahead of the next rising edge.
            sck       <= 1'b0;
            bits_left <= bits_left - 6'd1;

            if (bits_left == 6'd1) begin
                if (out_phase) begin
                    // Just sent the last cmd+addr bit - switch to
                    // receiving the 32 data bits.
                    out_phase <= 1'b0;
                    bits_left <= 6'd32;
                    mosi      <= 1'b0; // don't care during the data phase
                end else begin
                    // Just sampled the last data bit - done.
                    xfer_active <= 1'b0;
                    cs_n        <= 1'b1;
                    busy        <= 1'b0;
                    ready       <= 1'b1;
                    // Flash sends bytes in ascending address order
                    // (byte@addr first) - that's genuinely how real
                    // SPI NOR flash works. in_shift's straightforward
                    // bit-shift makes the first-received byte the
                    // MOST-significant byte of the word (big-endian
                    // assembly); everything else in this project
                    // (imem.v/dmem.v) is little-endian - byte@addr is
                    // the LEAST-significant byte. Byte-swap here to
                    // match that convention.
                    rdata <= {in_shift[7:0], in_shift[15:8],
                              in_shift[23:16], in_shift[31:24]};
                end
            end else if (out_phase) begin
                out_shift <= {out_shift[30:0], 1'b0};
                mosi      <= out_shift[30];
            end
        end
    end

endmodule
