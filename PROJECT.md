# RISC-V real-time control core with a lockable instruction cache

## Goal

Design and build a custom RV32I soft processor in Verilog that executes in
place (XIP) from external QSPI flash behind a **lockable instruction
cache**, and use it to run closed-loop control of a real DC motor on an
FPGA.

The thesis of the project is that **in a real-time system, average-case
performance is the wrong metric.** A cache dramatically improves average
instruction-fetch latency, but a single miss at the wrong moment causes a
missed control deadline. So the maximum *stable* control-loop frequency is
governed by worst-case behavior, not average behavior — and the fix is not
"a bigger cache," it is making the hot path *deterministic* by locking it
into the cache.

This is a deliberately different claim from "I built a CPU that works."
The deliverable is a measured result with a non-obvious conclusion.

## The core experiment

Three configurations, one workload (the PID control loop), one headline
metric (maximum stable control-loop frequency on a real motor):

| # | Configuration | Expected average | Expected worst case | Expected max stable rate |
|---|---|---|---|---|
| 1 | XIP from flash, **no cache** | Slow | Slow but *predictable* | Low |
| 2 | XIP from flash, **cache** | Much faster | Miss-induced jitter spikes | Limited by worst case, not average |
| 3 | XIP from flash, **cache + control loop locked** | Fast | Fast *and* predictable | Highest |

The interesting result is configuration 2: the average-case speedup is
large, but it does **not** translate proportionally into control
performance, because the loop must be clocked slow enough to survive its
worst iteration. Configuration 3 is what real-time-capable silicon
actually does (ARM Cortex-R, Infineon AURIX, TI C6000 all support cache
locking or scratchpad memory for exactly this reason).

## Current status

### Phase 1 — Complete the single-cycle RV32I core

- [x] Phase 0: Learned Verilog fundamentals (HDLBits)
- [x] ALU module written and testbench passing
      (32-bit RV32I ALU: ADD, SUB, AND, OR, XOR, SLL, SRL, SRA, SLT, SLTU;
      files: `alu.v`, `tb_alu.v`)
- [x] Register file written and testbench passing
      (32 x 32-bit, 2 read ports + 1 write port, x0 hardwired to zero;
      files: `regfile.v`, `tb_regfile.v`)
- [x] Control unit written and testbench passing
      (decodes R-type/I-type opcode+funct3+funct7 into alu_ctrl, alu_src,
      reg_write; files: `control.v`, `tb_control.v`)
- [x] Program counter written and testbench passing
      (synchronous reset to 0, advances to whatever pc_next carries;
      files: `pc.v`, `tb_pc.v`)
- [x] Instruction memory written and testbench passing
      (256 x 32-bit combinational ROM; files: `imem.v`, `tb_imem.v`)
- [x] Single-cycle core integration (pc + imem + control + alu + regfile;
      R-type/I-type ALU instructions only; verified end-to-end against a
      hand-assembled test program; files: `cpu.v`, `tb_cpu.v`)
- [ ] Data memory + load/store support (`dmem.v`, S-type immediate,
      mem_read/mem_write/mem_to_reg, write-back mux) — **next task**
- [ ] Branches (B-type) and jumps (JAL, JALR) — required before any real
      program can run
- [ ] LUI / AUIPC — completes the RV32I instruction set
- [ ] RISC-V GNU toolchain installed; compile real C/assembly instead of
      hand-assembled hex
- [ ] **Passes the official RV32I architectural test suite**
      (riscv-tests / RISCOF) — this is the credibility gate for every
      claim that follows
- [ ] Differential co-simulation against a reference ISS (Spike, or a
      small Python model): compare architectural state per retire

### Phase 2 — Pipeline

- [ ] 5-stage pipeline (IF / ID / EX / MEM / WB)
- [ ] Hazard detection + forwarding
- [ ] Generic stall mechanism (required later for cache-miss stalls)
- [ ] Re-run the compliance suite against the pipelined core

### Phase 3 — Memory hierarchy (the thesis)

- [ ] QSPI flash read controller (start with plain SPI 0x03 reads, then
      optimize to quad/fast-read)
- [ ] XIP instruction-fetch path: program lives in flash, not BRAM
- [ ] Direct-mapped instruction cache with stall-on-miss + line fill
- [ ] **Cache line locking**: lock bit per line, plus a CSR or
      memory-mapped register to pin an address range
