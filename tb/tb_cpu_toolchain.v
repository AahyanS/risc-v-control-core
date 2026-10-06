// tb_cpu_toolchain.v
// End-to-end test: a program compiled by the real RISC-V GNU toolchain
// (not hand-assembled), loaded via $readmemh, run on the core.
//
// sw/sum_loop.c computes 1+2+3+4+5 and stores the result (15) to a
// fixed address (0x200) in data memory. The program ends in an
// infinite self-loop, so this testbench just runs for a generous
// number of cycles and checks the final result, rather than hand-
// counting the exact cycle the store happens on.
//
// Run with:
//   iverilog -o sim_cpu_toolchain rtl/alu.v rtl/regfile.v rtl/control.v rtl/pc.v rtl/imem.v rtl/dmem.v rtl/cpu.v tb/tb_cpu_toolchain.v
//   vvp sim_cpu_toolchain

`timescale 1ns/1ps

module tb_cpu_toolchain;

    reg clk;
    reg reset;

    cpu uut (
        .clk(clk),
        .reset(reset)
    );

    always #5 clk = ~clk;

    initial begin
        clk   = 1'b0;
        reset = 1'b1;

        // Load the real compiled program directly into instruction
        // memory - this is the payoff of imem.v being byte-addressable
        // now: $readmemh's byte-per-line format from objcopy -O verilog
        // loads straight in, no repacking needed.
        $readmemh("sw/sum_loop.hex", uut.imem_inst.mem);

        // Hold reset through one clock edge to establish pc = 0
        @(negedge clk);
        @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        // Run for a generous number of cycles - the program finishes
        // (per a hand-trace of the compiled loop) by cycle 68, then
        // spins forever, so 200 cycles leaves ample margin
        repeat (200) begin
            @(posedge clk); @(negedge clk);
        end

        // sum_loop.c stores the result (15) as a little-endian word at
        // byte address 0x200 (512)
        #1;
        if (uut.dmem_inst.peek(512) !== 8'd15 || uut.dmem_inst.peek(513) !== 8'd0 ||
            uut.dmem_inst.peek(514) !== 8'd0  || uut.dmem_inst.peek(515) !== 8'd0)
            $display("FAIL [COMPILED_SUM_RESULT]: mem[512..515] got=%0d %0d %0d %0d expected=15,0,0,0",
                      uut.dmem_inst.peek(512), uut.dmem_inst.peek(513),
                      uut.dmem_inst.peek(514), uut.dmem_inst.peek(515));
        else
            $display("PASS [COMPILED_SUM_RESULT]: mem[512..515] = 15,0,0,0 (1+2+3+4+5=15)");

        $display("Testbench complete.");
        $finish;
    end

endmodule
