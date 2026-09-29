// tb_basys3_top.v
// Simulates the complete board design - basys3_top.v with its MMCM,
// reset sequencing, STARTUPE2 flash path (including the three
// swallowed clocks after configuration), the CPU, and the motor
// safety chain - running the real hardware test programs from a flash
// model holding them at FLASH_BASE (3 MB), exactly where the hardware
// flash image puts them.
//
// Default: runs sw/hw_hello (heartbeat + live encoder position on the
// LEDs) and turns a simulated encoder forward then backward.
// With -DMOTOR_TEST: runs sw/hw_motor_test, checks the DHB1 enable is
// actually driven in both directions with the arm switch up, that
// direction never changes at the pins while enable is high, and that
// enable never goes high at all with the arm switch down.
// With -DCACHE_LOCK: runs sw/hw_cache_lock (the locked-vs-unlocked
// interference experiment), decodes the UART pin back into text the
// way the PC will, and checks the printed numbers against the CPU's
// own registers and against the core-level simulation results.
// With -DNO_BOOT_DUMMY: builds the wrapper with zero dummy boot clocks
// - expected to FAIL, confirming the stub really models the lost
// clocks and the wrapper's workaround is what makes the boot work.
//
// Run from the repository root:
//   bash fpga/sim/run_board_sim.sh

`timescale 1ns/1ps

module tb_basys3_top;

`ifdef NO_BOOT_DUMMY
    localparam DUMMY = 0;
