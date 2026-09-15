// regfile.v
// 32 x 32-bit register file for RV32I
//
// Two combinational read ports, one clocked write port.
// x0 is hardwired to zero: reads of x0 always return 0, and writes
// targeting x0 are ignored, regardless of we/rd_addr/rd_data.

module regfile (
    input         clk,
    input         we,        // write enable
    input  [4:0]  rs1_addr,  // read port 1 address
    input  [4:0]  rs2_addr,  // read port 2 address
    input  [4:0]  rd_addr,   // write port address
    input  [31:0] rd_data,   // write port data
    output [31:0] rs1_data,  // read port 1 data
    output [31:0] rs2_data   // read port 2 data
);

    reg [31:0] regs [0:31];

    // Reads are combinational and bypass storage for x0, so x0 reads as
    // zero even though regs[0] itself is never written.
    assign rs1_data = (rs1_addr == 5'd0) ? 32'd0 : regs[rs1_addr];
    assign rs2_data = (rs2_addr == 5'd0) ? 32'd0 : regs[rs2_addr];

    always @(posedge clk) begin
        if (we && rd_addr != 5'd0)
            regs[rd_addr] <= rd_data;
    end

endmodule
