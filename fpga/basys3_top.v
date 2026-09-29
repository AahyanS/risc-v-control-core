// basys3_top.v
// Board-level wrapper: puts cpu_pipeline_cache_locked on a Digilent
// Basys3 (Artix-7 XC7A35T). Everything board-specific lives here so
// the core itself stays board-agnostic.
//
// ---- Clock ----
// The 100 MHz board oscillator goes through an MMCM to a 25 MHz system
// clock. That keeps the flash SCK (clk/2 = 12.5 MHz) far inside the
// flash's limits with a full 40 ns window between each SCK falling edge
// and the sample on the next rising edge. Cycle counts - the thing the
// project actually measures - don't depend on the clock frequency.
//
// ---- Program storage: the board's own configuration flash ----
// The FPGA bitstream lives at the bottom of the Basys3's onboard QSPI
// flash; the CPU's program is stored above it at FLASH_BASE (3 MB,
// above the ~2.2 MB XC7A35T bitstream) and fetched from there. The
// flash's clock pin is a dedicated configuration pin, so user logic
// can only drive it through Xilinx's STARTUPE2 primitive (USRCCLKO);
// the other signals are ordinary I/O once configuration finishes.
// Per Xilinx UG470, the first three USRCCLKO cycles after
// configuration never reach the pin, so this wrapper issues eight
// dummy clocks with chip-select high before letting the CPU out of
// reset - otherwise the first bits of the CPU's first read command
// would be lost.
//
// In single-bit SPI mode the flash's DQ2 (write protect) and DQ3
// (hold) pins must be held high; a floating HOLD pin can pause the
// flash mid-transfer.
//
// ---- Motor (Pmod DHB1 on JB, motor 1 only) ----
// PWM and direction go through motor_dir_guard, which enforces the
// DHB1's "disable before changing direction" requirement in hardware.
// Switch SW15 is a physical arm switch: with it down, the motor enable
// is forced low no matter what the software does. Motor 2 is held off.
//
// ---- Encoder (through the DHB1, arriving on JB3/JB4) ----
// The encoder plugs into the DHB1's J7 header, which supplies it with
// the Basys3's 3.3 V (never the motor supply - the Pololu encoder's
// outputs are pulled up to whatever powers it). The DHB1 passes A/B
// through 74-series inverting Schmitt-trigger buffers (NL27WZ14) to
// J1 pins 3/4. Inverting both channels keeps the quadrature sequence
// in the same cyclic order, so direction is unchanged; tb_quad_decoder
// checks this. quad_decoder.v has its own two-flop synchronizers.
//
// ---- LEDs ----
// LD0-LD15 show the CPU's LED register (0xFFFFFF28).
//
// ---- Serial output ----
// uart_txd goes to the Basys3's USB-UART bridge (FTDI FT2232, second
// channel), so the CPU's UART register (0xFFFFFF30) prints to a serial
// terminal on the PC over the same USB cable used for programming:
// 115200 baud, 8 data bits, no parity, 1 stop bit.

