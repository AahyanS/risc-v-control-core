# RISC-V real-time control accelerator

## Goal

Design and build a custom RV32I RISC-V CPU core in Verilog, extend it with a
custom instruction that accelerates PID control-loop math, and use the core
to run closed-loop control of a real DC motor on an FPGA. The point of the
project is to show a *measured* improvement in maximum stable control-loop
frequency caused by a hardware design decision, not just "a CPU that works."

## Current status

- [x] Phase 0: Learned Verilog fundamentals (HDLBits)
- [x] ALU module written and testbench passing
      (32-bit RV32I ALU: ADD, SUB, AND, OR, XOR, SLL, SRL, SRA, SLT, SLTU;
      files: `alu.v`, `tb_alu.v`)
- [x] Register file written and testbench passing
      (32 x 32-bit, 2 read ports + 1 write port, x0 hardwired to zero;
      files: `regfile.v`, `tb_regfile.v`)
- [x] Control unit written and testbench passing
      (decodes R-type/I-type opcode+funct3+funct7 into alu_ctrl, alu_src,
      reg_write; branches/loads/stores/jumps not wired up yet;
      files: `control.v`, `tb_control.v`)
- [ ] Program counter + instruction memory + fetch logic — **next task**
- [ ] Data memory + load/store support
- [ ] Single-cycle core integration (wire ALU + regfile + control + fetch +
      memory together into a working single-cycle RV32I CPU)
- [ ] Pipelining: 5-stage pipeline (IF / ID / EX / MEM / WB)
- [ ] Hazard detection + forwarding for the pipeline
- [ ] Custom PID-MAC instruction (see below)
- [ ] Simple cache, justified by repeated reads of PID gain constants
- [ ] Simple branch predictor, justified by the tight control-loop branch
- [ ] FPGA bring-up (Digilent Basys3, Vivado)
- [ ] Tier 1 hardware integration: closed-loop DC motor control

## Environment already set up

- Icarus Verilog (`iverilog`, `vvp`) + GTKWave for simulation, on Windows
- VS Code + "Verilog-HDL/SystemVerilog" extension
- Git + a GitHub repo for version control
- Target board: Digilent Basys3 (Xilinx Artix-7). Vivado not installed yet —
  install once the board is in hand (large download, not needed for
  simulation-only work).
- RISC-V GNU toolchain: not installed yet. Early modules use hand-written
  hex instructions in testbenches instead of compiled programs.

## Working pattern for every module

Every module in this project is built and verified the same way, established
with the ALU:

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

- ISA: RV32I integer base instruction set
- Build order: single-cycle datapath first, fully working and tested, then
  convert to a 5-stage pipeline (Fetch, Decode, Execute, Memory, Writeback)
  with hazard detection and forwarding.

### Custom ISA extension: PID-MAC instruction

- Encoding: use RISC-V's reserved custom-0 opcode space (does not break
  standard RV32I compliance).
- Semantics: `mac rd, rs1, rs2` performs `rd = rd + (rs1 * rs2)` as a single
  instruction — a fixed-point multiply-accumulate, replacing separate
  multiply + add instructions.
- Purpose: this is the core repeated operation in a PID loop
  (`output = Kp*error + Ki*integral + Kd*derivative`).
- Benchmark to report: cycles-per-control-loop-iteration, baseline
  (separate mul + add) vs. with the custom instruction.

### Cache

- Simple direct-mapped cache.
- Justification: the PID gain constants (Kp, Ki, Kd) and control-loop code
  are read repeatedly every iteration — this is the actual reason a cache
  helps here, not a generic "CPUs usually have one."
- Benchmark to report: hit rate measured specifically on the control-loop
  workload.

### Branch predictor

- Simple 2-bit saturating counter (or gshare if time allows).
- Justification: the control loop is one tight, highly repetitive loop —
  a strong case for prediction.
- Benchmark to report: misprediction rate on this same workload.

## Real-world integration target: Tier 1 — closed-loop motor control

- Hardware: a DC motor with a rotary encoder, a motor driver / H-bridge
  module (3.3V-logic compatible, e.g. Pmod-style), wired to Basys3 GPIO.
- Software: the RISC-V core reads encoder position/speed, runs the PID loop
  (using the custom MAC instruction), and drives PWM output to the motor.
- Demo to produce: video of the motor tracking a target speed and
  recovering from a manual disturbance; report the maximum stable control
  loop frequency achieved, baseline core vs. with the custom instruction.
- Estimated added hardware cost: ~$30-60 (motor + encoder, H-bridge driver).

## Metrics to report at the end (for the resume/portfolio writeup)

- Cycles-per-control-iteration: baseline vs. with custom MAC instruction
- Maximum stable control-loop frequency (Hz): baseline vs. optimized
- Cache hit rate, measured on the control-loop workload
- Branch predictor accuracy, measured on the control-loop workload
- FPGA synthesis results: max clock frequency and resource utilization
  (LUTs/FFs), and any measured tradeoff from adding the custom MAC unit
  (e.g. % change in max frequency)

## Immediate next step

Build the program counter + instruction memory + fetch logic: a PC
register that increments by 4 each cycle (or jumps/branches once those
are wired up), an instruction memory to fetch from, and the logic to
slice a fetched 32-bit word into opcode/funct3/funct7/rd/rs1/rs2/imm
fields for the control unit and register file. Write it and its
testbench following the same pattern as the earlier modules.
