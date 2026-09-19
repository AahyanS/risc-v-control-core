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
- [x] Data memory + load/store support
      (byte-addressable dmem with full LB/LH/LW/LBU/LHU/SB/SH/SW width +
      sign/zero-extend support; S-type immediate; mem_write/mem_to_reg/
      imm_sel control signals; write-back mux; verified end-to-end in
      cpu.v against a hand-assembled test program; files: `dmem.v`,
      `tb_dmem.v`, updated `control.v`/`cpu.v`/`tb_cpu.v`)
- [x] Branches (B-type) and jumps (JAL, JALR)
      (B-type/J-type immediates reassembled from their scattered
      instruction fields; branch condition reuses the ALU's SUB/SLT/
      SLTU outputs with funct3[0] as the invert bit; pc_next and
      write-back muxes widened; verified with a real 5-iteration loop
      plus a JAL/JALR call-and-return in tb_cpu.v; files: updated
      `control.v`, `cpu.v`, `tb_control.v`, `tb_cpu.v`)
- [x] LUI / AUIPC — completes base RV32I
      (U-type immediate needs no sign-extension, since instr[31:12]
      already sits exactly where the result's own top bits belong;
      LUI writes it directly, AUIPC adds it to pc via a dedicated
      adder - neither touches the ALU; verified in tb_cpu.v; files:
      updated `control.v`, `cpu.v`, `tb_control.v`, `tb_cpu.v`)
