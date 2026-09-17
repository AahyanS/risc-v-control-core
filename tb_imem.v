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

    // Loads one 32-bit word into 4 consecutive bytes, little-endian -
    // this is what a real $readmemh-loaded hex file effectively does,
    // just written by hand here instead of read from a file.
    task load_word(input [31:0] byte_addr, input [31:0] word);
        begin
            uut.mem[byte_addr]   = word[7:0];
            uut.mem[byte_addr+1] = word[15:8];
            uut.mem[byte_addr+2] = word[23:16];
            uut.mem[byte_addr+3] = word[31:24];
        end
    endtask

    initial begin
        // No RISC-V toolchain loader wired up yet in this testbench
        // (that's the next step), so load hand-picked words byte by
        // byte - this stands in for "compiling a program into memory."
        load_word(32'd0,    32'hA0A0A0A0);
        load_word(32'd4,    32'hB1B1B1B1);
        load_word(32'd8,    32'hC2C2C2C2);
        load_word(32'd12,   32'hD3D3D3D3);
        load_word(32'd1020, 32'hFEFEFEFE); // last valid word, top of the 1KB array

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

        // Last word: byte address 1020..1023, the top of the 1KB array
        addr = 32'd1020;
        check(32'hFEFEFEFE, "LAST_WORD");

        // Verify little-endian byte placement directly: the low byte
        // of 0xA0A0A0A0 (0xA0, same in this case since all bytes are
        // equal) should sit at the lowest address. Use a
        // distinguishable word to make this a meaningful check.
        load_word(32'd100, 32'h11223344);
        if (uut.mem[100] !== 8'h44 || uut.mem[101] !== 8'h33 ||
            uut.mem[102] !== 8'h22 || uut.mem[103] !== 8'h11)
            $display("FAIL [LITTLE_ENDIAN_BYTES]: mem[100..103] got=%0h %0h %0h %0h",
                      uut.mem[100], uut.mem[101], uut.mem[102], uut.mem[103]);
        else
            $display("PASS [LITTLE_ENDIAN_BYTES]: mem[100..103] = 44,33,22,11");

        addr = 32'd100;
        check(32'h11223344, "LITTLE_ENDIAN_READBACK");

        // A genuinely unaligned address now reads a real, different
        // 4-byte window (bytes 101-104), not an alias of the aligned
        // word the way the old word-array design's addr[9:2] truncation
        // used to behave. pc.v never actually produces unaligned
        // addresses (it only steps by 4), so this is just documenting
        // real byte-addressable memory behavior, not something the CPU
        // relies on.
        load_word(32'd104, 32'h55667788);
        addr = 32'd101;
        // bytes 101,102,103,104 = 0x33,0x22,0x11,0x88
        check(32'h88112233, "UNALIGNED_ADDR_REAL_WINDOW");

        $display("Testbench complete.");
        $finish;
    end

endmodule
