// tb_pid_mac_test.v
// Runs sw/pid_mac_test.c on cpu_pipeline_cache_locked (the core with
// the MAC instruction): pid_step() in C vs. the PID_MAC macro the
// control-loop interrupt handler uses, same inputs, every step
// compared. Requires zero mismatches AND that every branch of the
// saturation/anti-windup logic was actually taken.
//
// Build + run:
//   cd sw && riscv-none-elf-gcc -march=rv32i -mabi=ilp32 -O1 -nostdlib -nostartfiles \
//     -Ttext=0x0 -o pid_mac_test.elf crt0.s pid.c pid_mac.s pid_mac_test.c -lgcc && \
//     riscv-none-elf-objcopy -O verilog pid_mac_test.elf pid_mac_test.hex && cd ..
//   iverilog -o sim_pid_mac_test rtl/alu.v rtl/regfile.v rtl/control.v rtl/pc.v rtl/dmem.v rtl/spi_flash_ctrl.v \
//     tb/spi_flash_model.v rtl/icache.v rtl/quad_decoder.v rtl/pwm.v rtl/timer.v rtl/uart_tx.v \
//     rtl/cpu_pipeline_cache_locked.v tb/tb_pid_mac_test.v
//   vvp sim_pid_mac_test

`timescale 1ns/1ps

module tb_pid_mac_test;

    reg clk = 0;
    reg reset = 1;
    integer i;

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

    integer fails = 0;

    task check(input cond, input [8*48-1:0] msg);
        begin
            if (cond) $display("PASS [%0s]", msg);
            else begin $display("FAIL [%0s]", msg); fails = fails + 1; end
        end
    endtask

    initial begin
        $readmemh("sw/pid_mac_test.hex", flash.mem);
        repeat (3) @(negedge clk);
        reset = 0;

        // Software 64-bit multiplies fetched from flash are slow; poll
        // for the done marker rather than guessing a cycle budget.
        for (i = 0; i < 40000000 && peek_result(32'h31C) !== 32'h600D; i = i + 1)
            @(negedge clk);
        $display("finished after %0d cycles", i);

        $display("steps=%0d mismatches=%0d | in range=%0d, clamped high=%0d (kept %0d), clamped low=%0d (kept %0d)",
                 peek_result(32'h300), peek_result(32'h304), peek_result(32'h308),
                 peek_result(32'h30C), peek_result(32'h314),
                 peek_result(32'h310), peek_result(32'h318));

        check(peek_result(32'h31C) === 32'h600D, "PROGRAM_FINISHED");
        check(peek_result(32'h300) == 100,        "ALL_100_STEPS_RAN");
        check(peek_result(32'h304) == 0,          "MAC_PID_MATCHES_C_PID_EVERY_STEP");
        check(peek_result(32'h308) > 0,           "COVERED_IN_RANGE");
        check(peek_result(32'h30C) > peek_result(32'h314), "COVERED_HIGH_DISCARD");
        check(peek_result(32'h314) > 0,           "COVERED_HIGH_KEEP");
        check(peek_result(32'h310) > peek_result(32'h318), "COVERED_LOW_DISCARD");
        check(peek_result(32'h318) > 0,           "COVERED_LOW_KEEP");

        if (fails == 0) $display("ALL CHECKS PASSED");
        else            $display("%0d CHECK(S) FAILED", fails);
        $finish;
    end

endmodule