- [x] RISC-V GNU toolchain installed
      (xPack riscv-none-elf-gcc 15.2.0, bare-metal rv32i/ilp32 target;
      installed at `C:\riscv-toolchain\`, on PATH; verified by
      assembling a 3-instruction program and confirming the output
      machine code exactly matches tb_cpu.v's hand-derived encodings)
- [x] imem.v reshaped to byte-addressable (1024 x 8-bit, matching
      dmem.v's pattern) so it can be loaded via $readmemh from a real
      objcopy hex dump instead of hand-packed 32-bit words; tb_imem.v
      and tb_cpu.v updated to load byte-by-byte accordingly, full
      regression still passing (39/39 in tb_cpu.v)
- [x] Compile a real program with the toolchain and load it via $readmemh
      (sw/crt0.s + sw/sum_loop.c: a minimal startup stub sets up sp
      and hands off to main(), which sums 1..5 and stores the result
      to a fixed data memory address; compiled with
      `riscv-none-elf-gcc -march=rv32i -mabi=ilp32`, extracted with
      `objcopy -O verilog`, loaded directly into the byte-addressable
      imem.v with no hand-editing; verified end-to-end in
      tb_cpu_toolchain.v. First program on this core that wasn't
      hand-assembled instruction by instruction.)
- [x] **Passes the official RV32I architectural test suite**
      (all 40/40 applicable rv32ui tests from riscv-tests: add, addi,
      and, andi, auipc, beq, bge, bgeu, blt, bltu, bne, jal, jalr, lb,
      lbu, lh, lhu, lui, lw, or, ori, sb, sh, simple, sll, slli, slt,
      slti, sltiu, sltu, sra, srai, srl, srli, sub, sw, xor, xori,
      ld_st, st_ld. fence_i and ma_data excluded - not applicable/not
      yet supported. Used the *official, unmodified* per-instruction
      test bodies (they're pure integer arithmetic, no CSRs needed),
      but a custom minimal harness (`compliance/env/riscv_test.h` +
      `link.ld`) replacing the official CSR/ecall/trap-based pass-fail
      signaling this core doesn't support with a direct memory write,
      same convention (RESULT_ADDR gets 1=pass or (testnum<<1)|1=fail).
      Found and fixed a real architectural wrinkle: this core is
      Harvard-style (separate imem/dmem), but riscv-tests binaries
      assume one unified address space, so a compiled test's embedded
      data has to be mirrored into dmem at test-load time for
      load/store tests to find it - a testbench-level workaround, not
      a CPU change. Also discovered several R-type ALU test binaries
      (which include pipeline-bypass sub-tests this core doesn't need
      yet) exceed 1KB, so imem/dmem were enlarged to 8KB. Files:
      `compliance/`, `tb_compliance.v`, `run_compliance.sh`.)
- [x] Differential co-simulation against a reference ISS
      (`cosim/iss.py`: a from-scratch Python RV32I simulator,
      deliberately mirroring this core's exact architecture rather
      than an idealized unified-memory machine - same Harvard imem/
      dmem split, and only the opcodes control.v actually implements.
      Chosen over building Spike from source, which is real toolchain
      friction on Windows for the same verification value here.
      `tb_cosim.v` dumps a per-instruction trace from the real core in
      the same format; `cosim/compare_traces.py` diffs the two and
      reports the first divergence. Ran against sw/sum_loop.hex: all
      110 instructions matched exactly. Along the way, caught a real
      and non-obvious fact, not a bug: general-purpose registers have
      no defined reset value on this core (matching real RISC-V
      hardware - the spec doesn't require one either), so a compiler-
      generated prologue spilling an as-yet-unset register produced a
      spurious mismatch against the ISS's zero-initialized assumption.
      Fixed at the software level, the textbook-correct way: sw/crt0.s
      now explicitly zeroes x1-x31 at startup, the same thing
      riscv-tests' own INIT_XREG macro does and for the same reason -
      don't rely on hardware reset state you're not guaranteed. Files:
      `cosim/`, `tb_cosim.v`, updated `sw/crt0.s`.)

### Phase 2 — Pipeline

- [x] 5-stage pipeline (IF / ID / EX / MEM / WB)
      (cpu_pipeline.v, built alongside the untouched single-cycle
      cpu.v rather than replacing it; reuses every submodule
      unchanged, only the top-level wiring is new; verified on a
      hazard-free program - pipeline_test.s - before adding hazard
      handling on top; files: `cpu_pipeline.v`, `sw/pipeline_test.s`,
      `tb_cpu_pipeline.v`)
- [x] Control hazard handling (branches/jumps resolved in EX; fetch
      assumes sequential and gets corrected + the two wrongly-fetched
      instructions squashed on a misprediction - "predict not-taken,"
      standing in until the real branch predictor replaces just the
      prediction step, not this flush mechanism)
- [x] Hazard detection + forwarding
      (EX/MEM and MEM/WB forwarding for the ALU's operands and a
      store's data operand; a one-cycle load-use stall for the case
      forwarding can't cover, since a load's result isn't ready until
      MEM. Found and fixed a genuinely subtle timing gap along the
      way: a producer exactly 3 instructions before its consumer has
      its register-file write and the consumer's register-file read
      land on the *same* clock edge - too late for EX-stage
      forwarding (the producer has already fully retired past EX/MEM
      and MEM/WB) and too early for a plain register read (plain
      non-blocking-assignment semantics mean the write isn't visible
      until the *next* cycle). Fixed with a same-cycle write-through
      bypass at the ID stage, comparing against WB's own already-
      registered signals - deliberately *not* added inside regfile.v
      itself, since that module is shared with the single-cycle core,
      where the same instruction's own read and write can share an
      address (e.g. `addi x1,x1,5`) and doing it there creates a real
      combinational loop through the ALU. Verified with a dedicated
      hazard test program covering 0-gap and 1-gap ALU forwarding,
      0-gap store-data forwarding, and the load-use stall; files:
      `sw/pipeline_hazard_test.s`, `tb_cpu_pipeline_hazards.v`)
- [x] Real branch predictor (2-bit saturating counter, PC-indexed,
      64 entries), replacing the "always predict not-taken" policy
      (pulled forward from Phase 4 into the pipeline work itself,
      per user direction, rather than building a throwaway predict-
      not-taken scheme first). Predicted at fetch (bht lookup using
      pc[7:2], combined with a lightweight IF-stage pre-decode of
      opcode/imm_b/imm_j - full decode is still ID's job, but the
      predictor needs the branch's target before ID even runs);
      resolved for real in EX, updating the counter toward the
      actual outcome regardless of whether the prediction was right.
      Also added a genuine, unscoped-for-later improvement while
      building this: JAL's target is statically known from the
      instruction alone, so it's now resolved at fetch with zero
      penalty, not even treated as a "prediction" - only JALR (whose
      target needs a register value not available until EX) and an
      actual branch misprediction still trigger the late flush.
      Verified quantitatively, not just for correctness: a 7-
      execution loop (6 taken, 1 not-taken exit) produces exactly
      2 flushes under the real predictor, versus 6 under the old
      always-not-taken policy - checked via both the final learned
      bht state and a direct flush-cycle count, in
      tb_cpu_pipeline_predictor.v.

      Found and fixed a genuine bug along the way (not a leftover
      pre-existing issue): switching the flush condition to include
      `ex_is_jalr` (derived from id_ex_opcode) exposed that
      id_ex_opcode was never explicitly defined in the ID/EX
      register's squash branch - harmless under the old design
      (id_ex_jump was reliably 0 there and gated everything), but
      under the new one this let 'x' permanently poison ex_flush
      (and therefore pc_next) via Verilog's 4-state OR logic, where
      x-OR-anything stays x. Fixed by explicitly defining
      id_ex_opcode during squash. Files: `sw/pipeline_predictor_test.s`,
      `tb_cpu_pipeline_predictor.v`, updated `cpu_pipeline.v`.
- [x] Re-run the compliance suite against the pipelined core
      (40/40, matching the single-cycle result exactly - forwarding,
      the load-use stall, the flush mechanism, and the branch
      predictor all hold up against the official test suite, zero
      regressions. Reused the existing compliance infrastructure
      almost unchanged: cpu_pipeline.v shares cpu.v's submodule
      instance names, so tb_compliance_pipeline.v is nearly identical
      to tb_compliance.v, just instantiating the other core;
      run_compliance.sh takes an optional `pipeline` argument to pick
      which. Files: `tb_compliance_pipeline.v`, updated
      `run_compliance.sh`.)
- [ ] Generic stall mechanism (required later for cache-miss stalls) -
      deliberately deferred rather than built speculatively now: the
      only stall that exists today (load-use) is hardcoded for one
      specific condition and a fixed one-cycle duration, and a truly
      generic version needs to freeze multiple stages for a variable
      duration driven by an external signal whose exact shape isn't
      known until the Phase 3 cache controller actually exists to
      define it — **next task is Phase 3**

### Phase 3 — Memory hierarchy (the thesis)

- [x] QSPI flash read controller, plain SPI 0x03 reads
      (`spi_flash_ctrl.v`: mode-0 timing, SCK toggling once per clk
      cycle - one bit transferred per SCK period, so ~128 clk cycles
      per 32-bit read (8 cmd + 24 addr + 32 data bits, 2 clk/bit) - a
      real ~128x latency gap versus BRAM's 1-cycle fetch, not an
      artificial one. Verified against `spi_flash_model.v`, a genuine
      behavioral SPI slave (reacts only to sck/cs_n/mosi edges, no
      hierarchical peek into the controller's internals) standing in
      for real flash until Phase 5 hardware exists. Found and fixed a
      real bug: flash sends bytes in ascending address order (correct,
      matches real hardware), but naively shift-assembling that into
      a word gives big-endian byte order, while imem.v/dmem.v (and
      the whole rest of this project) are little-endian - fixed with
      an explicit byte-swap on the assembled result. SCK mirroring
      clk (rather than a proper independent, slower SPI clock domain)
      is a known simplification to revisit once a real chip's timing
      limits are known at hardware bring-up. Quad/fast-read
      optimization deferred - correctness first, matching the
      project's established pattern. Files: `spi_flash_ctrl.v`,
      `spi_flash_model.v`, `tb_spi_flash_ctrl.v`.)
- [x] XIP instruction-fetch path: program lives in flash, not BRAM
      (`cpu_pipeline_xip.v` - Configuration 1 of the core experiment:
      XIP from flash, no cache. Built as a new file, not a rewrite -
      cpu_pipeline.v stays intact as the BRAM-backed reference/
      compliance-suite target. Only IF changes; everything from ID
      onward is unchanged, since fetch timing is orthogonal to
      instruction correctness.

      IF now needs its own small state machine, since a flash fetch
      takes ~128 cycles instead of 1: pc_curr only moves on the exact
      cycle a fetch completes (flash_ready), frozen otherwise. Since
      a flash transaction can't be aborted once started, a
      misprediction/JALR flush discovered while a fetch is already
      in flight gets latched (pending_redirect/pending_target) and
      applied once that now-known-stale fetch finishes, discarding
      its result instead of using it - real instructions and their
      mispredictions don't stop happening just because fetch got
      slow. load_use_hazard also gates accepting a freshly-completed
      fetch into IF/ID, not just issuing a new one, for the (in
      practice vanishingly rare, given fetch is ~128 cycles vs. the
      pipeline's own ~5-cycle depth) case where it's still true right
      when a fetch lands - the fallback there is just a wasted, safe
      re-fetch, never an incorrect one.

      Found and fixed a real priority-order bug: the pc_next mux
      checked `fetch_issued` before `flash_ready`, but fetch_issued
      is a register that still reads its OLD value (1) at the exact
      moment flash_ready pulses - only clearing the cycle after. The
      mux therefore always took the "frozen" branch and never reached
      the "decide where to go" branch, permanently stalling pc_curr
      at 0 after the very first fetch. Fixed by checking flash_ready
      first.

      Verified by reusing the existing pipeline test programs
      (control-flow, hazards, predictor) against cpu_pipeline_xip.v +
      spi_flash_model.v instead of BRAM - deliberately reused rather
      than writing new ones, since they already exercise exactly the
      interactions that matter here (flush-while-mid-fetch, load-use
      timing, predictor training). All pass, including the predictor
      test's exact flush count (still 2, unchanged from the BRAM
      version) - confirming misprediction rate is governed purely by
      EX's comparison logic, independent of how IF fetches. Files:
      `cpu_pipeline_xip.v`, `tb_cpu_pipeline_xip.v`,
      `tb_cpu_pipeline_xip_hazards.v`, `tb_cpu_pipeline_xip_predictor.v`.)
- [x] Direct-mapped instruction cache with stall-on-miss + line fill
      (`icache.v` - Configuration 2 of the core experiment: XIP from
      flash, with a cache. 16 lines x 4 words (16 bytes) per line =
      256 bytes total. Address breakdown: `addr[3:2]` word offset,
      `addr[7:4]` line index, `addr[23:8]` tag.

      Deliberately built as a drop-in replacement for
      spi_flash_ctrl.v - same req/ready/rdata/busy interface, wrapping
      spi_flash_ctrl.v internally rather than being wired in alongside
      it. This meant cpu_pipeline_xip.v's entire IF state machine
      (fetch_issued/pending_redirect/pc_next priority/if_id_accept)
      could be reused completely unchanged in the new top-level file
      (`cpu_pipeline_cache.v`) - only the module instantiation swaps
      from spi_flash_ctrl to icache. Real interface constraint hit
      during design (not a bug found after the fact): a cache hit
      cannot answer combinationally in the same cycle as the request,
      because fetch_issued's update logic (`if (flash_req)
      fetch_issued<=1; else if (flash_ready) fetch_issued<=0;`) only
      checks the flash_ready branch when flash_req is NOT also true
      that same cycle - a same-cycle hit response would set
      fetch_issued=1 and never clear it, deadlocking fetch forever.
      Fixed by design: every hit takes exactly 1 cycle of latency
      (register the hit, respond ready the following cycle), matching
      the minimum latency spi_flash_ctrl.v already had.

      On a miss, fills the whole line via 4 separate spi_flash_ctrl.v
      transactions (word 0-3), then returns the specific word
      requested once the line is fully populated - not yet using
      flash's native continuous-read capability to fetch all 4 words
      in one transaction (would cost ~320 cycles instead of ~512 for
      a 16-byte line), deferred as a documented optimization, same
      pattern as deferring quad-SPI earlier. Cache line locking is a
      separate, later checklist item - no lock bit exists yet, to
      avoid building unused control-plane structure ahead of the
      mechanism that will actually drive it.

      Verified two ways: (1) architectural correctness - reused all
      three existing pipeline test programs (control-flow, hazards,
      predictor) against cpu_pipeline_cache.v, all checks pass
      including the predictor's exact flush count (still 2, confirming
      the cache changes fetch latency only, not misprediction
      behavior); (2) actual caching behavior, not just correctness - a
      new white-box testbench (`tb_icache_behavior.v`) counts cache
      requests vs. misses by peeking at icache_inst's internal state
      directly, running the looping predictor test program for 5000
      cycles: 1979 total fetch requests, only 2 misses, 1977 served as
      hits - concrete proof the cache is actually caching, not just
      passing through to flash every time. Files: `icache.v`,
      `cpu_pipeline_cache.v`, `tb_cpu_pipeline_cache.v`,
      `tb_cpu_pipeline_cache_hazards.v`,
      `tb_cpu_pipeline_cache_predictor.v`, `tb_icache_behavior.v`.)
- [x] **Cache line locking**: lock bit per line, plus a CSR or
      memory-mapped register to pin an address range (the actual
      thesis of this project. `icache.v` gained a `lock` bit per line
      alongside `valid`/`tag`, plus `lock_cmd`/`lock_set`/`lock_addr`
      ports; `cpu_pipeline_cache_locked.v` (Configuration 3) intercepts
      a `sw` to a reserved memory-mapped address (0xFFFFFF00 - well
      outside dmem's real 8KB range) in the MEM stage before it can
      reach dmem, and routes it to the cache's lock ports instead
      (store value bit 31 = lock/unlock, bits 23:0 = an address inside
      the target line). Software is expected to have already warmed
      the target line (fetched it at least once) before locking - the
      command only sets a bit, it doesn't force a fill.

      On a miss where the target line is locked, the cache can't
      evict it - instead it does a BYPASS fetch: get the single
      requested word straight from flash without touching cache
      storage at all. This is the real, concrete cost locking buys
      determinism with: any other address that aliases to a locked
      line (shares addr[7:4]) becomes permanently uncacheable for as
      long as the lock holds, since a direct-mapped cache has no
      associativity to fall back on.

      Found and fixed a real same-cycle race, not a hypothetical one -
      caught by tracing actual signal timing (per this project's
      standing debugging approach) rather than by inspection: the
      lock write and a conflicting miss on the exact same line landed
      in the same cycle in the very first test run. Since
      `lock[index] <= lock_set` is a non-blocking assignment, it
      doesn't take effect until the next cycle - so the miss-routing
      decision that same cycle read the stale (still-unlocked) value
      and evicted the line it was being asked to protect, one cycle
      before the lock would have caught it. Fixed with a combinational
      `req_index_locked` that ORs the registered lock bit with "a lock
      command landing on this exact index this exact cycle," so the
      routing decision can never race the write that's supposed to
      inform it.

      Verified two ways: (1) regression - the three existing pipeline
      test programs pass unchanged against
      cpu_pipeline_cache_locked.v, confirming the new MMIO decode
      doesn't disturb ordinary execution when the lock address is
      never touched; (2) a dedicated test
      (`sw/cache_lock_test.s` + `tb_cache_lock_protection.v`) that
      warms a line, locks it, then deliberately executes code placed
      exactly 256 bytes later (guaranteed same index, different tag,
      by construction: 256 = 2^8 is exactly one unit in the tag field
      while leaving the index field untouched) to try to evict it.
      White-box checks confirm the locked line's tag/valid are
      byte-for-byte unchanged after the conflicting access, and that
      the conflicting access actually went through the bypass path
      (30 bypass fetches observed, not silently ignored) - concrete
      proof the protection is real, not just architecturally
      invisible. Files: `icache.v`, `cpu_pipeline_cache_locked.v`,
      `sw/cache_lock_test.s`, `tb_cache_lock_protection.v`,
      `tb_cpu_pipeline_cache_locked.v`,
      `tb_cpu_pipeline_cache_locked_hazards.v`,
      `tb_cpu_pipeline_cache_locked_predictor.v`.)
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
- RISC-V GNU toolchain: xPack `riscv-none-elf-gcc` 15.2.0, installed at
  `C:\riscv-toolchain\`, on PATH. Early modules used hand-written hex
  instructions in testbenches; real programs are compiled now.

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

Phase 1 is complete: base RV32I, passing the official compliance suite,
verified against an independent reference model. Next is Phase 2 -
converting the single-cycle datapath into a 5-stage pipeline (IF / ID /
EX / MEM / WB). This means splitting cpu.v's combinational chain into
clocked pipeline registers between stages, then immediately confronting
hazards the single-cycle design never had to worry about: data hazards
(an instruction reading a register the previous instruction hasn't
written back yet - needs forwarding) and control hazards (a branch's
outcome isn't known until the EX stage, but fetch has already grabbed
the next 1-2 instructions sequentially - needs either a stall or a
simple predict-not-taken-and-flush scheme to start). The compliance
suite and cosim harness built in this phase aren't one-off checks -
both should be re-run against the pipelined core once it exists, since
hazards are exactly the kind of bug directed tests and even
differential testing on a single-cycle reference can miss if the
reference model doesn't also model pipeline timing.
