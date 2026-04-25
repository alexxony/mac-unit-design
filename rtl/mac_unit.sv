// =============================================================================
// Module : mac_unit
// Source : docs/phase-3-uarch/mac_unit.md (P3 normative spec)
// REQs   : REQ-F-001..009, REQ-A-003/007/009, REQ-P-001/002, REQ-U-001..005
// =============================================================================
// 8x8 unsigned MAC with 32-bit accumulator. 2-stage pipeline.
//   Stage 1: s1_product = i_a * i_b (gated by i_valid, REQ-U-002)
//            s1_valid   = i_valid
//   Stage 2: o_acc/o_ovf updated from sum33 = o_acc + s1_product
//            o_valid    = ~i_clr & s1_valid (REQ-A-007 acceptance)
//   i_clr   : synchronous, priority over i_valid (REQ-F-004/004a)
//   o_ovf   : sticky, cleared only by i_clr or rst_n (REQ-F-006)
// Single clock `clk`, single async-assert/sync-deassert reset `rst_n`.
// External rst_n synchronization required (REQ-U-005, REQ-F-007).
// No submodule hierarchy (REQ-A-009).
// =============================================================================

`default_nettype none

module mac_unit (
    // Clock and reset (no i_/o_ prefix per convention)
    input  logic        clk,
    input  logic        rst_n,

    // Control inputs
    input  logic        i_clr,
    input  logic        i_valid,

    // Operand inputs (8-bit unsigned)
    input  logic [7:0]  i_a,
    input  logic [7:0]  i_b,

    // Outputs (driven directly from flops, REQ-F-008)
    output logic        o_valid,
    output logic [31:0] o_acc,
    output logic        o_ovf
);

    // -------------------------------------------------------------------------
    // Stage 1 pipeline registers
    // -------------------------------------------------------------------------
    logic [15:0] s1_product;
    logic        s1_valid;

    // -------------------------------------------------------------------------
    // Combinational equations (mirrors §7 of mac_unit.md)
    // -------------------------------------------------------------------------
    logic [15:0] prod_c;       // 8x8 unsigned multiply
    logic [32:0] sum33;        // 33-bit add to capture carry-out
    logic        ovf_this;     // carry-out of this cycle's add
    logic        acc_add_en;   // accumulate enable (s1_valid AND NOT i_clr)
    logic [31:0] acc_nxt;      // next accumulator value
    logic        ovf_nxt;      // next sticky overflow value
    logic        ovld_nxt;     // next o_valid value

    always_comb begin
        prod_c     = i_a * i_b;
        sum33      = {1'b0, o_acc} + {17'b0, s1_product};
        ovf_this   = sum33[32];
        acc_add_en = s1_valid & ~i_clr;

        // i_clr has priority over accumulate
        if (i_clr) begin
            acc_nxt = 32'h0000_0000;
            ovf_nxt = 1'b0;
        end else if (acc_add_en) begin
            acc_nxt = sum33[31:0];
            ovf_nxt = o_ovf | ovf_this;  // sticky
        end else begin
            acc_nxt = o_acc;
            ovf_nxt = o_ovf;
        end

        // o_valid: i_valid delayed by 2, suppressed by i_clr at Stage 2
        ovld_nxt = ~i_clr & s1_valid;
    end

    // -------------------------------------------------------------------------
    // Stage 1 sequential: gated product capture (REQ-U-002), valid pass-through
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_product <= 16'h0000;
            s1_valid   <= 1'b0;
        end else begin
            // Gated update: hold when i_valid=0 (REQ-U-002.AC-1 literal pattern)
            s1_product <= i_valid ? prod_c : s1_product;
            s1_valid   <= i_valid;
        end
    end

    // -------------------------------------------------------------------------
    // Stage 2 sequential: accumulator, sticky overflow, output valid
    // All outputs driven directly from these flops (REQ-F-008)
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            o_acc   <= 32'h0000_0000;
            o_ovf   <= 1'b0;
            o_valid <= 1'b0;
        end else begin
            o_acc   <= acc_nxt;
            o_ovf   <= ovf_nxt;
            o_valid <= ovld_nxt;
        end
    end

endmodule

`default_nettype wire
