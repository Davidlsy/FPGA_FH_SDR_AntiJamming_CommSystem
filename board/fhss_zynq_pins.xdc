# =============================================================================
# fhss_zynq : physical constraints (ALINX AX7020, 2016 board)
# -----------------------------------------------------------------------------
# File    : board/fhss_zynq_pins.xdc
# Encoding: pure ASCII English comments (same policy as the timing file)
# Rules:
#   1. This file holds ONLY physical attributes: PACKAGE_PIN / IOSTANDARD /
#      SLEW / DRIVE etc.
#   2. All AD9363-related signals: LVCMOS33 + SLEW SLOW + DRIVE 4 (header
#      reflection reduction; SI budget: ribbon cable < 10 cm, ground pins
#      interleaved, >= 1/3 of the 40 pins grounded)
#   3. Pin numbers filled category by category from the ALINX AX7020 user
#      manual V2.2, then review-frozen (P1'-S1), kept 1:1 with docs/pins.md
#   4. A board swap (incl. the D0 fallback) replaces ONLY this file;
#      fhss_zynq_timing.xdc never changes
#   5. Filled-but-commented blocks (keys / AD9363): pin numbers are frozen
#      from the manual, but the lines stay commented until the integration
#      top exposes those ports -- on the S0 smoke top (sys_clk + led only)
#      each line would only raise Common 17-55 critical warnings (verified
#      2026-10-09). Enable them together with the ad9363_if / btn ports,
#      then flip docs/pins.md status to "enabled".
#
# Board identity (2026-10-09): ALINX AX7020 (2016 release,
# XC7Z020-2CLG400I), per the ALINX AX7020 user manual V2.2
# (docs/AX7020_2017.4.1/). This settles the board-vintage variance warned
# about by the previous revision:
#   - PL clock PL_GCLK = U18 (BANK34, 50 MHz single-ended) -- unchanged,
#     manual sec 5.2
#   - user LED1-4 = M14 / M15 / K16 / J16 (BANK35), manual sec 7.6.
#     The AX7Z020B values (J14/K14/J18/H18) are J11 header pins on THIS
#     board (PIN9/10 = H18/J18, PIN35/36 = J14/K14), so they were wrong
#     here and are now reused as AD9363 / ground-interleave pins
#   - user KEY1-4 = N15 / N16 / T17 / R17 (BANK35/34), manual sec 7.7
#   - J10 / J11 40-pin headers: manual sec 7.4 / 7.5; AD9363 map = RX group
#     on J10, TX group + control on J11, partner pins are cable grounds
#     (see docs/pins.md sec 4.3 for the full 2x40 pin maps)
# =============================================================================

# ---- PL clock: 50 MHz single-ended oscillator (physical anchor of [1]) ----
set_property -dict {PACKAGE_PIN U18 IOSTANDARD LVCMOS33} [get_ports sys_clk]

# ---- User LEDs (smoke heartbeat indicator; BANK35 VCCO = 3.3V) ----
set_property -dict {PACKAGE_PIN M14 IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN M15 IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN K16 IOSTANDARD LVCMOS33} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN J16 IOSTANDARD LVCMOS33} [get_ports {led[3]}]

# ---- User keys KEY1-4, active-low (manual sec 7.7); enable with btn ports ----
# set_property -dict {PACKAGE_PIN N15 IOSTANDARD LVCMOS33} [get_ports {btn[0]}]
# set_property -dict {PACKAGE_PIN N16 IOSTANDARD LVCMOS33} [get_ports {btn[1]}]
# set_property -dict {PACKAGE_PIN T17 IOSTANDARD LVCMOS33} [get_ports {btn[2]}]
# set_property -dict {PACKAGE_PIN R17 IOSTANDARD LVCMOS33} [get_ports {btn[3]}]