- [ ] Instrumentation: cycle counter, hit/miss counters, per-iteration
      min/mean/max timing capture

### Phase 4 — Control application

- [ ] Fixed-point PID in C/assembly: Q-format, saturating arithmetic,
      integral anti-windup
- [ ] Quadrature encoder decoder peripheral
- [ ] PWM output peripheral
- [ ] Timer peripheral; optionally a real timer interrupt (M-mode CSRs +
      trap entry) so "deadline miss" becomes directly measurable
- [ ] Custom PID-MAC instruction (see below)
- [ ] Branch predictor + measurement (see below)

### Phase 5 — Hardware bring-up and measurement

- [ ] FPGA bring-up (Digilent Basys3, Vivado)
- [ ] Motor + encoder + driver integration
- [ ] Measurement campaign across the three configurations
- [ ] Portfolio writeup with scope/logic-analyzer evidence

## Environment already set up

- Icarus Verilog (`iverilog`, `vvp`) + GTKWave for simulation, on Windows
- VS Code + "Verilog-HDL/SystemVerilog" extension
- Git + a GitHub repo for version control
- Target board: Digilent Basys3 (Xilinx Artix-7 XC7A35T). Vivado not
  installed yet — install once the board is in hand.
- RISC-V GNU toolchain: not installed yet. Early modules use hand-written
  hex instructions in testbenches instead of compiled programs.

## Working pattern for every module

Every module in this project is built and verified the same way,
established with the ALU:

1. Write the Verilog module.
2. Write a dedicated testbench (`tb_<module>.v`) that exercises every
   meaningful case, including edge cases that would expose common bugs
   (e.g. signed vs. unsigned comparisons).
3. Run it locally: `iverilog -o sim_<module> <module>.v tb_<module>.v`
   then `vvp sim_<module>`. Every check should print PASS; investigate any
   FAIL before moving on.
4. Only integrate a module into the larger core after its own testbench is
   clean.

## Architecture plan

### Base CPU

- ISA: RV32I integer base instruction set.
- Build order: single-cycle datapath first, fully working and tested, then
  convert to a 5-stage pipeline with hazard detection and forwarding.
- In-order, single-issue, deliberately. Out-of-order execution is the
  *wrong* answer for hard real-time control, where determinism is the
  feature — this is a design decision to defend, not an omission.

### Memory hierarchy (the centerpiece)

- Program storage: external QSPI flash, executed in place. Flash reads
  cost tens to hundreds of cycles versus single-cycle BRAM, creating a
  genuine ~100x latency gap with no artificial slowdown.
- This mirrors real MCU-class systems: the RP2040, ESP32, and many STM32
  parts all XIP from external flash behind a cache.
- Data memory stays in on-chip BRAM (flash is read-mostly; writes need
  slow erase/program cycles). This split is also what real parts do.
- Instruction cache: direct-mapped to start. Size and line length are
  tunable parameters so hit rate and fill cost can be swept in simulation
  before committing to hardware.
- Cache misses stall the pipeline. Building this is what forces a proper
  stall mechanism, which is the genuinely hard and educational part of
  pipelining.

### Cache locking

- A lock bit per cache line, plus a control register to pin an address
  range and prevent eviction.
- Justification: the PID control loop is a small, known, hot code region
  with a hard deadline. Locking it converts the cache from an
  average-case optimization into a *worst-case guarantee*.
- This is the single most differentiating feature of the project and the
  source of configuration 3 in the core experiment.

### Custom ISA extension: PID-MAC instruction

- Encoding: RISC-V's reserved custom-0 opcode space (does not break RV32I
  compliance).
- Semantics: `mac rd, rs1, rs2` performs `rd = rd + (rs1 * rs2)` as a
  single fixed-point multiply-accumulate.
- Purpose: the core repeated operation in a PID loop
  (`output = Kp*error + Ki*integral + Kd*derivative`).
- Benchmark to report: cycles-per-control-iteration, baseline vs. custom
  instruction — **and** the cost side: does the multiplier lengthen the
  critical path and reduce Fmax? Report the tradeoff, not just the win.

### Branch predictor

- Simple 2-bit saturating counter.
- Expectation to test, not assume: the control loop is one tight backward
  branch, so a 2-bit counter should already reach ~97-99% accuracy.
- **Deliverable is the measurement and the decision.** If the simple
  predictor is already at the ceiling, gshare is documented as
  *deliberately not built*, with data showing why. Documented restraint
  backed by numbers is a stronger signal than unnecessary complexity.

