# =============================================================================
# SDC Constraints: mac_unit (Phase 5 V8 — per-module)
# Technology: generic 28 nm (NangateOpenCellLibrary proxy where available)
# Target: 500 MHz (REQ-U-001, REQ-P-003). Period = 2.000 ns.
# =============================================================================

# ----- Clock definition (REQ-U-001.AC-2) ------------------------------------
create_clock -name clk -period 2.000 -waveform {0.000 1.000} [get_ports clk]

# Clock uncertainty (budget for jitter + CTS skew)
set_clock_uncertainty -setup 0.150 [get_clocks clk]
set_clock_uncertainty -hold  0.050 [get_clocks clk]

# Clock transition (slew) — conservative 28 nm value
set_clock_transition 0.100 [get_clocks clk]

# ----- Reset pin (async-assert / sync-deassert per REQ-F-007) ---------------
# rst_n is treated as an async input for STA; external synchronizer per REQ-U-005
set_false_path -from [get_ports rst_n]

# ----- Input delays (60% of period, conservative) ---------------------------
# Assume upstream launches outputs 1.2 ns after clk edge
set INPUT_DELAY 1.200
set_input_delay -clock clk $INPUT_DELAY [get_ports i_clr]
set_input_delay -clock clk $INPUT_DELAY [get_ports i_valid]
set_input_delay -clock clk $INPUT_DELAY [get_ports {i_a[*]}]
set_input_delay -clock clk $INPUT_DELAY [get_ports {i_b[*]}]

# ----- Output delays (40% of period budget for downstream capture) ----------
set OUTPUT_DELAY 0.800
set_output_delay -clock clk $OUTPUT_DELAY [get_ports o_valid]
set_output_delay -clock clk $OUTPUT_DELAY [get_ports {o_acc[*]}]
set_output_delay -clock clk $OUTPUT_DELAY [get_ports o_ovf]

# ----- Drive / load ---------------------------------------------------------
# Conservative external driver/load; refine with pad models when available.
set_driving_cell -lib_cell BUF_X2 -pin Z [all_inputs]
set_load 0.010 [all_outputs]

# ----- Max fanout / transition ----------------------------------------------
set_max_fanout    16   [current_design]
set_max_transition 0.250 [current_design]

# End of mac_unit.sdc