# ---- AD9363 data port (CMOS, same rate as sampling; all slow slew).
#      RX group on J10 (PIN3-30, BANK34): data_clk / rx_frame / rx_p0[11:0]
#      listed pin by pin per the ad9363_if port table ----
# set_property -dict {PACKAGE_PIN W19 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4} [get_ports ad9363_data_clk]
# set_property -dict {PACKAGE_PIN R14 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4} [get_ports ad9363_rx_frame]
# set_property -dict {PACKAGE_PIN Y17 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4} [get_ports {ad9363_rx_p0[0]}]
# set_property -dict {PACKAGE_PIN W15 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4} [get_ports {ad9363_rx_p0[1]}]
# set_property -dict {PACKAGE_PIN Y14 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4} [get_ports {ad9363_rx_p0[2]}]
# set_property -dict {PACKAGE_PIN P18 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4} [get_ports {ad9363_rx_p0[3]}]
# set_property -dict {PACKAGE_PIN U15 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4} [get_ports {ad9363_rx_p0[4]}]
# set_property -dict {PACKAGE_PIN P16 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4} [get_ports {ad9363_rx_p0[5]}]
# set_property -dict {PACKAGE_PIN U17 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4} [get_ports {ad9363_rx_p0[6]}]
# set_property -dict {PACKAGE_PIN V18 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4} [get_ports {ad9363_rx_p0[7]}]
# set_property -dict {PACKAGE_PIN T15 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4} [get_ports {ad9363_rx_p0[8]}]
# set_property -dict {PACKAGE_PIN V13 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4} [get_ports {ad9363_rx_p0[9]}]
# set_property -dict {PACKAGE_PIN W13 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4} [get_ports {ad9363_rx_p0[10]}]
# set_property -dict {PACKAGE_PIN U12 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4} [get_ports {ad9363_rx_p0[11]}]

# ---- AD9363 data port, TX group on J11 (PIN3-30, BANK35):
#      fb_clk / tx_frame / tx_p0[11:0] ----
# set_property -dict {PACKAGE_PIN F17 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4} [get_ports ad9363_fb_clk]
# set_property -dict {PACKAGE_PIN F20 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4} [get_ports ad9363_tx_frame]
# set_property -dict {PACKAGE_PIN G20 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4} [get_ports {ad9363_tx_p0[0]}]
# set_property -dict {PACKAGE_PIN H18 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4} [get_ports {ad9363_tx_p0[1]}]
# set_property -dict {PACKAGE_PIN L20 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4} [get_ports {ad9363_tx_p0[2]}]
# set_property -dict {PACKAGE_PIN M20 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4} [get_ports {ad9363_tx_p0[3]}]
# set_property -dict {PACKAGE_PIN K18 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4} [get_ports {ad9363_tx_p0[4]}]
# set_property -dict {PACKAGE_PIN J19 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4} [get_ports {ad9363_tx_p0[5]}]
# set_property -dict {PACKAGE_PIN H20 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4} [get_ports {ad9363_tx_p0[6]}]
# set_property -dict {PACKAGE_PIN L17 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4} [get_ports {ad9363_tx_p0[7]}]
# set_property -dict {PACKAGE_PIN M18 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4} [get_ports {ad9363_tx_p0[8]}]
# set_property -dict {PACKAGE_PIN D20 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4} [get_ports {ad9363_tx_p0[9]}]
# set_property -dict {PACKAGE_PIN E19 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4} [get_ports {ad9363_tx_p0[10]}]
# set_property -dict {PACKAGE_PIN G18 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4} [get_ports {ad9363_tx_p0[11]}]

# ---- AD9363 SPI (slow config port, <= 20 MHz; J10 PIN31-36).
#      MISO input needs no SLEW/DRIVE ----
# set_property -dict {PACKAGE_PIN T10 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4} [get_ports ad9363_spi_sclk]
# set_property -dict {PACKAGE_PIN A20 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4} [get_ports ad9363_spi_mosi]
# set_property -dict {PACKAGE_PIN C20 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4} [get_ports ad9363_spi_csn]
# set_property -dict {PACKAGE_PIN B20 IOSTANDARD LVCMOS33}                    [get_ports ad9363_spi_miso]

# ---- AD9363 control (J11 PIN31-35): hardware reset + ENSM pin control ----
# set_property -dict {PACKAGE_PIN H17 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4} [get_ports ad9363_resetn]
# set_property -dict {PACKAGE_PIN G15 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4} [get_ports ad9363_enable]
# set_property -dict {PACKAGE_PIN J14 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4} [get_ports ad9363_txnrx]

# ---- Reserved debug pins: recover from the header ground-interleave pool
#      (e.g. J10 PIN34 = B19, J11 PIN36 = K14); log the change in
#      docs/pins.md before use ----
