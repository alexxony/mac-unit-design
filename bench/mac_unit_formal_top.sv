// =============================================================================
// Formal wrapper: mac_unit_formal_top
// Re-expresses the 4 SVA properties from sim/sva/mac_unit_sva.sv in a Yosys
// read_verilog -formal compatible subset (no `property` blocks; uses inline
// assert/assume + regs to encode temporal relations manually).
//
// This is equivalent to the original SVA under BMC because read_verilog -formal
// does not support `property ... endproperty`. The four proved facts are:
//   p_latency_valid_2cyc: i_valid => 2 cycles later o_valid OR i_clr was asserted
//   p_clr_zeros:          i_clr=1 in cycle T => next-cycle outputs all 0
//   p_ovf_sticky:         (o_ovf && !i_clr) => next o_ovf = 1
//   p_reset_quiescence:   !rst_n => outputs 0
// =============================================================================

`default_nettype none

module mac_unit_formal_top (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        i_clr,
    input  logic        i_valid,
    input  logic [7:0]  i_a,
    input  logic [7:0]  i_b
);

    logic        o_valid;
    logic [31:0] o_acc;
    logic        o_ovf;

    mac_unit u_dut (
        .clk    (clk),
        .rst_n  (rst_n),
        .i_clr  (i_clr),
        .i_valid(i_valid),
        .i_a    (i_a),
        .i_b    (i_b),
        .o_valid(o_valid),
        .o_acc  (o_acc),
        .o_ovf  (o_ovf)
    );

    // ---- Reset sequence assume -------------------------------------------
    // The SVA properties are all "disable iff (!rst_n)". In BMC, to mirror the
    // semantics of "properties evaluate only after reset deasserts", we
    // assume rst_n is held low for the first cycle then deasserted. All
    // temporal checks below only fire when rst_n==1.
    //
    // After reset, rst_n remains high for the rest of the trace (no async
    // reset re-assertion during functional proof).
    reg rst_n_past;
    initial rst_n_past = 1'b0;
    always @(posedge clk) rst_n_past <= rst_n;

    // Force cycle 0 to be reset-asserted (!rst_n), cycle >=1 to be deasserted.
    // This establishes a clean post-reset baseline.
    reg [3:0] cycle_cnt;
    initial cycle_cnt = 4'd0;
    always @(posedge clk) if (cycle_cnt != 4'hF) cycle_cnt <= cycle_cnt + 1'b1;

    always @(*) begin
        if (cycle_cnt == 4'd0) assume (!rst_n);
        else                   assume ( rst_n);
    end

    // ---- History registers for temporal properties -------------------------
    logic        ivalid_d1, ivalid_d2;
    logic        iclr_d1,   iclr_d2;
    logic        ovf_d1;
    logic        iclr_seen_in_window; // any clr in last 2 cycles

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ivalid_d1 <= 1'b0;
            ivalid_d2 <= 1'b0;
            iclr_d1   <= 1'b0;
            iclr_d2   <= 1'b0;
            ovf_d1    <= 1'b0;
        end else begin
            ivalid_d1 <= i_valid;
            ivalid_d2 <= ivalid_d1;
            iclr_d1   <= i_clr;
            iclr_d2   <= iclr_d1;
            ovf_d1    <= o_ovf;
        end
    end

    // "in window" = i_clr was 1 in any of cycles T+1 or T+2 after the i_valid at T.
    // Check at cycle T+2 (current cycle): was i_clr asserted at current, at T+1 (iclr_d1),
    // or at T (iclr_d2)? If yes => output may legally be 0.
    assign iclr_seen_in_window = i_clr | iclr_d1 | iclr_d2;

    // -----------------------------------------------------------------------
    // Reset quiescence: while !rst_n, outputs are 0
    // (redundant with flop reset values but proves the contract)
    // -----------------------------------------------------------------------
    // Using inline assert for Yosys read_verilog -formal
    always @(*) begin
        if (!rst_n) begin
            a_reset_quiescence: assert (o_acc == 32'h0 && o_ovf == 1'b0 && o_valid == 1'b0);
        end
    end

    // -----------------------------------------------------------------------
    // All other properties are edge-triggered — assert after the positive
    // edge in a clocked always block, only when rst_n is asserted.
    // Use $past-free formulation via the history registers above.
    // -----------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst_n) begin
            // ---- p_clr_zeros: i_clr at T-1 => outputs == 0 at T ------------
            if (iclr_d1) begin
                a_clr_zeros: assert (o_acc == 32'h0 && o_ovf == 1'b0 && o_valid == 1'b0);
            end

            // ---- p_ovf_sticky: (o_ovf && !i_clr) at T-1 => o_ovf==1 at T ---
            if (ovf_d1 && !iclr_d1) begin
                a_ovf_sticky: assert (o_ovf == 1'b1);
            end

            // ---- p_latency_valid_2cyc ------------------------------------
            // i_valid at T-2 => o_valid at T OR i_clr was asserted in [T-1..T]
            // (The original property disabled on !rst_n; guarded by outer if.)
            if (ivalid_d2) begin
                a_latency_valid_2cyc: assert (o_valid || i_clr || iclr_d1);
            end
        end
    end

    // ----- Cover properties (functional confidence) ------------------------
    always @(posedge clk) begin
        if (rst_n) begin
            c_ovf_reachable:   cover (o_ovf);
            c_o_valid_rise:    cover (o_valid && !$past(o_valid));
        end
    end

endmodule

`default_nettype wire
