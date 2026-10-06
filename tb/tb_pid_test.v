// tb_pid_test.v
// Runs sw/pid_test.c against cpu_pipeline.v (BRAM-backed - this is
// pure software verification of the Q16.16 math and the anti-windup
// guard, unrelated to the memory hierarchy work in Phase 3, so there's
// no need to route it through flash/cache).
//
// Checks q16_mul's basic correctness, then confirms anti-windup
// actually changes behavior: the guarded PID's integral should stay
// much smaller than the naive PID's after the same saturating run,
// and the guarded PID's peak (overshoot) should be lower too.
//
// Run with:
//   iverilog -o sim_pid rtl/alu.v rtl/regfile.v rtl/control.v rtl/pc.v rtl/imem.v rtl/dmem.v rtl/cpu_pipeline.v tb/tb_pid_test.v
//   vvp sim_pid

`timescale 1ns/1ps

module tb_pid_test;

    reg clk;
    reg reset;
    integer i;

    cpu_pipeline uut (
        .clk(clk),
        .reset(reset)
    );

    always #5 clk = ~clk;

    function [31:0] peek_result(input [31:0] offset);
        peek_result = {uut.dmem_inst.peek(offset+3), uut.dmem_inst.peek(offset+2),
                        uut.dmem_inst.peek(offset+1), uut.dmem_inst.peek(offset+0)};
    endfunction

    initial begin
        clk   = 1'b0;
        reset = 1'b1;

        $readmemh("sw/pid_test.hex", uut.imem_inst.mem);

        @(negedge clk);
        @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        // 40 PID steps, each step a handful of multiplies/branches -
        // BRAM-backed (1-cycle fetch), so this is cheap. Budget
        // generously anyway.
        for (i = 0; i < 200000; i = i + 1) begin
            @(posedge clk); @(negedge clk);
        end

        if (peek_result(32'h300) !== 32'd245760)
            $display("FAIL [MUL_POSITIVE]: got=%0d expected=245760 (1.5*2.5=3.75)", $signed(peek_result(32'h300)));
        else
            $display("PASS [MUL_POSITIVE]: 1.5*2.5 = 3.75 (raw 245760)");

        if (peek_result(32'h304) !== -32'd393216)
            $display("FAIL [MUL_NEGATIVE]: got=%0d expected=-393216 (-2.0*3.0=-6.0)", $signed(peek_result(32'h304)));
        else
            $display("PASS [MUL_NEGATIVE]: -2.0*3.0 = -6.0 (raw -393216)");

        $display("guarded integral=%0d, naive integral=%0d",
                  $signed(peek_result(32'h308)), $signed(peek_result(32'h30c)));
        $display("guarded peak=%0d (%0d.x), naive peak=%0d (%0d.x)",
                  $signed(peek_result(32'h310)), $signed(peek_result(32'h310)) >>> 16,
                  $signed(peek_result(32'h314)), $signed(peek_result(32'h314)) >>> 16);

        if ($signed(peek_result(32'h30c)) <= $signed(peek_result(32'h308)))
            $display("FAIL [WINDUP_OBSERVED]: naive integral (%0d) is not greater than guarded (%0d) - anti-windup test isn't showing a difference",
                      $signed(peek_result(32'h30c)), $signed(peek_result(32'h308)));
        else
            $display("PASS [WINDUP_OBSERVED]: naive integral (%0d) far exceeds guarded (%0d) - anti-windup guard is doing real work",
                      $signed(peek_result(32'h30c)), $signed(peek_result(32'h308)));

        if ($signed(peek_result(32'h314)) <= $signed(peek_result(32'h310)))
            $display("FAIL [OVERSHOOT_REDUCED]: naive peak (%0d) is not greater than guarded peak (%0d)",
                      $signed(peek_result(32'h314)), $signed(peek_result(32'h310)));
        else
            $display("PASS [OVERSHOOT_REDUCED]: naive overshoots further (peak %0d) than guarded (peak %0d)",
                      $signed(peek_result(32'h314)), $signed(peek_result(32'h310)));

        $display("Testbench complete.");
        $finish;
    end

endmodule
