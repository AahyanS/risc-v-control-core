#!/bin/bash
# run_board_sim.sh
# Runs the board-level simulation (fpga/sim/tb_basys3_top.v) in all
# six modes. Run from the repository root after
# bash fpga/build_programs.sh:
#   bash fpga/sim/run_board_sim.sh

cd "$(dirname "$0")/../.."

SRC="alu.v regfile.v control.v pc.v dmem.v spi_flash_ctrl.v spi_flash_model.v \
     icache.v quad_decoder.v pwm.v timer.v uart_tx.v motor_dir_guard.v \
     cpu_pipeline_cache_locked.v fpga/basys3_top.v fpga/sim/xilinx_stubs.v \
     fpga/sim/tb_basys3_top.v"

echo "=== hw_hello (boot from flash, heartbeat, encoder on LEDs) ==="
iverilog -o sim_board_hello $SRC && vvp sim_board_hello | grep -vE '^VCD|finish'

echo
echo "=== hw_motor_test (motor enable, direction, arm switch) ==="
iverilog -DMOTOR_TEST -o sim_board_motor $SRC && vvp sim_board_motor | grep -vE '^VCD|finish'


echo
echo "=== hw_cache_lock (locked vs. unlocked experiment, printed over UART) ==="
iverilog -DCACHE_LOCK -o sim_board_lock $SRC && vvp sim_board_lock | grep -vE '^VCD|finish'

echo
echo "=== hw_control_loop (three-configuration control-loop measurement) ==="
iverilog -DCONTROL_LOOP -o sim_board_control $SRC && vvp sim_board_control | grep -vE '^VCD|finish'

echo
echo "=== hw_speed_control (closed-loop speed control against a motor model) ==="
iverilog -DSPEED_CONTROL -o sim_board_speed $SRC && vvp sim_board_speed | grep -vE '^VCD|finish'

echo
echo "=== negative control: zero dummy boot clocks (expected to FAIL) ==="
iverilog -DNO_BOOT_DUMMY -o sim_board_nodummy $SRC && vvp sim_board_nodummy | grep -vE '^VCD|finish'
