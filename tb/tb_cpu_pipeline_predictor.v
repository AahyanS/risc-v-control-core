// tb_cpu_pipeline_predictor.v
// Verifies the branch predictor actually learns, using
// sw/pipeline_predictor_test.s: a loop with 7 executions of the same
// backward branch (6 taken, then 1 not-taken to exit). Checks not
// just architectural correctness, but the predictor's own state
// (final bht entry) and the actual flush count - proving prediction
// reduces flushes rather than just "the core still works with one
// installed."
//
// Run with:
//   iverilog -o sim_pipeline_predictor rtl/alu.v rtl/regfile.v rtl/control.v rtl/pc.v rtl/imem.v rtl/dmem.v rtl/cpu_pipeline.v tb/tb_cpu_pipeline_predictor.v
//   vvp sim_pipeline_predictor

`timescale 1ns/1ps

module tb_cpu_pipeline_predictor;

    reg clk;
    reg reset;
    integer i;
    integer flush_count;

    cpu_pipeline uut (
        .clk(clk),
        .reset(reset)
    );

    always #5 clk = ~clk;

    function [31:0] peek_reg(input [4:0] reg_num);
        peek_reg = (reg_num == 5'd0) ? 32'd0 : uut.regfile_inst.regs[reg_num];
    endfunction

    task check_reg(input [4:0] reg_num, input [31:0] exp_val,
                    input [63:0] opname);
        begin
            if (peek_reg(reg_num) !== exp_val)
                $display("FAIL [%0s]: x%0d got=%0h expected=%0h",
                          opname, reg_num, peek_reg(reg_num), exp_val);
            else
                $display("PASS [%0s]: x%0d = %0h",
                          opname, reg_num, peek_reg(reg_num));
        end
    endtask

    initial begin
        clk   = 1'b0;
        reset = 1'b1;
        flush_count = 0;

        $readmemh("sw/pipeline_predictor_test.hex", uut.imem_inst.mem);

        @(negedge clk);
        @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        // Count every cycle ex_flush fires while the program runs
        for (i = 0; i < 60; i = i + 1) begin
            @(posedge clk);
            if (uut.ex_flush) flush_count = flush_count + 1;
            @(negedge clk);
        end

        // Architectural correctness: sum of 1..7 = 28
        check_reg(5'd1, 32'd28,  "X1_SUM");
        check_reg(5'd2, 32'd8,   "X2_FINAL_I");
        check_reg(5'd4, 32'd999, "X4_AFTER_LOOP");

        // The predictor's own learned state: the branch is at byte
        // address 0x14 (20), so its bht index is 20>>2 = 5. Expected
        // final state 2'b10 (weakly taken) - trained up by 5
        // consecutive taken outcomes (exec2-6, each incrementing
        // from the exec1 mispredict's 10), then knocked back down
        // once by the final not-taken exit (exec7: 11 -> 10).
        if (uut.bht[5] !== 2'b10)
            $display("FAIL [BHT_FINAL_STATE]: bht[5] got=%0b expected=10", uut.bht[5]);
        else
            $display("PASS [BHT_FINAL_STATE]: bht[5] = 10 (weakly taken)");

        // The actual point: only 2 flushes for 7 branch executions,
        // not 6 (what "always predict not-taken" would have cost) or
        // 7 (what no prediction/always-stall would cost).
        if (flush_count !== 2)
            $display("FAIL [FLUSH_COUNT]: got=%0d expected=2", flush_count);
        else
            $display("PASS [FLUSH_COUNT]: exactly 2 flushes for 7 branch executions (vs. 6 under always-predict-not-taken)");

        $display("Testbench complete.");
        $finish;
    end

endmodule
