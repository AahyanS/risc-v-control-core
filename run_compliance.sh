#!/bin/bash
# run_compliance.sh
# Compiles compliance/isa/rv32ui/*.S with the real RISC-V toolchain
# against this core's custom minimal test harness (compliance/env/),
# then runs each through a compliance testbench and reports pass/fail.
#
# Usage:
#   ./run_compliance.sh            # single-cycle core (cpu.v)
#   ./run_compliance.sh pipeline   # pipelined core (rtl/cpu_pipeline.v)
# (run from the repo root - relative paths assume that)

set -u

TOOLCHAIN="/c/riscv-toolchain/xpack-riscv-none-elf-gcc-15.2.0-1/bin"
GCC="$TOOLCHAIN/riscv-none-elf-gcc.exe"
OBJCOPY="$TOOLCHAIN/riscv-none-elf-objcopy.exe"

TESTS="add addi and andi auipc beq bge bgeu blt bltu bne jal jalr lb lbu lh lhu lui lw or ori sb sh simple sll slli slt slti sltiu sltu sra srai srl srli sub sw xor xori ld_st st_ld"

if [ "${1:-}" = "pipeline" ]; then
    CORE_FILE="rtl/cpu_pipeline.v"
    TB_FILE="tb/tb_compliance_pipeline.v"
    SIM_NAME="sim_compliance_pipeline"
    echo "Target: pipelined core (cpu_pipeline.v)"
else
    CORE_FILE="rtl/cpu.v"
    TB_FILE="tb/tb_compliance.v"
    SIM_NAME="sim_compliance"
    echo "Target: single-cycle core (cpu.v)"
fi

mkdir -p build_compliance

echo "Compiling testbench..."
iverilog -o "$SIM_NAME" rtl/alu.v rtl/regfile.v rtl/control.v rtl/pc.v rtl/imem.v rtl/dmem.v "$CORE_FILE" "$TB_FILE"
if [ $? -ne 0 ]; then
    echo "Testbench compilation failed."
    exit 1
fi

pass_count=0
fail_count=0
total=0

for t in $TESTS; do
    total=$((total + 1))
    "$GCC" -march=rv32i -mabi=ilp32 -nostdlib -nostartfiles \
        -I compliance/env -I compliance/macros -I "compliance/isa/rv64ui" \
        -T compliance/env/link.ld \
        -o "build_compliance/$t.elf" "compliance/isa/rv32ui/$t.S" 2> "build_compliance/$t.compile.log"
    if [ $? -ne 0 ]; then
        echo "FAIL [$t]: compilation error (see build_compliance/$t.compile.log)"
        fail_count=$((fail_count + 1))
        continue
    fi

    "$OBJCOPY" -O verilog "build_compliance/$t.elf" "build_compliance/$t.hex"

    result=$(vvp "$SIM_NAME" +HEXFILE="build_compliance/$t.hex" +TESTNAME="$t")
    echo "$result"

    if echo "$result" | grep -q "^PASS"; then
        pass_count=$((pass_count + 1))
    else
        fail_count=$((fail_count + 1))
    fi
done

echo ""
echo "==================================="
echo "Compliance results: $pass_count / $total passed"
echo "==================================="

rm -f "$SIM_NAME"
