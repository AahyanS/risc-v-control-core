// riscv_test.h
// Minimal bare-metal test harness for this core, standing in for the
// official riscv-tests env/p/riscv_test.h.
//
// The official harness signals pass/fail via `ecall` into a trap
// handler that writes a result to a `tohost` location - all of which
// needs CSRs (mtvec/mepc/mcause/mstatus) and `mret`, none of which
// this core implements (no privileged mode yet). The actual per-
// instruction test bodies (TEST_RR_OP etc., in test_macros.h) need
// none of that - they're pure integer arithmetic and branches - so
// only the surrounding harness needs replacing.
//
// This version writes the result directly to a fixed data-memory
// address (RESULT_ADDR) and spins, instead of trapping. Same
// TESTNUM/pass-fail encoding convention as the original: RVTEST_PASS
// writes 1; RVTEST_FAIL writes (TESTNUM << 1) | 1, so a failing
// sub-test's number can be recovered as (result >> 1).

#ifndef _ENV_CORE_TEST_H
#define _ENV_CORE_TEST_H

// Address 0x1FFC (8188): the last word of dmem's 8KB space. Originally
// 0x3FC (1020, then the top of a 1KB dmem), but some real riscv-tests
// binaries - the R-type ALU tests especially, which include pipeline-
// bypass sub-tests this core doesn't need yet - compile larger than
// 1KB, which would have collided with the result address itself.
#define RESULT_ADDR 0x1FFC

#define RVTEST_RV32U \
  .macro init;        \
  .endm

#define RVTEST_RV64U RVTEST_RV32U

#define TESTNUM gp

#define RVTEST_CODE_BEGIN \
        .section .text.init; \
        .align 2;             \
        .globl _start;        \
_start:                       \
        init;

#define RVTEST_CODE_END \
        unimp

#define RVTEST_PASS                    \
        fence;                          \
        li  TESTNUM, 1;                 \
        li  t0, RESULT_ADDR;            \
        sw  TESTNUM, 0(t0);             \
1:      j 1b

#define RVTEST_FAIL                    \
        fence;                          \
1:      beqz TESTNUM, 1b;               \
        slli TESTNUM, TESTNUM, 1;       \
        ori  TESTNUM, TESTNUM, 1;       \
        li   t0, RESULT_ADDR;           \
        sw   TESTNUM, 0(t0);            \
1:      j 1b

// No tohost/fromhost/HTIF needed without ecall - just keep the
// begin_signature/end_signature markers some tests reference.
#define RVTEST_DATA_BEGIN \
        .align 4; .global begin_signature; begin_signature:

#define RVTEST_DATA_END \
        .align 4; .global end_signature; end_signature:

#endif
