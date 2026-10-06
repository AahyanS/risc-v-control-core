// tb_compliance.v
// Generic runner for RISC-V compliance test hex files.
//
// Compiled once; which test to run is chosen at simulation runtime via
// a +HEXFILE=path plusarg, so the whole compliance/isa/rv32ui/*.S
// suite can be run without recompiling this testbench per test.
//
// The compiled test image is loaded into BOTH imem and dmem: pure
// ALU/branch/jump tests only need imem, but the memory-access tests
// (lw/sw/lb/etc.) embed literal test data right after their code in
// one linked image, and since this core has physically separate
// instruction and data memories (a Harvard split), that data has to
// be mirrored into dmem for a real load/store instruction to find it
// at the address the linker assumed. This is a testbench-level
// workaround, not a CPU change - see docs/DESIGN_LOG.md for the full
// reasoning.
//
// Run with:
//   iverilog -o sim_compliance rtl/alu.v rtl/regfile.v rtl/control.v rtl/pc.v rtl/imem.v rtl/dmem.v rtl/cpu.v tb/tb_compliance.v
//   vvp sim_compliance +HEXFILE=build_compliance/add.hex +TESTNAME=add

`timescale 1ns/1ps

module tb_compliance;

    reg clk;
    reg reset;
    integer i;
    reg [8*256-1:0] hexfile;
    reg [8*64-1:0]  testname;
    reg [31:0] result;
    integer cycle_count;
    parameter TIMEOUT_CYCLES = 5000;

    cpu uut (
        .clk(clk),
        .reset(reset)
    );

    always #5 clk = ~clk;

    initial begin
        clk   = 1'b0;
        reset = 1'b1;

        if (!$value$plusargs("HEXFILE=%s", hexfile)) begin
            $display("FAIL [SETUP]: no +HEXFILE=<path> given");
            $finish;
        end
        if (!$value$plusargs("TESTNAME=%s", testname))
            testname = "unknown";

        // Zero-fill dmem first: objcopy doesn't emit bytes for .bss
        // (zero-initialized data isn't stored explicitly), so without
        // this, any .bss region would read back as simulation's
        // default unknown ('x') instead of the 0 a real system
        // guarantees at startup.
        for (i = 0; i < 8192; i = i + 1)
            uut.dmem_inst.poke(i, 8'd0);

        $readmemh(hexfile, uut.imem_inst.mem);
        uut.dmem_inst.load_hex(hexfile);

        @(negedge clk);
        @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        // Poll the result address (0x1FFC, top word of dmem) each cycle
        // instead of hand-counting cycles - test lengths vary, and
        // every test ends in an infinite self-loop once it writes its
        // result, so polling with a generous timeout is both simpler
        // and more robust than computing an exact cycle count per test.
        result = 32'd0;
        cycle_count = 0;
        while (result == 32'd0 && cycle_count < TIMEOUT_CYCLES) begin
            @(posedge clk); @(negedge clk);
            result = {uut.dmem_inst.peek(16'h1FFF), uut.dmem_inst.peek(16'h1FFE),
                      uut.dmem_inst.peek(16'h1FFD), uut.dmem_inst.peek(16'h1FFC)};
            cycle_count = cycle_count + 1;
        end

        if (result == 32'd0)
            $display("TIMEOUT [%0s]: no result after %0d cycles", testname, TIMEOUT_CYCLES);
        else if (result == 32'd1)
            $display("PASS [%0s]", testname);
        else
            $display("FAIL [%0s]: sub-test %0d failed (result=0x%0h)",
                      testname, result >> 1, result);

        $finish;
    end

endmodule
