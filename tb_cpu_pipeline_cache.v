// tb_cpu_pipeline_cache.v
// Regression test for cpu_pipeline_cache.v: reuses sw/pipeline_test.s
// (same program/checks as tb_cpu_pipeline.v and tb_cpu_pipeline_xip.v)
// to prove the cache doesn't break architectural correctness - just
// confirms results still come out right when IF goes through icache.v
// instead of talking to flash directly.
//
// Run with:
//   iverilog -o sim_cache alu.v regfile.v control.v pc.v dmem.v spi_flash_ctrl.v spi_flash_model.v icache.v cpu_pipeline_cache.v tb_cpu_pipeline_cache.v
//   vvp sim_cache

`timescale 1ns/1ps

module tb_cpu_pipeline_cache;

    reg clk;
    reg reset;
    integer i;

    wire sck, cs_n, mosi, miso;

    cpu_pipeline_cache uut (
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

    task check_reg_not(input [4:0] reg_num, input [31:0] bad_val,
                        input [63:0] opname);
        begin
            if (peek_reg(reg_num) === bad_val)
                $display("FAIL [%0s]: x%0d got=%0h - squashed write escaped!",
                          opname, reg_num, peek_reg(reg_num));
            else
                $display("PASS [%0s]: x%0d = %0h (not the skipped value %0h)",
                          opname, reg_num, peek_reg(reg_num), bad_val);
        end
    endtask

    initial begin
        clk   = 1'b0;
        reset = 1'b1;

        $readmemh("sw/pipeline_test.hex", flash.mem);

        @(negedge clk);
        @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        // Same budget as tb_cpu_pipeline_xip.v - a cache miss costs
        // even more than a plain flash read (4 sub-fetches instead of
        // 1), so keep the generous cycle count.
        for (i = 0; i < 4000; i = i + 1) begin
            @(posedge clk); @(negedge clk);
        end

        check_reg(5'd1,  32'd5,   "X1_BASE");
        check_reg(5'd5,  32'd15,  "X5_HAZARD_FREE_READ");
        check_reg_not(5'd7, 32'd999, "X7_SKIPPED_BY_TAKEN_BRANCH");
        check_reg(5'd8,  32'd111, "X8_TAKEN_BRANCH_TARGET");
        check_reg(5'd9,  32'd222, "X9_NOT_TAKEN_BRANCH_FALLTHROUGH");
        check_reg(5'd10, 32'd333, "X10_ALWAYS_RUNS");
        check_reg(5'd11, 32'd84,  "X11_JAL_LINK_ADDR");
        check_reg_not(5'd12, 32'd444, "X12_SKIPPED_BY_JAL");
        check_reg(5'd13, 32'd555, "X13_JAL_TARGET");

        $display("Testbench complete.");
        $finish;
    end

endmodule
