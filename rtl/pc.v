// pc.v
// Program counter for RV32I
//
// Holds the address of the current instruction. Advances to whatever
// address pc_next carries on each clock edge; the caller is responsible
// for computing pc_next (pc+4 normally, a branch/jump target later) so
// this module never needs to change when branch logic is added.

module pc (
    input         clk,
    input         reset,
    input  [31:0] pc_next,
    output reg [31:0] pc
);

    always @(posedge clk) begin
        if (reset)
            pc <= 32'd0;
        else
            pc <= pc_next;
    end

endmodule
