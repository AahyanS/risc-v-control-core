// tb_imem.v
// Testbench for imem.v
//
// Run with:
//   iverilog -o sim_imem imem.v tb_imem.v
//   vvp sim_imem
//
// Every line should print PASS. If any line prints FAIL, the printed
// "got" vs "expected" values tell you exactly which case broke.

`timescale 1ns/1ps

module tb_imem;

    reg  [31:0] addr;
    wire [31:0] instr;

    imem uut (
        .addr(addr),
        .instr(instr)
    );

    task check(input [31:0] exp_instr, input [63:0] opname);
        begin
            #1; // let the combinational read settle
            if (instr !== exp_instr)
                $display("FAIL [%0s]: addr=%0d -> got=%0h expected=%0h",
                          opname, addr, instr, exp_instr);
            else
                $display("PASS [%0s]: addr=%0d -> instr=%0h",
                          opname, addr, instr);
        end
    endtask

    initial begin
        // No RISC-V toolchain yet, so load hand-picked words directly
        // into imem's internal array via hierarchical reference -
        // this stands in for "compiling a program into memory."
        uut.mem[0]   = 32'hA0A0A0A0;
        uut.mem[1]   = 32'hB1B1B1B1;
        uut.mem[2]   = 32'hC2C2C2C2;
        uut.mem[3]   = 32'hD3D3D3D3;
        uut.mem[255] = 32'hFEFEFEFE; // last valid word, top of the array

        // Word 0 lives at byte address 0
        addr = 32'd0;
        check(32'hA0A0A0A0, "WORD_0");

        // Word 1 lives at byte address 4, matching pc.v's pc+4 stepping
        addr = 32'd4;
        check(32'hB1B1B1B1, "WORD_1");

        // Word 2 at byte address 8
        addr = 32'd8;
        check(32'hC2C2C2C2, "WORD_2");

        // Word 3 at byte address 12
        addr = 32'd12;
        check(32'hD3D3D3D3, "WORD_3");

        // Last word: mem[255] is at byte address 255*4 = 1020
        addr = 32'd1020;
        check(32'hFEFEFEFE, "LAST_WORD");

        // Byte offsets within a word (1, 2, 3) all alias to the same
        // word as offset 0, since addr[9:2] drops those low 2 bits.
        // pc.v never actually produces these addresses (it only steps
        // by 4), but this shows why word alignment matters.
        addr = 32'd1;
        check(32'hA0A0A0A0, "UNALIGNED_ADDR_1");

        addr = 32'd3;
        check(32'hA0A0A0A0, "UNALIGNED_ADDR_3");

        $display("Testbench complete.");
        $finish;
    end

endmodule
