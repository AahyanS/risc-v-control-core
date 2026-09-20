// regfile.v
// 32 x 32-bit register file for RV32I
//
// Three combinational read ports, one clocked write port. The third
// port (rs3) is unused by ordinary RV32I decode - it exists for the
// custom MAC instruction (`mac rd, rs1, rs2`, Phase 4), which reads
// rd's OWN current value as an implicit accumulator input alongside
// the normal rs1/rs2 multiplicands, needing three distinct reads in
// one cycle where ordinary R-type instructions only ever need two.
// Every other CPU configuration in this project leaves rs3_addr
// unconnected, which is fine - it's a pure combinational lookup with
// no side effects, so an unused port can't affect anything else this
// module does.
//
// x0 is hardwired to zero: reads of x0 always return 0, and writes
// targeting x0 are ignored, regardless of we/rd_addr/rd_data.

module regfile (
    input         clk,
    input         we,        // write enable
    input  [4:0]  rs1_addr,  // read port 1 address
    input  [4:0]  rs2_addr,  // read port 2 address
    input  [4:0]  rs3_addr,  // read port 3 address (MAC's accumulator read)
    input  [4:0]  rd_addr,   // write port address
    input  [31:0] rd_data,   // write port data
    output [31:0] rs1_data,  // read port 1 data
    output [31:0] rs2_data,  // read port 2 data
    output [31:0] rs3_data   // read port 3 data
);

    reg [31:0] regs [0:31];

    // Reads are combinational and bypass storage for x0, so x0 reads as
    // zero even though regs[0] itself is never written.
    assign rs1_data = (rs1_addr == 5'd0) ? 32'd0 : regs[rs1_addr];
    assign rs2_data = (rs2_addr == 5'd0) ? 32'd0 : regs[rs2_addr];
    assign rs3_data = (rs3_addr == 5'd0) ? 32'd0 : regs[rs3_addr];

    always @(posedge clk) begin
        if (we && rd_addr != 5'd0)
            regs[rd_addr] <= rd_data;
    end

endmodule
