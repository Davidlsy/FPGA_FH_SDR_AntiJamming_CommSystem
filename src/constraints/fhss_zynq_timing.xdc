# =============================================================================
# fhss_zynq : main timing constraints (4 clock domains + async groups)
# -----------------------------------------------------------------------------
# File    : src/constraints/fhss_zynq_timing.xdc   (board-independent, reusable)
# Pair    : board/fhss_zynq_pins.xdc        (pins/IO standard, one per board)
# Tool    : Vivado ML 2021.2 - xc7z020clg400-2 (Zynq-7000)
# Encoding: pure ASCII English comments -- Vivado on Chinese Windows reads
#           BOM-less files as GBK and UTF-8 Chinese comments garble; also
#           required by the English open-source repo rule (3.3.3.3)
#
# Maintenance rules:
#   - This file holds clocks / exceptions / config properties ONLY; pins go
#     to the pins file; every change goes through review
#   - Constraint anchors = fhss_top port names and PS7/MMCM instance names;
#     renaming any of them requires syncing this file
#
# PL clock domain overview:
#   A  baseband main   onboard 50 MHz single-ended osc (U18) -> MMCM ->
#                      ~61.44 MHz, full TX/RX DSP chain
#   B  control plane   PS FCLK_CLK0 100 MHz, axi_regs / spi_master / FSMs
#   C  RF sampling     AD9363 DATA_CLK (= sample rate), ad9363_if data port
#   D  SPI pseudo      <= 20 MHz: SCLK is a divided output of domain B, not
#                      an independent fabric clock, see [4]
#   NOTE: PS GEM 125 MHz is NOT in this file: the PHY sits on PS MIO (board
#     hard condition C2), RGMII timing lives entirely in the PS domain and is
#     guaranteed by the PS7 configuration (RX delay via rgmii-id, solved at
#     the PS / device-tree level). Enable the fallback block [7] only if
#     forced onto a PL-side PHY / EMIO.
#   NOTE (correction 2026-09-16): the AX7Z020B has a 50 MHz single-ended PL
#     oscillator (U18, BANK34, LVCMOS33) per the ALINX official user manual
#     sec 2.5 -- the earlier "200 MHz differential pair" assumption is void;
#     port names sys_clk_p/n renamed to sys_clk accordingly.
#
# Staged enabling (current file state = stage 1, loadable as-is, all other
# sections fully commented):
#   - Stage 1 (pure-PL smoke, no PS7/AD9363 ports): only [1] [6] active.
#     If [2][3][4][5] were loaded while their anchor ports are missing, the
#     empty get_ports/get_clocks matches would error out immediately -- that
#     is why they stay commented (a latent pitfall of the previous template
#     revision, now fixed).
#   - Stage 2 (PS BD built, axi_regs wired): uncomment [2] and [5B] (2-group)
#   - Stage 3 (ad9363_if wired): uncomment [3] [4], switch [5B] to [5A]
#     (full 3-group version)
# =============================================================================


# -----------------------------------------------------------------------------
# [1] Onboard 50 MHz single-ended oscillator (U18, BANK34)
#     Drives logic directly in the smoke stage; once the MMCM is inserted,
#     the baseband clock is auto-derived from this constraint (never
#     create_clock an MMCM output manually)
# -----------------------------------------------------------------------------
create_clock -period 20.000 -name sys_clk_50m [get_ports sys_clk]

# Baseband 61.44 MHz pitfall note (Clocking Wizard parameters):
#   61.44 MHz cannot be synthesized exactly from 50 MHz (1.2288 is not on
#   the MMCM fractional grid, mathematically unreachable). Engineering
#   practice: M=29.5, D=2, O=12 -> VCO 737.5 MHz -> 61.4583 MHz (+299 ppm),
#   same order as crystal tolerance, absorbed by the receiver CFO loop;
#   configure in Clocking Wizard, record in docs/report/env.md, lock after review
#   (M step 0.125, D must be an integer).


# -----------------------------------------------------------------------------
# [2] PS FCLK_CLK0 100 MHz -- uncomment at stage 2 (after the PS BD is built)
#     Auto-constrained by the PS7 IP from the PS configuration; never
#     create_clock it manually; the handle below only feeds grouping in [5].
#     Adjust the instance name to the actual Block Design.
# -----------------------------------------------------------------------------
# set fclk_pins [get_pins -hierarchical -filter {NAME =~ *ps7*FCLK_CLK0*}]
# set clk_axi   [get_clocks -of_objects $fclk_pins]
# If FCLK_CLK1/2/3 are used (e.g. a dedicated debug clock), widen the filter
# to *ps7*FCLK_CLK*


# -----------------------------------------------------------------------------
# [3] AD9363 DATA_CLK (CMOS mode, frequency = sample rate; default derated
#     20 MSPS) -- uncomment at stage 3; changing the sample rate requires
#     changing the period in lockstep: 10 MSPS -> 100.000.
#     Step-up plan: see gate BV-02.
# -----------------------------------------------------------------------------
# create_clock -period 50.000 -name clk_rf_data [get_ports ad9363_data_clk]

