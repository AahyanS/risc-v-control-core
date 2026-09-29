// tb_compliance_pipeline.v
// Same generic compliance-test runner as tb_compliance.v, but against
// cpu_pipeline.v (the pipelined core) instead of cpu.v (single-cycle).
// Identical logic throughout - cpu_pipeline.v uses the same submodule
// instance names (imem_inst, dmem_inst) as cpu.v, so the hierarchical
// references and the RESULT_ADDR polling scheme carry over unchanged.
// This is exactly the check PROJECT.md's Phase 2 calls for: the
// official compliance suite re-run against the pipelined core, not
// just the single-cycle one - forwarding, stalls, flushes, and the
// branch predictor all have to hold up under the same official tests.
//
// Run with:
//   iverilog -o sim_compliance_pipeline alu.v regfile.v control.v pc.v imem.v dmem.v cpu_pipeline.v tb_compliance_pipeline.v
//   vvp sim_compliance_pipeline +HEXFILE=build_compliance/add.hex +TESTNAME=add

`timescale 1ns/1ps

module tb_compliance_pipeline;

    reg clk;
    reg reset;
    integer i;
    reg [8*256-1:0] hexfile;
    reg [8*64-1:0]  testname;
    reg [31:0] result;
    integer cycle_count;
    parameter TIMEOUT_CYCLES = 5000;

    cpu_pipeline uut (
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

        for (i = 0; i < 8192; i = i + 1)
            uut.dmem_inst.poke(i, 8'd0);

        $readmemh(hexfile, uut.imem_inst.mem);
        uut.dmem_inst.load_hex(hexfile);

        @(negedge clk);
        @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

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
