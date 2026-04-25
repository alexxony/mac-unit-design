# Microarchitecture Spec: `mac_unit` (Phase 3)

- Date: 2026-04-24
- Authority: 3 (P3 μArch)
- Upstream: `docs/phase-1-research/iron-requirements.json` (P1, authority 1),
  `docs/phase-2-architecture/iron-requirements.json` (P2, authority 2),
  `docs/phase-2-architecture/architecture.md`
- Status: Locked after P3 review

## 1. Module Decomposition

`mac_unit` is a **single flat RTL module** with **no submodule hierarchy** (REQ-A-009).
The 2-stage pipeline is realized inside this single module by two `always_ff` blocks
(one per stage) plus the combinational next-state logic of Stage 2.

Rationale for single-module decomposition:
- Total cell budget is ~500–700 cells (per architecture.md §8). At this size, an
  internal hierarchy adds zero verification value and obstructs synthesis flattening.
- REQ-A-009 explicitly forbids submodule instantiation.
- The two-stage pipeline is fully described by 5 named registers; their bind to
  Stage 1 vs Stage 2 is documented in §5.

### 1.1 Logical sub-blocks (NOT separate modules — concept-only partition)

| Sub-block         | Realized by                                           | Clock domain | Purpose                                  |
|-------------------|-------------------------------------------------------|--------------|------------------------------------------|
| `mul_path`        | `prod_c = i_a * i_b` (combinational) + `s1_product` flop | `clk`        | 8x8 unsigned multiply + Stage 1 register |
| `valid_pipe`      | `s1_valid` flop, `o_valid` flop                       | `clk`        | i_valid delay-by-2 with i_clr suppression |
| `acc_path`        | `sum33` adder + `o_acc` flop                          | `clk`        | 32-bit wrap accumulate                   |
| `ovf_logic`       | `sum33[32]` carry capture + `o_ovf` sticky flop       | `clk`        | Sticky overflow flag                     |
| `ctrl`            | `acc_nxt` / `ovf_nxt` / `ovld_nxt` mux logic          | `clk`        | i_clr priority, valid-gating             |

All sub-blocks share the single clock domain `clk` and the single reset `rst_n`.

## 2. Clock Domain Assignment

- **Single clock domain**: `clk` (no multi-clock, no generated clock, no clock gating
  proposed at P3 — see §10 ADR notes).
- **Single reset**: `rst_n` (active-low, async-assert, sync-deassert per REQ-F-007).
- **External synchronization assumption**: rst_n synchronization is the integrator's
  responsibility (per REQ-F-007 acceptance criteria and OPEN-2-005 resolution
  option-a). `mac_unit` does NOT instantiate a reset synchronizer — doing so would
  violate REQ-A-009 (no submodule hierarchy).

`docs/phase-3-uarch/clock-domain-map.md` formally records this single-domain decision.

## 3. Protocol Assignment

| Interface | Protocol         | Justification                                              |
|-----------|------------------|------------------------------------------------------------|
| Input     | **Valid-only** (no ready) | REQ-A-007 forbids back-pressure. Throughput is 1 beat/cycle (REQ-P-001) so flow control is unnecessary. |
| Output    | **Valid-only** (no ready) | REQ-F-009 freezes the port list (no ready signal); consumer is assumed non-stalling. |
| Clear     | **Synchronous level** (i_clr) | REQ-F-004 mandates single-cycle clear with priority over i_valid. No handshake required. |

`docs/phase-3-uarch/protocol-assignments.md` formally records protocol decisions.

## 4. Design Partitioning

- **Pipeline stages**: exactly 2 (REQ-A-003).
- **Resource sharing**: none (single multiplier, single adder).
- **Parallelism**: 1 MAC/cycle (REQ-P-001). No SIMD, no banked compute.
- **No clock gating** at P3 (revisit at P5 if utilization data warrants).

## 5. Register / SRAM / FSM Allocation

### 5.1 Storage type decision (per Storage Selection Criteria)

