#!/bin/bash
# run_all_tests.sh
# Runs every testbench in the repository with the source files its
# design under test needs, then the compliance suite on both cores and
# the board-level simulation. Prints PASS/FAIL counts per testbench and
# exits nonzero if anything failed.
#
# Exists because hand-picked regression lists missed a broken
# testbench once (tb_quad_decoder.v, after a port was added); this
# derives the list from the files themselves instead.
#
# Run from the repository root:  bash run_all_tests.sh

cd "$(dirname "$0")"

CORE="alu.v regfile.v control.v pc.v"
declare -A SRC=(
    [cpu]="$CORE imem.v dmem.v cpu.v"
    [cpu_pipeline]="$CORE imem.v dmem.v cpu_pipeline.v"
    [cpu_pipeline_xip]="$CORE dmem.v spi_flash_ctrl.v spi_flash_model.v cpu_pipeline_xip.v"
    [cpu_pipeline_cache]="$CORE dmem.v spi_flash_ctrl.v spi_flash_model.v icache.v cpu_pipeline_cache.v"
    [cpu_pipeline_cache_locked]="$CORE dmem.v spi_flash_ctrl.v spi_flash_model.v icache.v quad_decoder.v pwm.v timer.v uart_tx.v cpu_pipeline_cache_locked.v"
    [spi_flash_ctrl]="spi_flash_ctrl.v spi_flash_model.v"
    [icache]="icache.v spi_flash_ctrl.v spi_flash_model.v"
)

# Testbenches driven by their own scripts (they need +HEXFILE= etc.).
SKIP="tb_compliance.v tb_compliance_pipeline.v tb_cosim.v"

total_fail=0
bad=()

for tb in tb_*.v; do
    case " $SKIP " in *" $tb "*) continue ;; esac

    # The design under test is the first known module the testbench
    # instantiates; unit testbenches fall back to <module>.v.
    top=$(grep -oE "^\s*(cpu_pipeline_cache_locked|cpu_pipeline_cache|cpu_pipeline_xip|cpu_pipeline|cpu|spi_flash_ctrl|icache)\b" "$tb" | head -1 | tr -d ' ')
    if [ -n "$top" ]; then
        src=${SRC[$top]}
    else
        src="${tb#tb_}"
    fi

    out=$(iverilog -o /tmp/run_all_sim $src "$tb" 2>&1 && vvp /tmp/run_all_sim 2>&1)
    status=$?
    # Match failure markers, not check names that merely contain
    # "ERROR" (e.g. "PASS [ERROR_COUNT]").
    p=$(echo "$out" | grep -c "^PASS")
    f=$(echo "$out" | grep -cE "^FAIL|error:|ERROR:")

    if [ $status -ne 0 ] || [ "$f" -ne 0 ] || [ "$p" -eq 0 ]; then
        printf "%-45s %3d pass  %3d FAIL   <--\n" "$tb" "$p" "$f"
        bad+=("$tb")
        total_fail=$((total_fail + (f > 0 ? f : 1)))
    else
        printf "%-45s %3d pass\n" "$tb" "$p"
    fi
done

echo
echo "=== Compliance suite ==="
comp1=$(bash run_compliance.sh 2>&1 | grep "Compliance results")
comp2=$(bash run_compliance.sh pipeline 2>&1 | grep "Compliance results")
echo "single-cycle: $comp1"
echo "pipelined:    $comp2"
for c in "$comp1" "$comp2"; do
    if ! echo "$c" | grep -qE "([0-9]+) / \1 passed"; then
        bad+=("compliance")
        total_fail=$((total_fail + 1))
    fi
done

echo
echo "=== Board-level simulation ==="
board=$(bash fpga/sim/run_board_sim.sh 2>&1)
echo "$board" | grep -E "^===|ALL CHECKS|CHECK\(S\) FAILED"
# Expected: four passing runs, then the negative control failing.
if [ "$(echo "$board" | grep -c "ALL CHECKS PASSED")" -ne 4 ] || \
   [ "$(echo "$board" | grep -c "CHECK(S) FAILED")" -ne 1 ]; then
    bad+=("board sim")
    total_fail=$((total_fail + 1))
fi

echo
if [ $total_fail -eq 0 ]; then
    echo "ALL TESTS PASSED"
else
    echo "FAILURES in: ${bad[*]}"
    exit 1
fi
