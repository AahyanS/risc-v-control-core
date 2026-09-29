# Basys3 hardware bring-up

Step-by-step path from an unopened board to the CPU driving the motor.
Each step proves one new thing, so when something fails you know which
piece to look at.

| File | What it is |
|---|---|
| `bringup_top.v`, `bringup.xdc` | Step 2 test: switches to LEDs, plus a blinking LED |
| `basys3_top.v`, `basys3.xdc` | The real design: CPU + clocking + flash boot + motor safety |
| `build.tcl` | Vivado batch build (bitstream, flash image, reports) |
| `build_programs.sh` | Builds the hardware test programs (`sw/hw_*.bin`) |
| `sim/` | Board-level simulation of `basys3_top.v` (run `bash fpga/sim/run_board_sim.sh`) |

## 1. Install Vivado

1. Make an AMD account and download the **AMD Unified Installer** for
   Windows from [AMD's download page](https://www.xilinx.com/support/download.html)
   (the web installer is small; it downloads the rest).
2. In the installer choose **Vivado**, edition **Vivado ML Standard**
   (free, covers the XC7A35T).
3. On the device list, uncheck everything except **7 Series → Artix-7**.
   This cuts the install size dramatically.
4. Leave **Install Cable Drivers** checked.
5. After installing, open a new terminal and check `vivado -version`
   works. If it doesn't, run the `settings64.bat` in the Vivado install
   folder, or add Vivado's `bin` folder to your PATH.
6. **License (new in 2026.1).** Even the free tier needs a license file
   now. In the **Vivado License Manager**, note your **Host ID** under
   View Host Information (use the built-in Ethernet MAC; Wi-Fi MACs can
   be randomized), then on AMD's Product Licensing site create a free,
   node-locked **Vivado Basic Tier License** for that host ID and
   download `Xilinx.lic`. Put it in `C:\Users\<you>\.Xilinx\` and point
   Vivado at it with the user environment variable
   `XILINXD_LICENSE_FILE` (License Manager → Manage License Search
   Paths). On this install Vivado didn't find the file in `.Xilinx`
   on its own; the environment variable is what made it work. The
   license renews yearly.

If builds hit odd "file locked" errors, OneDrive is syncing
`fpga/build/` mid-build - pause OneDrive sync while building.

## 2. Bring-up test (no CPU yet)

1. Set jumper **JP1** (top-left, labeled MODE) to **JTAG**.
2. Plug the Basys3 into USB and flip the power switch on.
3. From the repository root:
   ```
   vivado -mode batch -source fpga/build.tcl -tclargs bringup
   ```
4. Load it onto the board, either from the command line:
   ```
   vivado -mode batch -source fpga/program.tcl -tclargs fpga/build/bringup/bringup_top.bit
   ```
   or in the GUI: **Open Hardware Manager** → **Open Target → Auto
   Connect** → **Program Device**, and pick
   `fpga/build/bringup/bringup_top.bit`.

**Expected:** LD15 blinks; LD0-LD14 follow SW0-SW14; holding the center
button freezes the blink. If that works, the toolchain, cable, and board
are all good.

## 3. The CPU, running from flash

The program lives in the Basys3's own configuration flash, at 3 MB, above
the FPGA bitstream. One `.mcs` file holds both.

1. Build (from the repository root):
   ```
   bash fpga/build_programs.sh
   vivado -mode batch -source fpga/build.tcl -tclargs core sw/hw_hello.bin
   ```
   Note the "Achievable frequency" printed at the end, and keep
   `fpga/build/core/timing_worst_20_paths.rpt` and `utilization.rpt` -
   those are the real Fmax and resource numbers for PROJECT.md.
2. Write the flash image and start the CPU:
   ```
   vivado -mode batch -source fpga/program_flash.tcl -tclargs fpga/build/core/basys3_flash.mcs fpga/build/core/basys3_top.bit
   ```
   This erases, writes, and verifies the flash, then loads the CPU over
   JTAG. The script defaults to the **Macronix MX25L3273F**, which is what
   this project's board has, even though Digilent's documentation lists a
   Spansion S25FL032P (older boards). If Vivado reports a part mismatch,
   it has read the chip's ID and stopped before writing anything; pass
   the part it detected as a third argument (for example
   `s25fl032p-spi-x1_x2_x4`). In the GUI instead: Hardware Manager →
   right-click the device → **Add Configuration Memory Device** → pick
   the part → **Program Configuration Memory Device**.
3. To run standalone: power off, set **JP1** to **QSPI**, power on. The
   FPGA loads itself from flash and the CPU starts running from the same
   chip, with no laptop involved.

**Expected:** LD15-LD8 count up a few times a second (the CPU is
running). LD7-LD0 are the encoder position - they'll only change once
the encoder is wired in step 4.

Iterating afterward: to try a new FPGA design, you can program the `.bit`
over JTAG without touching flash - the program already stored at 3 MB
stays put. To change only the program, rebuild with a different `.bin`
and reprogram the `.mcs`.

## 4. Wiring the motor and encoder

Do every step with the Basys3 **powered off** and the motor supply
**disconnected**.

**The two rules that protect the board:**
- The encoder is powered from the Basys3's **3.3 V**, never from the
  motor supply. Its A/B outputs are pulled up to whatever powers it, so
  powering it from 6 V would put 6 V on FPGA pins.
- The motor supply only connects to the DHB1's **VM/GND** screw
  terminals, and must stay between 2.7 V and 10.8 V. Never power the
  motor from the Basys3's USB.

Everything connects to the DHB1; nothing goes on the Basys3 except the
DHB1 itself. The DHB1's white JST connectors (J2, J3) aren't used.

**DHB1:** plug it into Pmod port **JB** (the top row of the DHB1's
12-pin header goes in the top row of JB).

**Preparing the Pololu cable (female-to-female, #4767):** cut it in
half. Plug one half's connector into the motor; keep the other half as
a spare. At the cut end:
- **Red and black:** strip about 6 mm. The wire is thin, so twist the
  strands tightly (folding the stripped end back on itself gives the
  screw terminal more to grip).
- **Yellow, white, green, blue:** cut four female-to-female jumpers in
  half, solder one half to each wire, and cover each joint with its own
  heat-shrink. These plug onto the DHB1's J7 pins.

**Motor power to J5** (blue screw terminal labeled M1+ / M1−):

| Pololu wire | Signal | DHB1 |
|---|---|---|
| Red | Motor M1 | **J5 M1+** |
| Black | Motor M2 | **J5 M1−** |

**Encoder to J7** (4-pin header labeled S1A / S1B, "M1 Feedback"). J7's
3.3 V comes from the Basys3, so the encoder is powered safely. The
DHB1 buffers A/B and forwards them to JB3/JB4.

| Pololu wire | Signal | DHB1 J7 pin |
|---|---|---|
| Yellow | Encoder A | 1 (SA1-IN) |
| White | Encoder B | 2 (SB1-IN) |
| Green | Encoder GND | 3 (GND) |
| Blue | Encoder VCC | 4 (VCC, 3.3 V) |

Before plugging onto J7, confirm which end is pin 1 with the multimeter
(DHB1 unpowered): J7 pin 3 reads ~0 Ω to J1 pin 5 (GND), and J7 pin 4
reads ~0 Ω to J1 pin 6 (VCC). Getting GND and VCC swapped would
reverse-power the encoder.

**Leave as-is:** the blue jumpers on JP1/JP2 only affect motor 2, and
headers J8, J9, and J10 aren't needed.

**Motor supply:** 6 V (e.g. 4×AA holder) to the DHB1's **J4** screw
terminal: **VM** (+) and **GND** (−).

**Before powering anything:** SW15 **down** (motor disarmed).

**Check the encoder first, motor unpowered:** power the Basys3 with the
`hw_hello` image from step 3 and turn the motor shaft by hand. LD7-LD0
should count up turning one way and down turning the other.

## 5. Motor test

1. Rebuild the flash image with the motor program:
   ```
   vivado -mode batch -source fpga/build.tcl -tclargs core sw/hw_motor_test.bin
   ```
   and program the new `.mcs` as in step 3.
2. Power on with SW15 down: LD14/LD15 cycle through the phases, but the
   motor stays still - the arm switch is overriding the software.
3. Connect the motor supply, then flip SW15 up.

**Expected:** about 2 s forward, 0.5 s stop, 2 s reverse, 0.5 s stop,
repeating. LD15 shows the direction, LD14 shows motor on, and LD13-LD0
(encoder position / 64) count up in one direction and down in the other.

If the count goes the wrong way for the direction you consider forward,
swap the yellow and white encoder wires on J7 (or the red and black
wires on J5). If it
doesn't move at all while the motor spins, recheck the encoder power and
A/B wiring. Flip SW15 down at any time to stop the motor.

## What's verified before hardware

`bash fpga/sim/run_board_sim.sh` simulates this exact design - MMCM,
reset, the STARTUPE2 flash path (including the three flash clocks that
are lost after configuration), the CPU fetching from 3 MB into flash,
the LEDs, the encoder, and the motor safety chain - with both programs.
It also runs a negative control with the boot workaround removed, which
fails, confirming the workaround is what makes booting work.