| Element        | Bits | Ports | Type            | Rationale                                  |
|----------------|------|-------|-----------------|--------------------------------------------|
| `s1_product`   | 16   | 1R/1W | **Flip-flop**   | <256 bits → register array (16 bits)       |
| `s1_valid`     | 1    | 1R/1W | **Flip-flop**   | Single bit                                 |
| `o_acc`        | 32   | 1R/1W | **Flip-flop**   | <256 bits → register array (32 bits)       |
| `o_ovf`        | 1    | 1R/1W | **Flip-flop**   | Single bit                                 |
| `o_valid`      | 1    | 1R/1W | **Flip-flop**   | Single bit                                 |
| **Total**      | 51   | —     | All flops       | No SRAM macro instantiated                 |

No SRAM wrappers required at this scale.

### 5.2 Pipeline register placement

| Register       | Stage   | Update style                                      | Reset value |
|----------------|---------|---------------------------------------------------|-------------|
| `s1_product`   | Stage 1 | `i_valid ? prod_c : s1_product` (gated; OPEN-2-002 option-a) | 16'h0000   |
| `s1_valid`     | Stage 1 | `i_valid` (always update)                          | 1'b0        |
| `o_acc`        | Stage 2 | `acc_nxt` (clr-priority mux)                       | 32'h00000000 |
| `o_ovf`        | Stage 2 | `ovf_nxt` (clr-priority sticky)                    | 1'b0        |
| `o_valid`      | Stage 2 | `ovld_nxt = ~i_clr & s1_valid`                     | 1'b0        |

### 5.3 Config registers

**None.** ACC_WIDTH is hard-coded 32 (REQ-A-008). No mode parameters.

### 5.4 FSM allocation

**No explicit FSM.** All control is implemented as flat next-state combinational logic
(`acc_nxt`, `ovf_nxt`, `ovld_nxt`). The "state" is the accumulator value plus the sticky
overflow bit, which are pure data registers — not control state.

## 6. Inter / Intra-Module Pipeline

### 6.1 Pipeline diagram

See `reviews/phase-3-uarch/pipeline-diagram.md` (Mermaid). Summary:

- Stage 0 (combinational input): `i_a`, `i_b`, `i_valid`, `i_clr` consumed combinationally.
- Stage 1 (1 cycle): `s1_product = i_a * i_b` registered; `s1_valid = i_valid` registered.
- Stage 2 (1 cycle): `sum33 = {1'b0, o_acc} + {17'b0, s1_product}`; `o_acc`, `o_ovf`,
  `o_valid` registered with i_clr-priority mux.

### 6.2 Hazard analysis

- **No structural hazard**: each stage has dedicated registers and arithmetic.
- **No data hazard**: there is no read-after-write conflict; the accumulator is updated
  by Stage 2 from the PRIOR cycle's `s1_product` (RTL "read old reg" semantics).
- **No control hazard**: i_clr is consumed in the SAME cycle at Stage 2 (not pipelined).
  Behaviour is fully specified by REQ-A-005 (clear priority) and REQ-A-007 (valid gating).

### 6.3 Backpressure

**None.** No `o_ready` is exposed (REQ-A-007). Throughput contract is 1 MAC/cycle
unconditionally (REQ-P-001).

### 6.4 Throughput invariant verification

`rate_per_cycle × clock_freq ≥ target_throughput`
- rate_per_cycle = 1 MAC/cycle
- clock_freq = 500 MHz (committed below)
- target_throughput = 1 MAC/cycle (REQ-P-001) → **500 M MAC/s**
- Invariant holds: 1 × 500 MHz = 500 MMAC/s ≥ 1 MAC/cycle. **PASS.**

## 7. Detailed Combinational Equations

```
prod_c       = i_a * i_b;                                 // 16-bit unsigned
sum33        = {1'b0, o_acc} + {17'b0, s1_product};       // 33-bit
ovf_this     = sum33[32];                                  // carry-out
acc_add_en   = s1_valid & ~i_clr;                          // gate + clr priority
acc_nxt      = i_clr      ? 32'h00000000
             : acc_add_en ? sum33[31:0]
             :              o_acc;
ovf_nxt      = i_clr                       ? 1'b0
             : (acc_add_en & ovf_this)     ? 1'b1
             :                               o_ovf;
ovld_nxt     = ~i_clr & s1_valid;
```

