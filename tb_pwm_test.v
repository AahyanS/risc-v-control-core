// tb_pwm_test.v
// End-to-end test of the PWM peripheral wired into
// cpu_pipeline_cache_locked.v: runs sw/pwm_test.s (sets duty_cycle=256
// via a store to 0xFFFFFF18, reads it back), then observes the
// CPU's actual physical pwm_out pin over one full 1024-cycle period
// and confirms the measured high-time matches what software
// programmed - proving the full path, not just that the register
// holds the value.
//
// Run with:
//   iverilog -o sim_pwm_test alu.v regfile.v control.v pc.v dmem.v spi_flash_ctrl.v spi_flash_model.v icache.v quad_decoder.v pwm.v cpu_pipeline_cache_locked.v tb_pwm_test.v
//   vvp sim_pwm_test

`timescale 1ns/1ps

module tb_pwm_test;

    reg clk;
    reg reset;
    integer i, high_count;

    wire sck, cs_n, mosi, miso;
    wire pwm_out;

    cpu_pipeline_cache_locked uut (
        .clk(clk),
        .reset(reset),
        .sck(sck), .cs_n(cs_n), .mosi(mosi), .miso(miso),
        .enc_a(1'b0), .enc_b(1'b0),
        .pwm_out(pwm_out)
    );

    spi_flash_model flash (
        .sck(sck), .cs_n(cs_n), .mosi(mosi), .miso(miso)
    );

    always #5 clk = ~clk;

    function [31:0] peek_result(input [31:0] offset);
        peek_result = {uut.dmem_inst.mem[offset+3], uut.dmem_inst.mem[offset+2],
                        uut.dmem_inst.mem[offset+1], uut.dmem_inst.mem[offset+0]};
    endfunction

    initial begin
        clk   = 1'b0;
        reset = 1'b1;

        $readmemh("sw/pwm_test.hex", flash.mem);

        @(negedge clk);
        @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        // Run the program - XIP fetch for ~7 instructions, generous budget.
        for (i = 0; i < 3000; i = i + 1) begin
            @(posedge clk); @(negedge clk);
        end

        if (peek_result(32'h200) !== 32'd256)
            $display("FAIL [DUTY_CYCLE_READBACK]: got=%0d expected=256", peek_result(32'h200));
        else
            $display("PASS [DUTY_CYCLE_READBACK]: software read back duty_cycle=256 via MMIO");

        // Observe the actual pwm_out pin over one full 1024-cycle
        // period - the program has long since finished, spinning, so
        // the PWM generator is running freely off the value software
        // programmed.
        high_count = 0;
        for (i = 0; i < 1024; i = i + 1) begin
            @(posedge clk);
            if (pwm_out) high_count = high_count + 1;
            @(negedge clk);
        end

        $display("Measured pwm_out high for %0d/1024 cycles (expected 256)", high_count);
        if (high_count !== 256)
            $display("FAIL [PWM_WAVEFORM_MATCHES_SOFTWARE]: measured=%0d expected=256", high_count);
        else
            $display("PASS [PWM_WAVEFORM_MATCHES_SOFTWARE]: physical pwm_out pin matches the software-programmed duty cycle exactly");

        $display("Testbench complete.");
        $finish;
    end

endmodule
