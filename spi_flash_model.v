// spi_flash_model.v
// Behavioral SPI NOR flash model, for simulation only - stands in for
// a real flash chip until real hardware exists (Phase 5). Deliberately
// built as a genuine SPI slave, reacting only to sck/cs_n/mosi edges
// (no hierarchical peek into spi_flash_ctrl.v's internal state) - the
// point is to prove the controller's protocol handling is actually
// correct, not to take a simulation-only shortcut that would pass
// even if the real protocol timing were wrong.
//
// Supports exactly the 0x03 "Read Data" command this project's first
// controller version issues: 8 bits of command (ignored - a real
// chip would check it, this model only implements this one command
// so it doesn't need to) + 24 bits of address + then drives out data
// bytes, MSB-first, continuously incrementing the address for as long
// as sck keeps toggling (real SPI NOR flash chips support exactly
// this "continuous read" behavior).
//
// Loaded with content via $readmemh, same as imem.v/dmem.v - a
// testbench can load a compiled program's hex dump here to simulate
// it actually living in flash.

// ADDR_BASE is the flash address that mem[0] corresponds to - lets a
// testbench model the hardware layout (program image stored above the
// FPGA bitstream) without allocating a multi-megabyte array.

module spi_flash_model #(
    parameter        MEM_BYTES = 8192,
    parameter [23:0] ADDR_BASE = 24'h000000
)(
    input  sck,
    input  cs_n,
    input  mosi,
    output miso
);

    reg [7:0] mem [0:MEM_BYTES-1];

    reg [31:0] shift_in;   // accumulates the 32-bit command+address
    reg [6:0]  bit_count;  // total bits clocked since cs_n was asserted

    always @(posedge sck or posedge cs_n) begin
        if (cs_n) begin
            bit_count <= 7'd0;
            shift_in  <= 32'd0;
        end else begin
            if (bit_count < 7'd32)
                shift_in <= {shift_in[30:0], mosi};
            bit_count <= bit_count + 7'd1;
        end
    end

    // Address is only meaningful once all 32 command+address bits
    // have arrived - waiting for bit_count to reach 32 (rather than
    // trying to compute it mid-shift, one edge early) avoids an
    // off-by-one on the boundary between the two phases.
    wire        addr_valid = (bit_count >= 7'd32);
    wire [23:0] flash_addr = shift_in[23:0];

    // How many bits into the data phase are we, and which specific
    // bit of which byte does that correspond to (MSB-first, address
    // auto-incrementing as more bits are clocked past the current
    // byte's 8).
    wire [6:0]  data_bit_index = bit_count - 7'd32;
    wire [23:0] byte_index     = (flash_addr - ADDR_BASE + (data_bit_index >> 3)) % MEM_BYTES;
    wire [2:0]  bit_in_byte    = 3'd7 - data_bit_index[2:0];

    assign miso = (!cs_n && addr_valid) ? mem[byte_index][bit_in_byte] : 1'b0;

endmodule
