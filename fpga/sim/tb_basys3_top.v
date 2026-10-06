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
// With -DCONTROL_LOOP: runs sw/hw_control_loop (the three-configuration
// control-loop measurement) and checks properties of its report that
// must hold whatever the exact numbers turn out to be.
// With -DSPEED_CONTROL: runs sw/hw_speed_control against a simulated DC
// motor driven by the real H-bridge pins (single-channel encoder, A
// stuck) and checks that the speed settles on every setpoint.
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

    reg  [8*160-1:0] cur_line  = 0;
    reg  [8*160-1:0] last_line = 0;
    reg  [8*160-1:0] line_buf [0:7];   // first 8 lines, for multi-line reports
    event            line_done;
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
            if (lines_rx < 8) line_buf[lines_rx] = cur_line;
            -> line_done;
            cur_line  = 0;
            lines_rx  = lines_rx + 1;
        end else if (ch != 8'd13) begin
            cur_line = {cur_line[8*159-1:0], ch};
        end
    end

    function [31:0] cpu_reg(input [4:0] n);
        cpu_reg = uut.u_cpu.regfile_inst.regs[n];
    endfunction

    integer parsed, p_run, p_umin, p_umax, p_lmin, p_lmax;
    integer r_min [0:2], r_mean [0:2], r_max [0:2], r_hz [0:2], r_per [0:2], r_bg [0:2];
    integer c, cfg_ok;
    integer v_min, v_mean, v_max, v_hz, v_per, v_bg;
    reg [8*160-1:0] tmp_line;

`ifdef SPEED_CONTROL
    // ---- DC motor model, driven by the real H-bridge pins ----
    // Speed follows the average drive (+1 forward, -1 reverse, 0 when
    // EN is low - PWM averages out through the lag) with a first-order
    // time constant; position integrates speed; every whole count the
    // shaft turns toggles encoder B. A is held stuck, like this
    // project's encoder. Scaled to the simulation's 2000-cycle tick:
    // full speed 50 counts per 16 ticks, time constant 30 ticks.
    localparam real VMAX = 50.0 / (16.0 * 2000.0);   // counts per cycle
    localparam real TAU  = 30.0 * 2000.0;            // cycles
    real    m_v = 0.0, m_pos = 0.0, m_drive;
    integer m_count = 0, m_new;

    always @(posedge uut.sys_clk) begin
        m_drive = dhb1_en1 ? (dhb1_dir1 ? -1.0 : 1.0) : 0.0;
        m_v     = m_v + (m_drive * VMAX - m_v) / TAU;
        m_pos   = m_pos + m_v;
        m_new   = $rtoi(m_pos + 1000000.0) - 1000000;   // floor, for either sign
        if (m_new != m_count) begin
            m_count = m_new;
            enc_b   = ~enc_b;
        end
    end

    // ---- Log checker: parse each "ms,setpoint,speed,duty" line ----
    // Segments are 150 ticks. In the last 40 ticks of each segment the
    // speed must be within 2 counts of the setpoint (settled); also
    // track the largest overshoot past each nonzero setpoint.
    integer l_ms = 0, l_sp, l_v, l_u, l_parsed;
    integer log_lines = 0, settled_checked = 0, settled_bad = 0;
    integer max_over = 0, min_rev = 0, saturated = 0;
    integer cur_sp = 0, prev_sp = 0;
    reg [5:0] seg_settled = 6'b0;     // a settled-window sample seen, per segment
    always @(line_done) begin
        tmp_line = last_line;
        l_parsed = $sscanf(tmp_line, "%d,%d,%d,%d", l_ms, l_sp, l_v, l_u);
        if (l_parsed == 4) begin
            log_lines = log_lines + 1;
            if ($test$plusargs("showlog")) $display("LOG %0s", tmp_line);
            if (l_ms % 150 >= 110) begin
                settled_checked = settled_checked + 1;
                seg_settled[(l_ms / 150) % 6] = 1'b1;
                if (l_v - l_sp > 2 || l_sp - l_v > 2) begin
                    settled_bad = settled_bad + 1;
                    if (settled_bad <= 5)
                        $display("NOT SETTLED: ms=%0d setpoint=%0d speed=%0d duty=%0d", l_ms, l_sp, l_v, l_u);
                end
            end
            // Overshoot: past the new setpoint, in the direction of the
            // step from the previous one.
            if (l_sp != cur_sp) begin prev_sp = cur_sp; cur_sp = l_sp; end
            if (l_sp > prev_sp && l_v - l_sp > max_over) max_over = l_v - l_sp;
            if (l_sp < prev_sp && l_sp - l_v > max_over) max_over = l_sp - l_v;
            if (l_v < min_rev) min_rev = l_v;
            if (l_u >= 1023 || l_u <= -1023) saturated = saturated + 1;
        end
    end
`endif

    initial begin
`ifdef CACHE_LOCK
        $readmemh("sw/hw_cache_lock_sim.hex", flash.mem);
`elsif CONTROL_LOOP
        $readmemh("sw/hw_control_loop_sim.hex", flash.mem);
`elsif SPEED_CONTROL
        $readmemh("sw/hw_speed_control_sim.hex", flash.mem);
        enc_a = 1'b1;           // channel A is dead: stuck
        sw15  = 1'b1;           // armed from the start
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
`elsif CONTROL_LOOP
        // ---- One full round: a header line plus one per configuration ----
        for (i = 0; i < 60000000 && lines_rx < 4; i = i + 1) @(negedge clk);
        check(lines_rx >= 4, "ROUND_REPORT_PRINTED");
        check(framing_errors == 0, "UART_FRAMES_VALID");
        $display("%0s", line_buf[0]);
        $display("%0s", line_buf[1]);
        $display("%0s", line_buf[2]);
        $display("%0s", line_buf[3]);

        // A "(missed N)" at the relaxed period would break the format,
        // so parsing also checks that every configuration kept up there.
        tmp_line = line_buf[1];
        parsed = $sscanf(tmp_line,
            "no cache: response min %d mean %d max %d cycles, max rate %d Hz (period %d), background %d",
            v_min, v_mean, v_max, v_hz, v_per, v_bg);
        r_min[0] = v_min; r_mean[0] = v_mean; r_max[0] = v_max;
        r_hz[0] = v_hz; r_per[0] = v_per; r_bg[0] = v_bg;
        check(parsed == 6, "NO_CACHE_LINE_PARSES_NO_MISSES_AT_P_REF");
        tmp_line = line_buf[2];
        parsed = $sscanf(tmp_line,
            "cache: response min %d mean %d max %d cycles, max rate %d Hz (period %d), background %d",
            v_min, v_mean, v_max, v_hz, v_per, v_bg);
        r_min[1] = v_min; r_mean[1] = v_mean; r_max[1] = v_max;
        r_hz[1] = v_hz; r_per[1] = v_per; r_bg[1] = v_bg;
        check(parsed == 6, "CACHE_LINE_PARSES_NO_MISSES_AT_P_REF");
        tmp_line = line_buf[3];
        parsed = $sscanf(tmp_line,
            "locked: response min %d mean %d max %d cycles, max rate %d Hz (period %d), background %d",
            v_min, v_mean, v_max, v_hz, v_per, v_bg);
        r_min[2] = v_min; r_mean[2] = v_mean; r_max[2] = v_max;
        r_hz[2] = v_hz; r_per[2] = v_per; r_bg[2] = v_bg;
        check(parsed == 6, "LOCKED_LINE_PARSES_NO_MISSES_AT_P_REF");

        // Internal consistency.
        cfg_ok = 1;
        for (c = 0; c < 3; c = c + 1)
            if (!(r_min[c] <= r_mean[c] && r_mean[c] <= r_max[c] &&
                  r_hz[c] == 25000000 / r_per[c] && r_max[c] < r_per[c]))
                cfg_ok = 0;
        check(cfg_ok, "MIN_LE_MEAN_LE_MAX_AND_HZ_MATCHES_PERIOD");

        // What locking must deliver, whatever the exact numbers.
        check(r_max[2] < r_max[1], "LOCKED_WORST_CASE_BEATS_UNLOCKED");
        check(r_max[2] < r_max[0], "LOCKED_WORST_CASE_BEATS_NO_CACHE");
        check(r_hz[2] > r_hz[1] && r_hz[2] > r_hz[0], "LOCKED_HAS_HIGHEST_MAX_RATE");
        // Locked jitter: the handler always hits, and since interrupts
        // abort the interrupted code's in-flight flash read instead of
        // waiting it out, entry no longer depends on what the background
        // was fetching. (Before that change: 137-319 cycles on hardware,
        // traced to exactly that wait.) What's left is a few cycles of
        // phase - where in the two-cycle fetch cadence and the abort
        // handshake the tick lands.
        check(r_max[2] - r_min[2] <= 8, "LOCKED_JITTER_AT_MOST_8_CYCLES");
`elsif SPEED_CONTROL
        // ---- One full setpoint cycle: 6 segments x 150 ticks. Logging
        // runs behind the tick rate in simulation (a line takes ~25
        // ticks to print), so wait on the logged time, not a line count.
        for (i = 0; i < 4000000 && l_ms < 900; i = i + 1) @(negedge clk);
        $display("%0d log lines; settled-window samples %0d, off by more than 2 counts: %0d",
                 log_lines, settled_checked, settled_bad);
        $display("largest overshoot past a new setpoint: %0d counts; lowest speed %0d; saturated samples %0d",
                 max_over, min_rev, saturated);
        check(framing_errors == 0,              "UART_FRAMES_VALID");
        check(l_ms >= 900,                      "LOG_COVERS_ALL_6_SEGMENTS");
        check(seg_settled == 6'b111111 && settled_bad == 0, "SPEED_SETTLES_WITHIN_2_COUNTS_EVERY_SEGMENT");
        check(min_rev <= -18,                   "MOTOR_REVERSES_FOR_NEGATIVE_SETPOINT");
        check(max_over <= 8,                    "OVERSHOOT_AT_MOST_8_COUNTS");
        check(dir_violations == 0,              "DIR_NEVER_CHANGED_WITH_EN_HIGH");
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
