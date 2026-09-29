// tb_predictor_measurement.v
// Measures the existing 2-bit saturating-counter predictor's real
// accuracy on a representative control-loop shape (one tight backward
// branch, 1000 iterations - sw/predictor_measurement.s), rather than
// assuming the "~97-99%" PROJECT.md predicts. Counts every branch
// resolution (id_ex_branch asserted in EX) and every misprediction
// (ex_branch_mispredicted) to compute the real hit rate.
//
// Expected, worked out by hand from the 2-bit counter's own state
// machine (00/01=predict not-taken, 10/11=predict taken, starts at
// 01): iteration 1 mispredicts (cold start - predictor says
// not-taken, branch is actually taken), iteration 2 is correct and
// saturates the counter to 11 (strongly taken), iterations 3-999 are
// all correct (997 in a row), and the final iteration (the loop exit,
// not-taken) mispredicts - unavoidably, since nothing about a 2-bit
// counter can know in advance which iteration is the last one. That's
// 2 mispredictions out of 1000 - the mathematical ceiling for ANY
// predictor that doesn't know the loop bound ahead of time, which is
// the actual answer to "would a fancier predictor (gshare) help here":
// no, not for this shape, because there's nothing left to improve on.
//
// Run with:
//   iverilog -o sim_predictor_measure alu.v regfile.v control.v pc.v dmem.v spi_flash_ctrl.v spi_flash_model.v icache.v quad_decoder.v pwm.v timer.v cpu_pipeline_cache_locked.v tb_predictor_measurement.v
//   vvp sim_predictor_measure

`timescale 1ns/1ps

module tb_predictor_measurement;

    reg clk;
    reg reset;
    integer i;
    integer total_branches;
    integer mispredictions;

    wire sck, cs_n, mosi, miso;

    cpu_pipeline_cache_locked uut (
        .clk(clk),
        .reset(reset),
        .sck(sck), .cs_n(cs_n), .mosi(mosi), .miso(miso),
        .enc_a(1'b0), .enc_b(1'b0),
        .pwm_out()
    );

    spi_flash_model flash (
        .sck(sck), .cs_n(cs_n), .mosi(mosi), .miso(miso)
    );

    always #5 clk = ~clk;

    function [31:0] peek_result(input [31:0] offset);
        peek_result = {uut.dmem_inst.peek(offset+3), uut.dmem_inst.peek(offset+2),
                        uut.dmem_inst.peek(offset+1), uut.dmem_inst.peek(offset+0)};
    endfunction

    initial begin
        clk   = 1'b0;
        reset = 1'b1;
        total_branches = 0;
        mispredictions = 0;

        $readmemh("sw/predictor_measurement.hex", flash.mem);

        @(negedge clk);
        @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        // 1000 iterations, tiny 2-instruction loop body, mostly cache
        // hits after warm-up - budget generously anyway.
        for (i = 0; i < 20000; i = i + 1) begin
            @(posedge clk);
            if (uut.id_ex_branch) begin
                total_branches = total_branches + 1;
                if (uut.ex_branch_mispredicted)
                    mispredictions = mispredictions + 1;
            end
            @(negedge clk);
        end

        if (peek_result(32'h300) !== 32'd1000)
            $display("FAIL [PROGRAM_COMPLETED]: iteration count=%0d expected=1000 - didn't finish in the cycle budget",
                      peek_result(32'h300));
        else
            $display("PASS [PROGRAM_COMPLETED]: all 1000 iterations ran");

        $display("Total branch resolutions: %0d", total_branches);
        $display("Mispredictions: %0d", mispredictions);
        $display("Accuracy: %0d.%01d%%",
                  (total_branches - mispredictions) * 100 / total_branches,
                  ((total_branches - mispredictions) * 1000 / total_branches) % 10);

        if (mispredictions !== 2)
            $display("FAIL [MATCHES_THEORETICAL_CEILING]: mispredictions=%0d expected=2 (1 cold-start + 1 unavoidable loop-exit)",
                      mispredictions);
        else
            $display("PASS [MATCHES_THEORETICAL_CEILING]: exactly 2 mispredictions (cold-start + loop-exit) - the 2-bit predictor is already at the ceiling for this shape");

        $display("Testbench complete.");
        $finish;
    end

endmodule
