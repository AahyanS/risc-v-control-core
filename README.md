# RISC-V Real-Time Control Processor

A 5-stage pipelined RISC-V (RV32I) processor written from scratch in
Verilog and run on a Xilinx Artix-7 FPGA, built to answer one question:
**does cache locking matter for real-time control?**

A cache makes code fast *on average*. A control loop doesn't care about
the average — it has to finish before the next tick, every tick, so one
cache miss at the wrong moment is a missed deadline. This processor
executes directly from slow SPI flash behind an instruction cache whose
lines can be locked, so the control loop can be pinned in place and never
evicted. On the real hardware, that makes the difference below.

## Results

The same interrupt-driven PID control loop, running on the FPGA next to a
background task, in three configurations of one chip — only a control
register differs between them:

| Configuration | Worst-case response | Max stable loop rate |
|---|---|---|
| No cache (every fetch from flash) | 3,701 cycles | 4.7 kHz |
| Cache | 4,231 cycles | 5.9 kHz |
| Cache, control loop locked | **65 cycles** | **100.4 kHz** |

- **Locking cuts the worst case 65x and runs the loop 17x faster.**
- **An unlocked cache is *worse* than no cache.** The background task is
  bigger than the cache, so it evicts the control loop between ticks; every
  tick then misses on every line and refills whole 4-word lines, including
  words the loop never executes. The cache's average-case benefit vanishes
  exactly where a control loop needs it.
- **Locking has a cost**, and it's measured too: other code mapping to the
  locked lines can no longer be cached, so the background task completes
  24% less work.

Max stable rate is the shortest timer period with zero missed deadlines,
found by binary search on the board. Every number here was measured on the
FPGA and printed over USB serial by the processor itself; the board output
is identical round after round:

```
no cache: response min 3701 mean 3701 max 3701 cycles, max rate 4698 Hz (period 5321), background 1062
cache: response min 4229 mean 4229 max 4231 cycles, max rate 5886 Hz (period 4247), background 1921
locked: response min 61 mean 61 max 65 cycles, max rate 100401 Hz (period 249), background 1459
```

The underlying effect in isolation — a small routine timed while a second
routine mapped to the same cache line runs between calls: **531 cycles
unlocked, 10 locked, on every call**, identical in simulation and on the
board.

### Other measured results

- **Interrupt latency jitter: 182 → 4 cycles.** Locking made the handler
  deterministic, but not *when it started*: interrupts waited for the
  interrupted code's in-flight flash read (traced: entry took 4–180 cycles
  depending on where in that read the tick landed). Interrupts are now
  taken in any cycle and abort the read, with a forward-progress rule so
  the interrupted code can never be starved. Locked response went from
  137–319 cycles to 61–65.
- **Custom multiply-accumulate instruction: 21x faster** PID math than the
  software multiply routine (1,585 vs. 33,343 cycles), in RISC-V's reserved
  custom-0 opcode space.
- **Branch prediction: 99.8% accurate** with a 2-bit counter on the control
  loop — matching a prediction made before running it, so a more complex
  predictor was deliberately not built.
- **Anti-windup:** overshoot drops from 42% to 1.3% against an otherwise
  identical PID without it.
- **Closed-loop motor speed control** with a single-channel encoder
  settles within 25–50 ms with at most 3 counts of overshoot, including a
  reversal, against a DC motor model driven by the real H-bridge pins in
  the board-level simulation.
- **FPGA cost:** 21% of the XC7A35T's LUTs, 4 DSP slices, no block RAM;
  meets timing up to 56 MHz (run at 25 MHz). The MAC instruction's
  multipliers are the critical path.

## Architecture

- **Pipeline:** IF / ID / EX / MEM / WB, in-order and single-issue by
  design — for hard real-time control, predictability is the feature.
  Full data forwarding, load-use hazard detection, 2-bit branch
  prediction. A single-cycle version of the core is kept as a reference.
- **Execute-in-place from SPI flash:** the program is fetched directly
  from the board's own configuration flash (stored above the FPGA
  bitstream), the way microcontrollers like the RP2040 and ESP32 run. A
  word costs 131 cycles from flash against 1 from cache. The flash's clock
  pin is reachable only through Xilinx's `STARTUPE2` primitive, which
  swallows its first three clocks after configuration; the boot sequence
  compensates.
- **Instruction cache:** direct-mapped, 16 lines x 16 bytes. A
  memory-mapped lock reserves a line for one address — that code fills it
  on first use and nothing else can evict it. A control bit disables the
  cache entirely, which is how all three configurations run on one
  bitstream.
- **Interrupts:** machine-mode timer interrupts (`mstatus`, `mie`,
  `mtvec`, `mepc`, `mcause`, `mret`), taken in any cycle, with the
  in-flight flash read aborted.
- **Peripherals (memory-mapped):** quadrature encoder decoder with a
  single-channel mode, PWM generator, periodic timer, UART transmitter,
  cycle and cache-hit counters, and a hardware guard that enforces the
  H-bridge's disable-before-reversing rule regardless of software.
- **Software:** fixed-point (Q16.16) PID with anti-windup in C, and an
  assembly version using the MAC instruction, small enough to lock into
  the cache.

## Verification

- The official RISC-V compliance suite (`riscv-tests`): **40/40** on both
  the single-cycle and pipelined cores.
- Differential co-simulation against an independent Python instruction-set
  simulator, comparing processor state after every instruction.
- 49 testbenches, including stress tests that land interrupts at every
  pipeline phase and check invariants every cycle — nothing executes
  between a trap and its handler, and every instruction matches flash at
  its address.
- Mutation testing: each bug fix is removed again to confirm the test that
  motivated it fails without it.
- A board-level simulation of the complete FPGA design — clocking, flash
  boot, peripherals, and a motor model — before anything runs on hardware.

Bugs found along the way include an instruction labeled with the wrong
address after an interrupt (causing an interrupt storm), a livelock where
interrupts starved slow code forever, a half-filled cache line left marked
valid after an aborted fill, and a data memory that synthesized into
65,536 flip-flops — more than the FPGA has. Each one, and how it was
traced, is in the [design log](docs/DESIGN_LOG.md).

## Hardware

- Digilent Basys3 (Xilinx Artix-7 XC7A35T)
- Digilent Pmod DHB1 H-bridge
- Pololu 50:1 micro metal gearmotor with encoder

## Repository layout

| Path | Contents |
|---|---|
| `rtl/` | The processor: pipelined and single-cycle cores, cache, SPI flash controller, peripherals |
| `tb/` | Testbenches and the SPI flash simulation model |
| `sw/` | Programs: PID controller, benchmarks, hardware experiments (`hw_*.s`) |
| `fpga/` | Basys3 top level, pin constraints, Vivado build and programming scripts, board-level simulation |
| `cosim/` | Reference instruction-set simulator and trace comparison |
| `compliance/` | Vendored `riscv-tests` |
| `docs/DESIGN_LOG.md` | Every design decision, measurement and bug, in the order the project was built |

## Running it

Requires [Icarus Verilog](https://steveicarus.github.io/iverilog/) and the
xPack RISC-V GCC toolchain.

```
bash run_all_tests.sh        # every testbench, both compliance suites, board simulation
```

Building for the FPGA requires Vivado; see [fpga/README.md](fpga/README.md)
for the build, flash programming, wiring, and serial output.