## Verification strategy

Verification is treated as a first-class deliverable, not an afterthought:

1. Per-module testbenches (already established).
2. Official RV32I architectural test suite (riscv-tests / RISCOF). "Passes
   the official compliance suite" is a categorically stronger claim than
   "my own testbenches pass."
3. Differential co-simulation against a reference ISS: run instruction
   streams through both, compare architectural state at every retire.
4. External timing evidence: toggle a GPIO pin at control-loop start/end
   and capture jitter on a logic analyzer — independent confirmation that
   does not rely on the core's own self-reported counters.

## Real-world integration target: closed-loop motor control

- Hardware: DC gearmotor with a quadrature encoder, a 3.3V-logic-safe
  motor driver / H-bridge, and a separate motor power supply, wired to
  Basys3 Pmod headers.
- Software: the core reads encoder position/velocity, runs the fixed-point
  PID loop, and drives PWM to the motor.
- Demo to produce: video of the motor tracking a target speed and
  recovering from a manual disturbance — plus, critically, a demo of the
  motor **visibly destabilizing** when the loop is pushed past the rate
  the memory configuration can sustain. That failure mode is the thesis
  made physical.

## Metrics to report at the end (for the resume/portfolio writeup)

Primary (the thesis):

- Maximum stable control-loop frequency (Hz) across all three
  configurations: no cache / cache / cache + locking
- Per-iteration execution time: **mean vs. worst case** for each
  configuration — the gap between them is the whole point
- Deadline miss rate at a fixed loop frequency
- Cache hit rate on the control-loop workload

Supporting:

- Cycles-per-control-iteration: baseline vs. custom MAC instruction
- Fmax and LUT/FF utilization from Vivado, including the cost of the MAC
  unit and the cache
- Branch predictor accuracy, and the documented decision not to go further
- Compliance suite results (pass rate on riscv-tests RV32I)

## Bill of materials

Already owned / free:

- Basys3 board (if not yet in hand, this is the one hard prerequisite)
- Vivado (free WebPACK/Standard edition covers the XC7A35T)
- RISC-V GNU toolchain, riscv-tests/RISCOF, Spike — all free
- Icarus Verilog, GTKWave, VS Code, Git — already installed

To acquire:

- **QSPI flash for XIP.** Either use the Basys3's onboard configuration
  flash (free, but requires instantiating the Artix-7 `STARTUPE2`
  primitive to drive CCLK from user logic, *and* risks corrupting the
  FPGA config image while experimenting), or add a dedicated Pmod flash
  module (~$15-20) that plugs into a Pmod header and avoids both problems.
  The dedicated module is recommended.
- **DC gearmotor with quadrature encoder** (~$25-45 for a decent metal
  gearmotor; cheaper hobby motors with encoders exist ~$10 but have poor
  encoder quality, which will limit control performance and muddy the
  measurements).
- **Motor driver / H-bridge, 3.3V-logic compatible** (~$10-15). A
  Pmod-style H-bridge or a DRV8833/TB6612FNG breakout works. Avoid
  L298N-style modules: old, inefficient, and 5V-logic oriented.
- **Separate motor power supply** (~$10-15), typically 6-12V at 1-2A
  depending on the motor. Do not power the motor from the FPGA board.
- **Jumper wires / breadboard / Pmod cables** (~$10).
- **USB logic analyzer** (~$15 for a basic 8-channel clone, more for a
  Saleae). Strongly recommended: external jitter measurements are far
  more credible portfolio evidence than self-reported cycle counts, and
  scope screenshots make the writeup concrete.

Rough total to acquire: **~$85-135**, or ~$70-120 if using the onboard
config flash instead of a dedicated flash module.

Electrical cautions:

- Basys3 Pmod pins are 3.3V and **not** 5V tolerant. Verify encoder output
  voltage; level-shift if the encoder is 5V.
- Keep motor power and logic power separate, with a common ground.
- Motors generate electrical noise and back-EMF. Use a driver IC with
  built-in protection and keep motor wiring away from signal wiring.

## Immediate next step

Add data memory + load/store support: a data memory module (`dmem.v`),
extended control-unit decode for S-type (store) and I-type-load opcodes
(mem_read / mem_write / mem_to_reg signals), the S-type immediate (split
across two instruction fields, unlike I-type's contiguous immediate), and
a write-back mux so the register file can be loaded from either the ALU
result or a data memory read.