module basys3_top #(
    parameter [23:0] FLASH_BASE      = 24'h300000,
    parameter        MMCM_OUT_DIVIDE = 40,      // 1000 MHz VCO / 40 = 25 MHz
    parameter        MOTOR_DEAD      = 2500,    // cycles per guard phase = 100 us at 25 MHz
    parameter        BOOT_DUMMY_CLKS = 8,
    parameter        UART_CLKS_PER_BIT = 217    // 25 MHz / 115200 baud
) (
    input         clk,        // 100 MHz oscillator (W5)
    input         btnC,       // reset button
    input         sw15,       // motor arm switch

    output [15:0] led,
    output        uart_txd,   // to the USB-UART bridge (A18)

    // Pmod DHB1 on JB
    output        dhb1_en1,
    output        dhb1_dir1,
    output        dhb1_en2,
    output        dhb1_dir2,

    // Encoder, via DHB1 J7 -> S1A/S1B -> JB3/JB4
    input         enc_a,
    input         enc_b,

    // Onboard QSPI flash (clock goes through STARTUPE2)
    output        qspi_cs_n,
    output        qspi_dq0,   // MOSI
    input         qspi_dq1,   // MISO
    output        qspi_dq2,   // write protect, held high
    output        qspi_dq3    // hold, held high
);

    // ================= Clock =================

    wire clk_fb, clk_mmcm, sys_clk, mmcm_locked;

    MMCME2_BASE #(
        .CLKIN1_PERIOD    (10.0),
        .CLKFBOUT_MULT_F  (10.0),              // VCO = 1000 MHz
        .DIVCLK_DIVIDE    (1),
        .CLKOUT0_DIVIDE_F (MMCM_OUT_DIVIDE)
    ) u_mmcm (
        .CLKIN1   (clk),
        .CLKFBIN  (clk_fb),
        .CLKFBOUT (clk_fb),
        .CLKOUT0  (clk_mmcm),
        .LOCKED   (mmcm_locked),
        .PWRDWN   (1'b0),
        .RST      (btnC)
    );

    BUFG u_bufg (.I(clk_mmcm), .O(sys_clk));

    // ================= Reset =================
    // Held while the MMCM is unlocked or the button is pressed, then
    // released synchronously to sys_clk.

    reg [2:0] rst_sync = 3'b111;
    always @(posedge sys_clk or negedge mmcm_locked) begin
        if (!mmcm_locked)
            rst_sync <= 3'b111;
        else
            rst_sync <= {rst_sync[1:0], btnC};
    end
    wire board_reset = rst_sync[2];

    // ================= Flash boot sequence =================

    wire eos;
    reg  [1:0] eos_sync;
    always @(posedge sys_clk) eos_sync <= {eos_sync[0], eos};

    localparam BOOT_WAIT_EOS = 2'd0;
    localparam BOOT_DUMMY    = 2'd1;
    localparam BOOT_DONE     = 2'd2;

    reg [1:0] boot_state;
    reg [4:0] dummy_edges;
    reg       boot_clk;

    always @(posedge sys_clk) begin
        if (board_reset) begin
            boot_state  <= BOOT_WAIT_EOS;
            dummy_edges <= 5'd0;
            boot_clk    <= 1'b0;
        end else begin
            case (boot_state)
                BOOT_WAIT_EOS:
                    if (eos_sync[1]) boot_state <= BOOT_DUMMY;
                BOOT_DUMMY: begin
                    boot_clk    <= ~boot_clk;
                    dummy_edges <= dummy_edges + 5'd1;
                    if (dummy_edges == 2 * BOOT_DUMMY_CLKS - 1) begin
                        boot_clk   <= 1'b0;
                        boot_state <= BOOT_DONE;
                    end
                end
                default: ;
            endcase
        end
    end

    wire boot_done = (boot_state == BOOT_DONE);
    wire cpu_reset = board_reset || !boot_done;

    // ================= Core =================

    wire cpu_sck, cpu_cs_n, cpu_mosi;
    wire pwm_raw, motor_dir_req;

    cpu_pipeline_cache_locked #(
        .FLASH_BASE        (FLASH_BASE),
        .UART_CLKS_PER_BIT (UART_CLKS_PER_BIT)
    ) u_cpu (
        .clk       (sys_clk),
        .reset     (cpu_reset),
        .sck       (cpu_sck),
        .cs_n      (cpu_cs_n),
        .mosi      (cpu_mosi),
        .miso      (qspi_dq1),
        .enc_a     (enc_a),
        .enc_b     (enc_b),
        .pwm_out   (pwm_raw),
        .led       (led),
        .motor_dir (motor_dir_req),
        .uart_tx   (uart_txd)
    );

    // ================= Flash pins =================

    wire flash_clk = boot_done ? cpu_sck  : boot_clk;
    assign qspi_cs_n = boot_done ? cpu_cs_n : 1'b1;
    assign qspi_dq0  = cpu_mosi;
    assign qspi_dq2  = 1'b1;
    assign qspi_dq3  = 1'b1;

    STARTUPE2 #(
        .PROG_USR      ("FALSE"),
        .SIM_CCLK_FREQ (0.0)
    ) u_startup (
        .CFGCLK    (),
        .CFGMCLK   (),
        .EOS       (eos),
        .PREQ      (),
        .CLK       (1'b0),
        .GSR       (1'b0),
        .GTS       (1'b0),
        .KEYCLEARB (1'b1),
        .PACK      (1'b0),
        .USRCCLKO  (flash_clk),
        .USRCCLKTS (1'b0),
        .USRDONEO  (1'b1),
        .USRDONETS (1'b1)
    );

    // ================= Motor =================

    reg [1:0] arm_sync;
    always @(posedge sys_clk) arm_sync <= {arm_sync[0], sw15};
    wire motor_armed = arm_sync[1];

    wire guard_en;

    motor_dir_guard #(.DEAD_CYCLES(MOTOR_DEAD)) u_guard (
        .clk     (sys_clk),
        .reset   (cpu_reset),
        .pwm_in  (pwm_raw),
        .dir_req (motor_dir_req),
        .en_out  (guard_en),
        .dir_out (dhb1_dir1)
    );

    assign dhb1_en1  = guard_en && motor_armed;
    assign dhb1_en2  = 1'b0;
    assign dhb1_dir2 = 1'b0;

endmodule
