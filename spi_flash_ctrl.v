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
// SCK toggles once per clk cycle while a transaction is active, so SCK
// runs at clk/2. On hardware (fpga/basys3_top.v) the whole system is
// clocked at 25 MHz, giving a 12.5 MHz SCK - well under the 0x03 read
// command's limit on either flash part Basys3 boards ship with (40 MHz
// on the older Spansion part, 54 MHz on the Micron one), and leaving a
// full 40 ns clk period between SCK falling (flash shifts out a bit)
// and the next SCK rising (sampled here) to cover the STARTUPE2 clock
// path, the flash's own output delay, and pad delays.
//
// FLASH_BASE is added to every address before it goes out on the bus,
// so the program image can sit above the FPGA bitstream in the same
// flash chip while the CPU still sees it starting at address 0. It
// defaults to 0, which is what every simulation testbench uses.
//
// abort ends the current transaction immediately: chip-select goes
// high (which a SPI flash treats as the end of the read command at any
// point), no ready pulse, back to idle. It wins over a req in the same
// cycle. Used when a fetch in flight is going to be thrown away - an
// interrupt redirecting fetch - so the next transaction can start at
// once instead of after up to 64 more SCK periods. Chip-select then
// stays high for at least one cycle before the next read (the idle
// state only drops it the cycle after it sees req).

module spi_flash_ctrl #(
    parameter [23:0] FLASH_BASE = 24'h000000
) (
    input         clk,
    input         reset,

    // Simple request/response interface to the rest of the core
    input  [23:0] addr,     // byte address in flash, word-aligned
    input         req,      // pulse: start a 32-bit read at addr
    input         abort,    // end the current transaction now (see header)
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

        if (reset || abort) begin
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
                out_shift   <= {CMD_READ, addr + FLASH_BASE};
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