These equations are normative. RTL (P4) MUST implement them literally.

## 8. Signal Naming (compliance check)

| Original    | Phase 3 spec | Convention check                              |
|-------------|--------------|-----------------------------------------------|
| Inputs      | `i_clr`, `i_valid`, `i_a`, `i_b` | `i_` prefix ✓                |
| Outputs     | `o_valid`, `o_acc`, `o_ovf`      | `o_` prefix ✓                |
| Clock       | `clk`                            | single domain ✓              |
| Reset       | `rst_n`                          | active-low ✓                 |
| Internal    | `s1_product`, `s1_valid`         | snake_case ✓                 |
| Wires       | `prod_c`, `sum33`, `ovf_this`, `acc_add_en`, `acc_nxt`, `ovf_nxt`, `ovld_nxt` | snake_case ✓ |
| Type usage  | `logic` only                     | `logic` only ✓ (no reg/wire) |
| Instances   | none required                    | n/a                          |
| Parameters  | none                             | n/a                          |

## 9. OPEN-2-* Resolutions (μArch decisions promoted to REQ-U-*)

| OPEN-ID    | Decision | Rationale | New iron REQ |
|------------|----------|-----------|--------------|
| OPEN-2-001 | option-a (500 MHz / generic 28 nm) | Confirms REQ-P-003 provisional. 2-stage pipeline has ample margin. No tool/library data exists in this environment to justify a higher target. Conservative choice. | REQ-U-001 |
| OPEN-2-002 | option-a (gated update) | Saves dynamic power on invalid cycles at zero area cost (synthesizes to same flop with mux in front). Avoids ICG verification burden of option-c. | REQ-U-002 |
| OPEN-2-003 | option-b (sibling `mac_unit_sva.sv` bound via `bind`) | Project preferred per OPEN-2-003 context. Compatible with both simulator (cocotb) and SymbiYosys formal flows. Keeps RTL clean. | REQ-U-003 |
| OPEN-2-004 | option-a (cocotb + Python ref model wrapping the C model) | Fastest iteration for a single-module unit; refc/ already provides the C reference (mac_unit.c) which can be wrapped via cffi or re-implemented in Python for parity. cocotb is already in project dependencies. | REQ-U-004 |
| OPEN-2-005 | option-a (external synchronizer required; documented assumption) | Matches REQ-F-007 acceptance criteria literally and respects REQ-A-009 (no submodule hierarchy). | REQ-U-005 |

## 10. ADR Anchors

The following 5 decisions are documented as ADRs in `docs/decisions/`:
- ADR-001: Target frequency commit (500 MHz) — see OPEN-2-001
- ADR-002: Stage-1 enable style (gated update) — see OPEN-2-002
- ADR-003: SVA bind strategy — see OPEN-2-003
- ADR-004: Unit testbench framework (cocotb) — see OPEN-2-004
- ADR-005: External reset synchronization contract — see OPEN-2-005

## 11. Verification Anchors (handed to P4/P5)

- **Latency**: SVA `assert property (@(posedge clk) disable iff (!rst_n) i_valid |-> ##2 (o_valid || $past(i_clr,0)));` (acceptance: REQ-P-002)
- **Clear semantics**: `assert property (i_clr |=> (o_acc == 0 && o_ovf == 0 && o_valid == 0));` (acceptance: REQ-F-004, REQ-F-004a)
- **Wrap semantics**: cocotb scoreboard mod-2^32 check vs C ref (acceptance: REQ-F-006)
- **Sticky overflow**: SVA `assert property ((o_ovf && !i_clr) |=> o_ovf);` (acceptance: REQ-F-006)
- **Reset quiescence**: SVA `assert property (!rst_n |-> (o_acc == 0 && o_ovf == 0 && o_valid == 0));` (acceptance: REQ-F-007)
- **Registered output**: lint NETLIST_OUTPUT_NOT_REG check (acceptance: REQ-F-008)

## 12. Assumptions / Wonder

See `docs/phase-3-uarch/wonder-log.md` for tracked assumptions.

Key load-bearing assumption: target library is generic 28nm; if a different node is
adopted, REQ-U-001 must be re-evaluated.
