// tb_cpu_pipeline_cache_locked_hazards.v
// Regression test for cpu_pipeline_cache_locked.v's forwarding paths
// and load-use stall, using sw/pipeline_hazard_test.s - same program
// and checks as the earlier hazards testbenches. No branches, no lock
// commands in this program - purely confirming the MMIO lock decode
// added in the MEM stage doesn't disturb ordinary forwarding/load-use
// timing.
//
// Run with:
//   iverilog -o sim_cache_locked_hazards rtl/alu.v rtl/regfile.v rtl/control.v rtl/pc.v rtl/dmem.v rtl/spi_flash_ctrl.v tb/spi_flash_model.v rtl/icache.v rtl/cpu_pipeline_cache_locked.v tb/tb_cpu_pipeline_cache_locked_hazards.v
//   vvp sim_cache_locked_hazards

`timescale 1ns/1ps

module tb_cpu_pipeline_cache_locked_hazards;

    reg clk;
    reg reset;
    integer i;

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

        for (i = 0; i < 8192; i = i + 1)
            uut.dmem_inst.poke(i, 8'd0);

        $readmemh("sw/pipeline_hazard_test.hex", flash.mem);

        @(negedge clk);
        @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        for (i = 0; i < 3500; i = i + 1) begin
            @(posedge clk); @(negedge clk);
        end

        check_reg(5'd1,  32'd5,  "X1_BASE");
        check_reg(5'd2,  32'd10, "X2_0GAP_ALU_FORWARD");
        check_reg(5'd3,  32'd7,  "X3_BASE");
        check_reg(5'd4,  32'd14, "X4_1GAP_ALU_FORWARD");
        check_reg(5'd7,  32'd300, "X7_ADDR_BASE");
        check_reg(5'd10, 32'd42, "X10_STORE_VALUE");
        check_reg(5'd8,  32'd42, "X8_LOAD_BACK");
        check_reg(5'd9,  32'd42, "X9_LOAD_USE_STALL");
        check_reg(5'd13, 32'd99, "X13_STORE_VALUE_2");
        check_reg(5'd11, 32'd99, "X11_LOAD_BACK_2");
        check_reg(5'd12, 32'd99, "X12_1GAP_LOAD_FORWARD");

        $display("Testbench complete.");
        $finish;
    end

endmodule