# AD9363 parallel data port I/O timing (DDR; bus names / widths to match the
# actual ad9363_if ports; values = datasheet I/O timing table + ribbon cable
# / adapter margin, backfill after BV-02 calibration):
# set_input_delay  -clock clk_rf_data -max <TsU_max> [get_ports {ad9363_rx_p0[*]}]
# set_input_delay  -clock clk_rf_data -min <tH_min>  [get_ports {ad9363_rx_p0[*]}]
# set_input_delay  -clock clk_rf_data -clock_falling -max <TsU_max> [get_ports {ad9363_rx_p0[*]}]
# set_input_delay  -clock clk_rf_data -clock_falling -min <tH_min>  [get_ports {ad9363_rx_p0[*]}]
# set_output_delay -clock clk_rf_data -max <tCO_max> [get_ports {ad9363_tx_p0[*]}]
# set_output_delay -clock clk_rf_data -min <tCO_min> [get_ports {ad9363_tx_p0[*]}]
# set_output_delay -clock clk_rf_data -clock_falling -max/-min ... same, second edge


# -----------------------------------------------------------------------------
# [4] SPI <= 20 MHz -- uncomment at stage 3. Pseudo-domain handling (no
#     independent fabric clock, no create_clock):
#     Architecture: spi_master runs in domain B (FCLK); SCLK is a counter-
#     divided output; design guarantee: MOSI/CSN change on the SCLK falling
#     edge, AD9363 samples on the rising edge; MISO is double-FF synchronized
#     then sampled in domain B (25 ns half-period margin at 20 MHz is
#     enough; bring-up strategy: get it working at 1 MHz first, then step
#     up -- same as the GOWIN-era P2-S2B procedure)
# -----------------------------------------------------------------------------
# set_false_path -from [get_ports ad9363_spi_miso]
# set_false_path -to   [get_ports {ad9363_spi_sclk ad9363_spi_mosi ad9363_spi_csn}]
# Keep the double-FF synchronizer from being optimized apart (hierarchical
# names to match the actual design):
# set_property ASYNC_REG true [get_cells -hierarchical -filter {NAME =~ *miso_sync*}]


# -----------------------------------------------------------------------------
# [5] Asynchronous clock groups -- set_clock_groups beats per-path
#     set_false_path: bidirectional (a false_path easily misses one
#     direction), auto-covers derived clocks, one line replaces six.
#     Physical basis: board oscillator / PS IOPLL / AD9363 clock are three
#     physically independent, unrelated sources.
#
# [5A] Full 3-group version (stage 3, enable together with [3]):
# set_clock_groups -asynchronous \
#   -group [get_clocks -include_generated_clocks sys_clk_50m] \
#   -group $clk_axi \
#   -group [get_clocks clk_rf_data]
#
# [5B] 2-group version (stage 2: only sys_clk x FCLK crossings exist):
# set_clock_groups -asynchronous \
#   -group [get_clocks -include_generated_clocks sys_clk_50m] \
#   -group $clk_axi
#
# WARNING board-swap note (PYNQ-Z2 style: no independent PL oscillator, MMCM
#   derived from FCLK -- then baseband and FCLK are related sources, never
#   cut them from each other; merge both into one group and cut only against
#   clk_rf_data):
# set_clock_groups -asynchronous \
#   -group [get_clocks -of_objects $fclk_pins -include_generated_clocks] \
#   -group [get_clocks clk_rf_data]
#
# Equivalent legacy form (reference only; one set_clock_groups line =
# 3 groups x 2 directions = 6 false_path lines, and it never misses derived
# clocks. Do not enable together with the forms above):
# set_false_path -from [get_clocks -include_generated_clocks sys_clk_50m] -to $clk_axi
# set_false_path -from $clk_axi -to [get_clocks -include_generated_clocks sys_clk_50m]
# set_false_path -from [get_clocks -include_generated_clocks sys_clk_50m] -to [get_clocks clk_rf_data]
# set_false_path -from [get_clocks clk_rf_data] -to [get_clocks -include_generated_clocks sys_clk_50m]
# set_false_path -from $clk_axi -to [get_clocks clk_rf_data]
# set_false_path -from [get_clocks clk_rf_data] -to $clk_axi
# -----------------------------------------------------------------------------


# -----------------------------------------------------------------------------
# [6] Config / bitstream properties (standard closing for 7-series 3.3V
#     config bank, silences the DRC warnings)
# -----------------------------------------------------------------------------
set_property CFGBVS VCCO                   [current_design]
set_property CONFIG_VOLTAGE 3.3            [current_design]
set_property BITSTREAM.GENERAL.COMPRESS true [current_design]


# -----------------------------------------------------------------------------
# [7] Fallback block: enable ONLY if forced onto a PL-side PHY / EMIO (keep
#     commented in the normal architecture). RGMII 125 MHz DDR (IDELAY/
#     ODELAY and IODELAY_GROUP handled separately, see UG471):
# create_clock -period 8.000 -name clk_gem_rxc [get_ports gem_rgmii_rx_clk]
# set_input_delay  -clock clk_gem_rxc -max <..> [get_ports {gem_rgmii_rxd[*]}]
# set_input_delay  -clock clk_gem_rxc -clock_falling -min <..> [get_ports {gem_rgmii_rxd[*]}]
# set_output_delay -clock clk_gem_rxc -max <..> [get_ports {gem_rgmii_txd[*]}]
# -----------------------------------------------------------------------------


# =============================================================================
# Sign-off self-checks (run after every implementation, also bake into the
# build/ one-key Tcl):
#   1. report_timing_summary -> WNS >= 0 for every domain, no intra-domain
#      violations
#   2. report_cdc -> no Unsafe crossings; every crossing must map to an
#      ad9363_if async FIFO or a double-FF synchronizer -- constraints only
#      stop STA from analyzing, they do NOT generate synchronizers for you!
#   3. Exception audit: false_path / clock_groups are allowed ONLY on the
#      inter-group paths of [5]; an intra-domain path being cut = a broken
#      constraint, roll back immediately
# =============================================================================