`else
    localparam DUMMY = 8;
`endif

    reg  clk = 0;
    reg  btnC = 1;
    reg  sw15 = 0;
    reg  enc_a = 0, enc_b = 0;

    wire [15:0] led;
    wire dhb1_en1, dhb1_dir1, dhb1_en2, dhb1_dir2;
    wire qspi_cs_n, qspi_dq0, qspi_dq1, qspi_dq2, qspi_dq3;

    basys3_top #(
        .FLASH_BASE      (24'h300000),
        .MOTOR_DEAD      (5),
        .BOOT_DUMMY_CLKS (DUMMY),
        .UART_CLKS_PER_BIT (UART_CPB)
    ) uut (
        .clk(clk), .btnC(btnC), .sw15(sw15),
        .led(led),
        .dhb1_en1(dhb1_en1), .dhb1_dir1(dhb1_dir1),
        .dhb1_en2(dhb1_en2), .dhb1_dir2(dhb1_dir2),
        .enc_a(enc_a), .enc_b(enc_b),
        .qspi_cs_n(qspi_cs_n), .qspi_dq0(qspi_dq0), .qspi_dq1(qspi_dq1),
        .qspi_dq2(qspi_dq2), .qspi_dq3(qspi_dq3)
    );

    // Flash clock comes out of the STARTUPE2 model's pin, not a port.
    wire flash_sck = uut.u_startup.cclk_pin;

    spi_flash_model #(
        .MEM_BYTES (8192),
        .ADDR_BASE (24'h300000)
    ) flash (
        .sck(flash_sck), .cs_n(qspi_cs_n), .mosi(qspi_dq0), .miso(qspi_dq1)
    );

    always #5 clk = ~clk;

    integer i;
    integer fails = 0;

    task settle;
        begin
            repeat (6) @(negedge clk);
        end
    endtask

    task enc_step_forward;   // one full quadrature cycle = +4 counts
        begin
            enc_a = 0; enc_b = 1; settle;
            enc_a = 1; enc_b = 1; settle;
            enc_a = 1; enc_b = 0; settle;
            enc_a = 0; enc_b = 0; settle;
        end
    endtask

    task enc_step_reverse;   // one full quadrature cycle = -4 counts
        begin
            enc_a = 1; enc_b = 0; settle;
            enc_a = 1; enc_b = 1; settle;
            enc_a = 0; enc_b = 1; settle;
            enc_a = 0; enc_b = 0; settle;
        end
    endtask

    task check(input cond, input [8*64-1:0] msg);
        begin
            if (cond) $display("PASS [%0s]", msg);
            else begin $display("FAIL [%0s]", msg); fails = fails + 1; end
        end
    endtask

    // ---- Pin-level motor safety checker (runs in every mode) ----
    reg     prev_en = 0, prev_dir = 0;
    integer dir_violations = 0;
    integer en_high_fwd = 0, en_high_rev = 0;

    integer raw_pwm_high_disarmed = 0;

    always @(negedge clk) begin
        if (!sw15 && uut.pwm_raw)
            raw_pwm_high_disarmed = raw_pwm_high_disarmed + 1;
        if (dhb1_dir1 !== prev_dir && (dhb1_en1 || prev_en))
            dir_violations = dir_violations + 1;
        if (dhb1_en1 &&  dhb1_dir1) en_high_rev = en_high_rev + 1;
        if (dhb1_en1 && !dhb1_dir1) en_high_fwd = en_high_fwd + 1;
        prev_en  = dhb1_en1;
        prev_dir = dhb1_dir1;
    end

    reg [7:0] hb_first, hb_later;

    // ---- UART receiver (the PC's side of the cable) ----
    // Waits for a start bit on uart_txd, samples each bit mid-period,
    // and assembles characters into lines. Runs in every mode; only
    // the CACHE_LOCK program prints anything.
    localparam UART_CPB = 16;   // short bit time so simulation is fast

    reg  [8*128-1:0] cur_line  = 0;
    reg  [8*128-1:0] last_line = 0;
    integer          lines_rx = 0;
    integer          framing_errors = 0;
    integer          ub;
    reg  [7:0]       ch;

    always begin
        @(negedge uut.uart_txd);
        repeat (UART_CPB / 2) @(posedge uut.sys_clk);
        if (uut.uart_txd !== 1'b0) framing_errors = framing_errors + 1;
        for (ub = 0; ub < 8; ub = ub + 1) begin
            repeat (UART_CPB) @(posedge uut.sys_clk);
            ch[ub] = uut.uart_txd;
        end
        repeat (UART_CPB) @(posedge uut.sys_clk);
        if (uut.uart_txd !== 1'b1) framing_errors = framing_errors + 1;
        if (ch == 8'd10) begin
            last_line = cur_line;
            cur_line  = 0;
            lines_rx  = lines_rx + 1;
        end else if (ch != 8'd13) begin
            cur_line = {cur_line[8*127-1:0], ch};
        end
    end

    function [31:0] cpu_reg(input [4:0] n);
        cpu_reg = uut.u_cpu.regfile_inst.regs[n];
    endfunction

    integer parsed, p_run, p_umin, p_umax, p_lmin, p_lmax;

    initial begin
`ifdef CACHE_LOCK
        $readmemh("sw/hw_cache_lock_sim.hex", flash.mem);
`elsif MOTOR_TEST
        $readmemh("sw/hw_motor_test_sim.hex", flash.mem);
`else
        $readmemh("sw/hw_hello_sim.hex", flash.mem);
`endif

        repeat (20) @(negedge clk);
        btnC = 0;

`ifdef CACHE_LOCK
        // ---- Wait for three printed lines ----
        for (i = 0; i < 1000000 && lines_rx < 3; i = i + 1) @(negedge clk);
        check(lines_rx >= 3, "THREE_LINES_PRINTED_OVER_UART");
        check(framing_errors == 0, "UART_FRAMES_VALID");
        $display("line 3 as the PC will show it: \"%0s\"", last_line);

        // "run N: unlocked MIN-MAX cycles, locked MIN-MAX cycles"
        parsed = $sscanf(last_line, "run %d: unlocked %d-%d cycles, locked %d-%d cycles",
                         p_run, p_umin, p_umax, p_lmin, p_lmax);
        check(parsed == 5, "LINE_MATCHES_EXPECTED_FORMAT");
        check(p_run == 3, "RUN_COUNTER_IS_3_ON_THIRD_LINE");

        // print_dec must reproduce exactly what the CPU measured (the
        // program keeps the results in s5-s8 = x21-x24 until the next
        // run, and the testbench reads them during the delay loop).
        check(p_umin == cpu_reg(21) && p_umax == cpu_reg(22) &&
              p_lmin == cpu_reg(23) && p_lmax == cpu_reg(24),
              "PRINTED_NUMBERS_MATCH_CPU_REGISTERS");

        // The experiment itself, through the full board design, must
        // match the core-level runs (tb_interference_unlocked.v /
        // tb_interference_locked.v): 531 and 10 cycles, no jitter.
        check(p_umin == 531 && p_umax == 531, "UNLOCKED_531_EVERY_CALL");
        check(p_lmin == 10 && p_lmax == 10,   "LOCKED_10_EVERY_CALL");
        check(led == 16'd3 || led == 16'd4,    "LEDS_SHOW_RUN_COUNT");
`elsif MOTOR_TEST
        // ---- Arm switch down: motor must never be enabled ----
        sw15 = 0;
        for (i = 0; i < 60000; i = i + 1) @(negedge clk);
        check(en_high_fwd == 0 && en_high_rev == 0,
              "DISARMED_MOTOR_NEVER_ENABLED");
        $display("raw PWM high while disarmed: %0d cycles", raw_pwm_high_disarmed);
        check(raw_pwm_high_disarmed > 0,
              "SOFTWARE_WAS_COMMANDING_THE_MOTOR_ANYWAY");

        // ---- Arm switch up: enable should toggle in both directions ----
        sw15 = 1;
        for (i = 0; i < 200000; i = i + 1) @(negedge clk);
        $display("EN high cycles: forward=%0d reverse=%0d", en_high_fwd, en_high_rev);
        check(en_high_fwd > 0, "MOTOR_DRIVEN_FORWARD");
        check(en_high_rev > 0, "MOTOR_DRIVEN_REVERSE");
        check(dir_violations == 0, "DIR_NEVER_CHANGED_WITH_EN_HIGH");
        check(dhb1_en2 === 1'b0 && dhb1_dir2 === 1'b0, "MOTOR2_HELD_OFF");
`else
        // ---- Boot + heartbeat ----
        for (i = 0; i < 20000; i = i + 1) @(negedge clk);
        hb_first = led[15:8];
        for (i = 0; i < 20000; i = i + 1) @(negedge clk);
        hb_later = led[15:8];
        $display("heartbeat: %0d then %0d", hb_first, hb_later);
        check(led !== 16'hxxxx && hb_later != hb_first,
              "CPU_RUNS_FROM_FLASH_HEARTBEAT_ADVANCES");

        // ---- Encoder: 5 cycles forward (+20), then 2 back (-8) ----
        for (i = 0; i < 5; i = i + 1) enc_step_forward;
        for (i = 0; i < 3000; i = i + 1) @(negedge clk);
        $display("LED low byte after +20 counts: %0d", led[7:0]);
        check(led[7:0] == 8'd20, "LEDS_SHOW_ENCODER_FORWARD");

        for (i = 0; i < 2; i = i + 1) enc_step_reverse;
        for (i = 0; i < 3000; i = i + 1) @(negedge clk);
        $display("LED low byte after -8 counts: %0d", led[7:0]);
        check(led[7:0] == 8'd12, "LEDS_SHOW_ENCODER_REVERSE");

        check(dhb1_en1 === 1'b0, "HELLO_PROGRAM_NEVER_ENABLES_MOTOR");
`endif

        if (fails == 0) $display("ALL CHECKS PASSED");
        else            $display("%0d CHECK(S) FAILED", fails);
        $finish;
    end

endmodule
