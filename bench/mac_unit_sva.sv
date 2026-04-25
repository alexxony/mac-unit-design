// =============================================================================
// SVA Bind Module: mac_unit_sva
// REQ-U-003: Sibling .sv bound via `bind mac_unit mac_unit_sva u_sva (.*);`
// Properties cover: latency (REQ-P-002), clear semantics (REQ-F-004/004a),
//                    wrap (REQ-F-006), sticky overflow (REQ-F-006),
//                    reset quiescence (REQ-F-007), registered output (REQ-F-008).
// Phase 4 deliverable: skeleton + named properties — Phase 5 runs SymbiYosys
// BMC depth >= 20 cycles.
// =============================================================================

`default_nettype none

module mac_unit_sva (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        i_clr,
    input  logic        i_valid,
    input  logic [7:0]  i_a,
    input  logic [7:0]  i_b,
    input  logic        o_valid,
    input  logic [31:0] o_acc,
    input  logic        o_ovf
);

    // ----- Latency: i_valid leads to o_valid in 2 cycles unless squashed by i_clr ----
    property p_latency_valid_2cyc;
        @(posedge clk) disable iff (!rst_n)
            i_valid |-> ##2 (o_valid || $past(i_clr, 0));
    endproperty
    a_latency_valid_2cyc: assert property (p_latency_valid_2cyc);

    // ----- Clear semantics: i_clr causes acc=0, ovf=0, valid=0 in next cycle -------
    property p_clr_zeros;
        @(posedge clk) disable iff (!rst_n)
            i_clr |=> (o_acc == 32'h0 && o_ovf == 1'b0 && o_valid == 1'b0);
    endproperty
    a_clr_zeros: assert property (p_clr_zeros);

    // ----- Sticky overflow: once set without clr, ovf stays set --------------------
    property p_ovf_sticky;
        @(posedge clk) disable iff (!rst_n)
            (o_ovf && !i_clr) |=> o_ovf;
    endproperty
    a_ovf_sticky: assert property (p_ovf_sticky);

    // ----- Reset quiescence: while !rst_n, all outputs are 0 -----------------------
    property p_reset_quiescence;
        @(posedge clk) (!rst_n) |-> (o_acc == 32'h0 && o_ovf == 1'b0 && o_valid == 1'b0);
    endproperty
    a_reset_quiescence: assert property (p_reset_quiescence);

    // ----- Wrap semantics (functional cover, not assert): hit overflow at least once ---
    cover property (@(posedge clk) disable iff (!rst_n) o_ovf);

    // ----- Output registered (REQ-F-008): outputs do not change without posedge ----
    // SVA cannot directly assert "registered"; this is verified by lint NETLIST_OUTPUT_NOT_REG.
    // Provide a coverage point: o_valid only toggles at posedge clk.
    cover property (@(posedge clk) disable iff (!rst_n) o_valid && !$past(o_valid));

    // ----- No-clr accumulate increments by s1_product when s1_valid was set -------
    // (Requires whitebox visibility — Phase 5 may bind to internal s1_product.)
    // Skeleton placeholder to be expanded in Phase 5 with internal probes.

endmodule

`default_nettype wire
