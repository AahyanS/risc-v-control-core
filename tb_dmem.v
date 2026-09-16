// tb_dmem.v
// Testbench for dmem.v
//
// Run with:
//   iverilog -o sim_dmem dmem.v tb_dmem.v
//   vvp sim_dmem
//
// Every line should print PASS. If any line prints FAIL, the printed
// "got" vs "expected" values tell you exactly which case broke.

`timescale 1ns/1ps

module tb_dmem;

    reg         clk;
    reg  [31:0] addr;
    reg  [31:0] write_data;
    reg         mem_write;
    reg  [2:0]  funct3;
    wire [31:0] read_data;

    dmem uut (
        .clk(clk),
        .addr(addr),
        .write_data(write_data),
        .mem_write(mem_write),
        .funct3(funct3),
        .read_data(read_data)
    );

    always #5 clk = ~clk;

    // funct3 encodings used below, named for readability
    localparam LB  = 3'b000;
    localparam LH  = 3'b001;
    localparam LW  = 3'b010;
    localparam LBU = 3'b100;
    localparam LHU = 3'b101;
    localparam SB  = 3'b000;
    localparam SH  = 3'b001;
    localparam SW  = 3'b010;

    task check_read(input [31:0] exp_val, input [63:0] opname);
        begin
            #1; // let the combinational read settle
            if (read_data !== exp_val)
                $display("FAIL [%0s]: addr=%0d funct3=%0b -> got=%0h expected=%0h",
                          opname, addr, funct3, read_data, exp_val);
            else
                $display("PASS [%0s]: addr=%0d funct3=%0b -> read_data=%0h",
                          opname, addr, funct3, read_data);
        end
    endtask

    // Checks one byte of the underlying storage directly, to verify
    // little-endian byte placement independent of the read logic
    task check_byte(input [31:0] byte_addr, input [7:0] exp_byte,
                     input [63:0] opname);
        begin
            if (uut.mem[byte_addr] !== exp_byte)
                $display("FAIL [%0s]: mem[%0d] got=%0h expected=%0h",
                          opname, byte_addr, uut.mem[byte_addr], exp_byte);
            else
                $display("PASS [%0s]: mem[%0d]=%0h",
                          opname, byte_addr, uut.mem[byte_addr]);
        end
    endtask

    // Drives one synchronous write, using the same edge-safe pattern
    // established in tb_regfile.v
    task write_mem(input [31:0] a, input [31:0] data, input [2:0] f3);
        begin
            @(negedge clk);
            addr       = a;
            write_data = data;
            funct3     = f3;
            mem_write  = 1'b1;
            @(posedge clk);
            @(negedge clk);
            mem_write  = 1'b0;
        end
    endtask

    initial begin
        clk        = 1'b0;
        addr       = 32'd0;
        write_data = 32'd0;
        mem_write  = 1'b0;
        funct3     = 3'b0;

        // ---- SB / LB / LBU: negative byte (top bit set) ----
        // 0xAB = 10101011 - top bit set, so LB must sign-extend to
        // 0xFFFFFFAB while LBU zero-extends to 0x000000AB
        write_mem(32'd0, 32'h000000AB, SB);
        check_byte(32'd0, 8'hAB, "SB_BYTE_0");

        addr = 32'd0; funct3 = LB;
        check_read(32'hFFFFFFAB, "LB_NEGATIVE");

        addr = 32'd0; funct3 = LBU;
        check_read(32'h000000AB, "LBU_NEGATIVE");

        // ---- SB / LB / LBU: positive byte (top bit clear) ----
        // 0x05 has no sign bit, so LB and LBU should agree
        write_mem(32'd12, 32'h00000005, SB);
        addr = 32'd12; funct3 = LB;
        check_read(32'h00000005, "LB_POSITIVE");
        addr = 32'd12; funct3 = LBU;
        check_read(32'h00000005, "LBU_POSITIVE");

        // ---- SH / LH / LHU: negative halfword (top bit set) ----
        // 0xBEEF = 1011...  - top bit set, sign-extend to 0xFFFFBEEF
        write_mem(32'd4, 32'h0000BEEF, SH);
        // Verify little-endian byte placement directly: low byte (0xEF)
        // at the lower address, high byte (0xBE) at the higher address
        check_byte(32'd4, 8'hEF, "SH_LOW_BYTE");
        check_byte(32'd5, 8'hBE, "SH_HIGH_BYTE");

        addr = 32'd4; funct3 = LH;
        check_read(32'hFFFFBEEF, "LH_NEGATIVE");
        addr = 32'd4; funct3 = LHU;
        check_read(32'h0000BEEF, "LHU_NEGATIVE");

        // ---- SH / LH / LHU: positive halfword ----
        write_mem(32'd16, 32'h00001234, SH);
        addr = 32'd16; funct3 = LH;
        check_read(32'h00001234, "LH_POSITIVE");
        addr = 32'd16; funct3 = LHU;
        check_read(32'h00001234, "LHU_POSITIVE");

        // ---- SW / LW: full word, verify little-endian byte order ----
        write_mem(32'd8, 32'hDEADBEEF, SW);
        check_byte(32'd8,  8'hEF, "SW_BYTE_0");
        check_byte(32'd9,  8'hBE, "SW_BYTE_1");
        check_byte(32'd10, 8'hAD, "SW_BYTE_2");
        check_byte(32'd11, 8'hDE, "SW_BYTE_3");

        addr = 32'd8; funct3 = LW;
        check_read(32'hDEADBEEF, "LW_FULL_WORD");

        // ---- mem_write deasserted: a write attempt must not happen ----
        write_mem(32'd20, 32'hCAFEF00D, SW); // establish a known value
        @(negedge clk);
        addr       = 32'd20;
        write_data = 32'h00000000;
        funct3     = SW;
        mem_write  = 1'b0; // disabled
        @(posedge clk);
        @(negedge clk);
        addr = 32'd20; funct3 = LW;
        check_read(32'hCAFEF00D, "WRITE_DISABLED_NO_CHANGE");

        // ---- Adjacent stores don't corrupt each other ----
        // addr 8's word (DEADBEEF) should be untouched by the addr 12/16
        // byte/halfword stores that came after it
        addr = 32'd8; funct3 = LW;
        check_read(32'hDEADBEEF, "NO_CORRUPTION_ADDR_8");

        $display("Testbench complete.");
        $finish;
    end

endmodule
