# =============================================================================
# fhss_zynq : physical constraints (AX7Z020B)
# -----------------------------------------------------------------------------
# File    : board/fhss_zynq_pins.xdc
# Encoding: pure ASCII English comments (same policy as the timing file)
# Rules:
#   1. This file holds ONLY physical attributes: PACKAGE_PIN / IOSTANDARD /
#      SLEW / DRIVE etc.
#   2. All AD9363-related signals: LVCMOS33 + SLEW SLOW + DRIVE 4 (header
#      reflection reduction; SI budget: ribbon cable < 10 cm, ground pins
#      interleaved, ~1/3 of the 40 pins grounded)
#   3. Pin numbers are filled in category by category from the ALINX
#      official manual / schematic, then review-frozen (P1'-S1), kept 1:1
#      with docs/pins.md
#   4. A board swap (incl. the D0 fallback) replaces ONLY this file;
#      fhss_zynq_timing.xdc never changes
#
# Verified (2026-09-16, AX7Z020B official user manual sec 2.5 and the
# user-LED section):
#   - PL clock PL_GCLK1 = U18 (BANK34, 50 MHz single-ended)
#   - user LED1-4 = J14 / K14 / J18 / H18 (BANK35)
#   WARNING board-vintage variance: the 2016 ALINX AX7020 uses LEDs at
#   M14/M15/K16/J16 -- first thing after board arrival is to cross-check
#   these two entries against the physical board / schematic; until then
#   the bitstream is for tool-flow verification only, do NOT download it to
#   the board (on-board verification belongs to P1'-S1)
# =============================================================================

# ---- PL clock: 50 MHz single-ended oscillator (physical anchor of [1]) ----
set_property -dict {PACKAGE_PIN U18 IOSTANDARD LVCMOS33} [get_ports sys_clk]

# ---- User LEDs (smoke heartbeat indicator; BANK34/35 default VCCO = 3.3V) ----
set_property -dict {PACKAGE_PIN J14 IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN K14 IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN J18 IOSTANDARD LVCMOS33} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN H18 IOSTANDARD LVCMOS33} [get_ports {led[3]}]

# ---- AD9363 data port (CMOS, same rate as sampling; all slow slew; fill
#      in after the P1'-S1 header-pin assignment) ----
# set_property -dict {PACKAGE_PIN <> IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4} [get_ports ad9363_data_clk]
# set_property -dict {PACKAGE_PIN <> IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4} [get_ports {ad9363_rx_p0[0]}]
# set_property -dict {PACKAGE_PIN <> IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4} [get_ports {ad9363_rx_p0[1]}]
# ... (bus width and names per the ad9363_if port table, expanded pin by
#      pin, frozen after the header-assignment review)

# ---- AD9363 SPI (slow config port; MISO input needs no SLEW/DRIVE) ----
# set_property -dict {PACKAGE_PIN <> IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4} [get_ports {ad9363_spi_sclk ad9363_spi_mosi ad9363_spi_csn}]
# set_property -dict {PACKAGE_PIN <> IOSTANDARD LVCMOS33}                    [get_ports ad9363_spi_miso]

# ---- Misc: buttons / reserved debug pins (pending schematic) ----
# set_property -dict {PACKAGE_PIN <> IOSTANDARD LVCMOS33} [get_ports {btn[*]}]
