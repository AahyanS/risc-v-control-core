// tb_cpu_pipeline_xip_predictor.v
// Verifies the branch predictor still learns correctly when fetching
// from real (simulated) flash instead of BRAM, using
// sw/pipeline_predictor_test.s - same program and checks as
// tb_cpu_pipeline_predictor.v. The flush count itself should be
// unchanged (2, not 6) - ex_flush is driven purely by EX comparing
// predicted vs. actual outcome, independent of how IF happens to be
// fetching; what changes is only how much a misprediction now costs
// in wall-clock cycles (one extra ~130-cycle fetch, wasted and
// discarded, per misprediction) - not measured here, but the
// underlying misprediction count is the thing that actually matters
// architecturally.
//
// Run with:
//   iverilog -o sim_xip_predictor alu.v regfile.v control.v pc.v dmem.v spi_flash_ctrl.v spi_flash_model.v cpu_pipeline_xip.v tb_cpu_pipeline_xip_predictor.v
//   vvp sim_xip_predictor

`timescale 1ns/1ps

module tb_cpu_pipeline_xip_predictor;

    reg clk;
    reg reset;
    integer i;
    integer flush_count;

    wire sck, cs_n, mosi, miso;

    cpu_pipeline_xip uut (
        .clk(clk),
        .reset(reset),
        .sck(sck), .cs_n(cs_n), .mosi(mosi), .miso(miso)
    );

    spi_flash_model flash (
        .sck(sck), .cs_n(cs_n), .mosi(mosi), .miso(miso)
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

        $readmemh("sw/pipeline_predictor_test.hex", flash.mem);

        @(negedge clk);
        @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        // ~26 real instructions + 2 misprediction-driven wasted
        // fetches, ~130 cycles each.
        for (i = 0; i < 5000; i = i + 1) begin
            @(posedge clk);
            if (uut.ex_flush) flush_count = flush_count + 1;
            @(negedge clk);
        end

        check_reg(5'd1, 32'd28,  "X1_SUM");
        check_reg(5'd2, 32'd8,   "X2_FINAL_I");
        check_reg(5'd4, 32'd999, "X4_AFTER_LOOP");

        if (uut.bht[5] !== 2'b10)
            $display("FAIL [BHT_FINAL_STATE]: bht[5] got=%0b expected=10", uut.bht[5]);
        else
            $display("PASS [BHT_FINAL_STATE]: bht[5] = 10 (weakly taken)");

        if (flush_count !== 2)
            $display("FAIL [FLUSH_COUNT]: got=%0d expected=2", flush_count);
        else
            $display("PASS [FLUSH_COUNT]: exactly 2 flushes for 7 branch executions (vs. 6 under always-predict-not-taken)");

        $display("Testbench complete.");
        $finish;
    end

endmodule
