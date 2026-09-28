#!/bin/bash
# run_board_sim.sh
# Runs the board-level simulation (fpga/sim/tb_basys3_top.v) in all
# three modes. Run from the repository root after
# bash fpga/build_programs.sh:
#   bash fpga/sim/run_board_sim.sh

cd "$(dirname "$0")/../.."

SRC="alu.v regfile.v control.v pc.v dmem.v spi_flash_ctrl.v spi_flash_model.v \
     icache.v quad_decoder.v pwm.v timer.v motor_dir_guard.v \
     cpu_pipeline_cache_locked.v fpga/basys3_top.v fpga/sim/xilinx_stubs.v \
     fpga/sim/tb_basys3_top.v"

echo "=== hw_hello (boot from flash, heartbeat, encoder on LEDs) ==="
iverilog -o sim_board_hello $SRC && vvp sim_board_hello | grep -vE '^VCD|finish'

echo
echo "=== hw_motor_test (motor enable, direction, arm switch) ==="
iverilog -DMOTOR_TEST -o sim_board_motor $SRC && vvp sim_board_motor | grep -vE '^VCD|finish'

echo
echo "=== negative control: zero dummy boot clocks (expected to FAIL) ==="
iverilog -DNO_BOOT_DUMMY -o sim_board_nodummy $SRC && vvp sim_board_nodummy | grep -vE '^VCD|finish'
