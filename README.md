# risc-v-control-core

A RISC-V (RV32I) processor built from scratch in Verilog, designed around a
specific argument: **for real-time control, average-case cache performance is
the wrong metric.** A cache makes the common case fast; it does nothing about
the worst case, and a worst-case latency spike is exactly what breaks a
control loop's deadline. The fix isn't a bigger cache — it's making the hot
path deterministic by locking it into the cache.

That argument is backed by measurement, not just made:

| | unlocked cache | locked cache |
|---|---|---|
| best case | 8 cycles | 10 cycles |
| under identical competing memory traffic | 531 cycles (every time) | 10 cycles (every time) |

Same hardware, same interference, only a lock bit differing — a 53x speedup
and the jitter eliminated entirely, not just reduced. See
[Results](#results) below for how this was measured, and [PROJECT.md](PROJECT.md)
for the full build log.

## Architecture

- **Core**: 5-stage pipelined RV32I (IF/ID/EX/MEM/WB), in-order, single-issue
  — deliberately. Out-of-order execution is the wrong answer for hard
  real-time control, where determinism is the feature, not an omission.
  Full data forwarding, load-use hazard detection, and a 2-bit
  saturating-counter branch predictor.
- **Memory hierarchy**: program executes in place (XIP) from external QSPI
  flash rather than on-chip BRAM, behind a direct-mapped instruction cache
  with **software-controlled cache-line locking** — the centerpiece of the
  project. A locked line can never be evicted; the real cost is that any
  other address aliasing to that line becomes permanently uncacheable while
  the lock holds, which is the actual, unavoidable tradeoff locking buys
  determinism with.
- **Interrupts**: a minimal but real M-mode subset (`mstatus`, `mie`, `mip`,
  `mtvec`, `mepc`, `mcause`; `CSRRW`/`CSRRS`/`MRET`) driven by a hardware
  timer, so a periodic control loop has a real trigger and "missed deadline"
  is a measurable event, not just a simulation artifact.
- **Peripherals**: a quadrature encoder decoder (4x decoding, hardware
  glitch rejection) and a PWM generator, both memory-mapped, both running
  continuously off the clock regardless of what the CPU is doing at any
  given moment — for the same reason the cache lock exists: correctness
  that depends on CPU timing is not correctness a real-time system can rely
  on.
- **Custom instruction**: `mac rd, rs1, rs2` (`rd = rd + rs1*rs2`, Q16.16
  fixed-point) in RISC-V's reserved custom-0 opcode space — a real hardware
  multiplier for the one operation a PID loop actually repeats, since base
  RV32I has no general multiply at all.
- **Control software**: a fixed-point (Q16.16) PID controller with
  integral anti-windup via conditional integration, written in C.

## Results

Every number below comes from an actual simulation run, not a calculation —
the standing rule for this project was to verify empirically and debug real
failures with signal traces, not fix things by reasoning about them in the
abstract.

- **Cache locking eliminates jitter, not just reduces it.** Under identical
  simulated bus contention (a second routine deliberately placed to alias to
  the same cache slot, called between every timed invocation of the "hot"
  routine), the unlocked cache misses on *every single call* (531 cycles,
  uniformly) while the locked cache hits on *every single call* (10 cycles,
  uniformly) — a 53x speedup and zero variance, from the same interference,
  with only a lock bit differing.
- **The branch predictor already sits at its ceiling.** On a representative
  control-loop shape (one tight backward branch, 1000 iterations), the 2-bit
  predictor achieves 99.8% accuracy — exactly 2 mispredictions (one
  cold-start, one unavoidable loop exit), matching a hand-derived prediction
  made *before* running anything. Decision: a fancier predictor (gshare) is
  deliberately not built, because there's nothing left for one to improve on
  for this workload — documented restraint backed by data.
- **The custom MAC instruction is ~21x faster** than the software multiply
  path (1585 vs. 33343 cycles for the same `Kp*error + Ki*integral +
  Kd*derivative` computation) — though precisely: this system is fetch-bound
  (XIP from flash), so the win comes from collapsing an entire software
  multiply routine into one instruction to fetch, not from faster per-cycle
  computation.
- **Anti-windup measurably prevents the failure mode it exists for.** Racing
  the real PID controller against a deliberately naive variant (no
  anti-windup guard) through the same saturating scenario: the guarded
  integral settles 32x smaller, and setpoint overshoot drops from 42% to
  1.3%.
- **Passes the official RV32I architectural compliance suite** (40/40,
  `riscv-tests`) on both the single-cycle and pipelined cores, cross-checked
  against an independently written Python ISA simulator via differential
  co-simulation.

## Verification approach

Every module has its own dedicated testbench exercising real edge cases, not
just the happy path. Beyond that:

1. The official `riscv-tests` architectural compliance suite — a
   categorically stronger claim than "my own tests pass."
2. Differential co-simulation against an independently written reference ISA
   simulator, comparing architectural state at every retired instruction.
3. End-to-end tests that drive real signal-level transitions on physical
   pins (encoder A/B channels, PWM output) and confirm software reads back
   what hardware actually did, not just what the source code says it should
   do.
4. Every claimed result above is measured through the hardware's own
   instrumentation (a free-running cycle counter and cache hit/miss
   counters, both memory-mapped), not computed by hand.

Several real bugs were found this way rather than through inspection —
notably a same-cycle race between a cache-lock command and a conflicting
miss, and a subtler one where a pipeline-inserted bubble (bit-identical to a
real `addi x0,x0,0`) could be mistaken for a valid interrupt trap point.
Both are documented in [PROJECT.md](PROJECT.md) with how they were traced and
fixed.

## Status

Phases 0 through 4 (base ISA, pipeline, memory hierarchy, cache locking,
control application — PID, peripherals, interrupts, the custom instruction)
are complete and verified in simulation. Phase 5 (a Digilent Basys3, a
Pmod DHB1 H-bridge, and an encoder-equipped gearmotor) is underway. **The
CPU runs on the physical board**, standalone: the FPGA configures itself
from its onboard flash and the CPU executes in place from the same chip,
through Xilinx's `STARTUPE2` primitive. On the XC7A35T it uses 20% of the
logic and meets timing up to about 55.5 MHz; the custom MAC instruction
is the critical path. Next is closed-loop motor control.
[fpga/README.md](fpga/README.md) is the bench procedure. See
[PROJECT.md](PROJECT.md) for the full checklist and design log.

## Repository layout

- Core: `cpu.v` (single-cycle reference), `cpu_pipeline*.v` (the three
  cache-configuration experiment cores), `alu.v`, `regfile.v`, `control.v`,
  `pc.v`
- Memory hierarchy: `spi_flash_ctrl.v`, `icache.v`, `imem.v`, `dmem.v`
- Peripherals: `quad_decoder.v`, `pwm.v`, `timer.v`, `motor_dir_guard.v`
- Board: `fpga/` — Basys3 top level, pin constraints, Vivado build
  script, board-level simulation, and the bring-up procedure
- Software: `sw/` — PID controller (`pid.c`/`pid.h`), test/benchmark
  programs, compliance harness
- Verification: `tb_*.v` (per-module and integration testbenches),
  `cosim/` (differential simulation against the Python reference ISS),
  `compliance/` (vendored `riscv-tests` + harness), `run_compliance.sh`

Every module builds and runs standalone with Icarus Verilog:

```
iverilog -o sim_<module> <module>.v tb_<module>.v
vvp sim_<module>
```

`PROJECT.md` has the full build order, every design decision and why it was
made, and every bug found along the way.
