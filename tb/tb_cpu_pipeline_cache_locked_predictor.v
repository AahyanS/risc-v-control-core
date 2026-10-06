// tb_cpu_pipeline_cache_locked_predictor.v
// Regression test confirming the branch predictor still learns
// correctly with cache-line locking support added, using
// sw/pipeline_predictor_test.s - same program and checks as the
// earlier predictor testbenches. No lock commands in this program -
// confirms the MMIO lock decode added in MEM doesn't disturb
// misprediction counting (still exactly 2 flushes).
//
// Run with:
//   iverilog -o sim_cache_locked_predictor rtl/alu.v rtl/regfile.v rtl/control.v rtl/pc.v rtl/dmem.v rtl/spi_flash_ctrl.v tb/spi_flash_model.v rtl/icache.v rtl/cpu_pipeline_cache_locked.v tb/tb_cpu_pipeline_cache_locked_predictor.v
//   vvp sim_cache_locked_predictor

`timescale 1ns/1ps

module tb_cpu_pipeline_cache_locked_predictor;

    reg clk;
    reg reset;
    integer i;
    integer flush_count;

    wire sck, cs_n, mosi, miso;

    cpu_pipeline_cache_locked uut (
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
            $display("PASS [FLUSH_COUNT]: exactly 2 flushes for 7 branch executions - unchanged by the cache");

        $display("Testbench complete.");
        $finish;
    end

endmodule
