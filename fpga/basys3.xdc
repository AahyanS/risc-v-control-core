## basys3.xdc
## Pin constraints for fpga/basys3_top.v on a Digilent Basys3 (rev B/C).
## Pin locations are taken from Digilent's official master XDC
## (github.com/Digilent/digilent-xdc, Basys-3-Master.xdc).

## ---- Clock: 100 MHz oscillator ----
## The MMCM's 25 MHz output clock is derived automatically from this.
set_property -dict { PACKAGE_PIN W5  IOSTANDARD LVCMOS33 } [get_ports clk]
create_clock -add -name sys_clk_pin -period 10.00 -waveform {0 5} [get_ports clk]

## ---- Reset button (center) and motor arm switch (SW15) ----
set_property -dict { PACKAGE_PIN U18 IOSTANDARD LVCMOS33 } [get_ports btnC]
set_property -dict { PACKAGE_PIN R2  IOSTANDARD LVCMOS33 } [get_ports sw15]

## ---- LEDs LD0-LD15 ----
set_property -dict { PACKAGE_PIN U16 IOSTANDARD LVCMOS33 } [get_ports {led[0]}]
set_property -dict { PACKAGE_PIN E19 IOSTANDARD LVCMOS33 } [get_ports {led[1]}]
set_property -dict { PACKAGE_PIN U19 IOSTANDARD LVCMOS33 } [get_ports {led[2]}]
set_property -dict { PACKAGE_PIN V19 IOSTANDARD LVCMOS33 } [get_ports {led[3]}]
set_property -dict { PACKAGE_PIN W18 IOSTANDARD LVCMOS33 } [get_ports {led[4]}]
set_property -dict { PACKAGE_PIN U15 IOSTANDARD LVCMOS33 } [get_ports {led[5]}]
set_property -dict { PACKAGE_PIN U14 IOSTANDARD LVCMOS33 } [get_ports {led[6]}]
set_property -dict { PACKAGE_PIN V14 IOSTANDARD LVCMOS33 } [get_ports {led[7]}]
set_property -dict { PACKAGE_PIN V13 IOSTANDARD LVCMOS33 } [get_ports {led[8]}]
set_property -dict { PACKAGE_PIN V3  IOSTANDARD LVCMOS33 } [get_ports {led[9]}]
set_property -dict { PACKAGE_PIN W3  IOSTANDARD LVCMOS33 } [get_ports {led[10]}]
set_property -dict { PACKAGE_PIN U3  IOSTANDARD LVCMOS33 } [get_ports {led[11]}]
set_property -dict { PACKAGE_PIN P3  IOSTANDARD LVCMOS33 } [get_ports {led[12]}]
set_property -dict { PACKAGE_PIN N3  IOSTANDARD LVCMOS33 } [get_ports {led[13]}]
set_property -dict { PACKAGE_PIN P1  IOSTANDARD LVCMOS33 } [get_ports {led[14]}]
set_property -dict { PACKAGE_PIN L1  IOSTANDARD LVCMOS33 } [get_ports {led[15]}]

## ---- Pmod DHB1 plugged into JB (top row = pins 1-4, bottom row = 7-10) ----
## DHB1 J1: 1=EN1 2=DIR1 3=S1A 4=S1B 7=EN2 8=DIR2 9=S2A 10=S2B
## S1A/S1B/S2A/S2B are unused - the encoder is wired to JC instead.
set_property -dict { PACKAGE_PIN A14 IOSTANDARD LVCMOS33 } [get_ports dhb1_en1]
set_property -dict { PACKAGE_PIN A16 IOSTANDARD LVCMOS33 } [get_ports dhb1_dir1]
set_property -dict { PACKAGE_PIN A15 IOSTANDARD LVCMOS33 } [get_ports dhb1_en2]
set_property -dict { PACKAGE_PIN A17 IOSTANDARD LVCMOS33 } [get_ports dhb1_dir2]

## ---- Encoder on JC: JC1 = channel A, JC2 = channel B ----
## (JC pin 5 = GND, JC pin 6 = 3.3 V for the encoder's supply)
set_property -dict { PACKAGE_PIN K17 IOSTANDARD LVCMOS33 } [get_ports enc_a]
set_property -dict { PACKAGE_PIN M18 IOSTANDARD LVCMOS33 } [get_ports enc_b]

## ---- Onboard QSPI flash ----
## The flash clock (CCLK) is not listed: it's a dedicated configuration
## pin driven through the STARTUPE2 primitive in basys3_top.v.
set_property -dict { PACKAGE_PIN K19 IOSTANDARD LVCMOS33 } [get_ports qspi_cs_n]
set_property -dict { PACKAGE_PIN D18 IOSTANDARD LVCMOS33 } [get_ports qspi_dq0]
set_property -dict { PACKAGE_PIN D19 IOSTANDARD LVCMOS33 } [get_ports qspi_dq1]
set_property -dict { PACKAGE_PIN G18 IOSTANDARD LVCMOS33 } [get_ports qspi_dq2]
set_property -dict { PACKAGE_PIN F18 IOSTANDARD LVCMOS33 } [get_ports qspi_dq3]

## ---- Timing exceptions ----
## Button, switch, and encoder inputs are asynchronous and each passes
## through a two-flop synchronizer. LED and motor outputs have no
## timing requirement. The flash interface runs at 12.5 MHz with a full
## 40 ns clk period between the flash updating MISO and this design
## sampling it (see the header of basys3_top.v), so it is left out of
## the timing analysis rather than modelled with I/O delays - the
## timing report then reflects the core's own internal paths, which is
## the Fmax question the project needs answered.
set_false_path -from [get_ports {btnC sw15 enc_a enc_b qspi_dq1}]
set_false_path -to   [get_ports {led[*] dhb1_* qspi_*}]

## ---- Configuration: boot from the onboard QSPI flash ----
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CFGBVS VCCO [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 33 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
