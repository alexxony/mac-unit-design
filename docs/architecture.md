# Phase 2 Architecture: 8-bit Pipelined MAC Unit (`mac_unit`)

- Date: 2026-04-23
- Upper spec: `docs/phase-1-research/iron-requirements.json` (P1 authority=1)
- Status: Authority 2, locked after P2 review

## 1. Design Overview

The `mac_unit` is a strictly 2-stage pipelined 8x8 unsigned multiply-accumulate
datapath with a 32-bit wrapping accumulator, sticky overflow flag, and a
synchronous clear that takes priority over both `i_valid` and in-flight products.

- Stage 1: registered 8x8 -> 16-bit multiply
- Stage 2: registered 32-bit accumulate (wrap) + sticky overflow flag
- Latency = 2 cycles (REQ-P-002), throughput = 1 MAC/cycle (REQ-P-001)
- All outputs are flip-flop Q driven (REQ-F-008)

### Open-requirement resolutions (from P1)

| OPEN-ID | Topic                              | P2 decision            | Rationale                                         |
|---------|------------------------------------|------------------------|---------------------------------------------------|
| OPEN-1-001 | Parameterize ACC_WIDTH          | option-a (hard-code 32)| Match P1 brief exactly; no reuse requirement stated |
| OPEN-1-002 | Saturation vs wrap              | option-a (wrap-only)   | REQ-F-006 explicitly mandates wrap                |
| OPEN-1-003 | Signed vs unsigned              | option-a (unsigned-only)| REQ-F-001 explicitly mandates unsigned            |
| OPEN-1-004 | Target frequency                | option-a (500 MHz prov.)| No user confirmation; 2-stage margin is ample    |
| OPEN-1-005 | Multiplier microarchitecture    | option-a (synth-inferred `*`) | Node-optimal, minimal risk, aligns with P1 survey |

## 2. Block Diagram

```d2
direction: right

i_a: {shape: circle; label: "i_a[7:0]"}
i_b: {shape: circle; label: "i_b[7:0]"}
i_valid: {shape: circle; label: "i_valid"}
i_clr: {shape: circle; label: "i_clr"}
clk: {shape: circle; label: "clk"}
rst_n: {shape: circle; label: "rst_n"}

mac_unit: {
  label: "mac_unit"
  style.fill: "#f0f4ff"

  stage1: {
    label: "Stage 1: Multiply"
    mul: {label: "8x8 unsigned\nmultiplier (*)"}
    s1_product_reg: {label: "s1_product[15:0]\n(DFF)"; shape: rectangle}
    s1_valid_reg: {label: "s1_valid\n(DFF)"; shape: rectangle}
    mul -> s1_product_reg: "prod_c[15:0]"
  }

  stage2: {
    label: "Stage 2: Accumulate"
    adder: {label: "33-bit adder\n{1'b0,acc}+{17'b0,prod}"}
    acc_reg: {label: "o_acc[31:0]\n(DFF)"; shape: rectangle}
    ovf_reg: {label: "o_ovf\n(DFF)"; shape: rectangle}
    valid_reg: {label: "o_valid\n(DFF)"; shape: rectangle}
    ctrl: {label: "next-state logic\n(clr priority,\nvalid gating,\nsticky ovf)"}
    adder -> ctrl: "sum[32:0]"
    ctrl -> acc_reg: "acc_nxt[31:0]"
    ctrl -> ovf_reg: "ovf_nxt"
    ctrl -> valid_reg: "ovld_nxt"
  }

  stage1 -> stage2: "s1_product,\ns1_valid"
}

i_a -> mac_unit.stage1.mul
i_b -> mac_unit.stage1.mul
i_valid -> mac_unit.stage1.s1_valid_reg: "gate"
i_clr -> mac_unit.stage2.ctrl: "priority clear"
clk -> mac_unit: "rising edge"
rst_n -> mac_unit: "async-assert,\nsync-deassert"

mac_unit.stage2.acc_reg -> o_acc: "o_acc[31:0]"
mac_unit.stage2.ovf_reg -> o_ovf: "o_ovf"
mac_unit.stage2.valid_reg -> o_valid: "o_valid"

o_acc: {shape: circle}
o_ovf: {shape: circle}
o_valid: {shape: circle}
```

## 3. Pipeline Stage Breakdown

### 3.1 Stage 0 (combinational input, not a register stage)

Input pads `i_a`, `i_b`, `i_valid`, `i_clr` are consumed combinationally by Stage 1
input logic. `i_clr` is also routed forward to Stage 2 for priority clear
(REQ-F-004a).

### 3.2 Stage 1 — Multiply (1 clock of latency)

- Combinational: `prod_c = i_a * i_b` (16-bit unsigned, synthesis-inferred `*`)
- Registers on rising edge of `clk`:
  - `s1_product[15:0]` <- `prod_c` when `i_valid` else `s1_product` (hold)
  - `s1_valid`         <- `i_valid`
- Reset behavior: `rst_n=0` -> `s1_product=0, s1_valid=0` (REQ-F-007)
- No interaction with `i_clr` at this stage: `i_clr` does NOT clear `s1_product`.
  Stage 1 only carries data; its discard is handled at the Stage 2 mux per REQ-F-004a.

### 3.3 Stage 2 — Accumulate + Overflow (1 clock of latency)

- Combinational next-state logic:
  ```
  sum33       = {1'b0, o_acc} + {17'b0, s1_product};   // 33-bit
  ovf_this    = sum33[32];                              // carry-out = overflow event
  acc_add_en  = s1_valid & ~i_clr;                      // gate + clear priority
  acc_nxt     = i_clr        ? 32'b0
              : acc_add_en   ? sum33[31:0]              // wrap via truncation
              :                o_acc;                   // hold
  ovf_nxt     = i_clr        ? 1'b0
              : (acc_add_en & ovf_this) ? 1'b1          // set on carry
              :                o_ovf;                   // sticky
  ovld_nxt    = ~i_clr & s1_valid;                      // suppress on clear
  ```
- Registers on rising edge of `clk`:
  - `o_acc[31:0]` <- `acc_nxt`
  - `o_ovf`       <- `ovf_nxt`
  - `o_valid`     <- `ovld_nxt`
- Reset behavior: `rst_n=0` -> `o_acc=0, o_ovf=0, o_valid=0` (REQ-F-007)

## 4. Datapath Description

### 4.1 Multiply path

- One 8x8 unsigned multiplier at Stage 1 combinational cone.
- Implementation: synthesis-inferred `*` operator, unsigned operands, 16-bit result.
- No sign extension; both operands declared `logic [7:0]` (unsigned by language default).

### 4.2 Accumulate path

- One 33-bit adder (32-bit acc + 16-bit product, zero-extended to 17 bits).
- Use 33-bit form to capture the carry-out on bit [32] as the overflow indicator.
- The low 32 bits of the sum form the wrap result (REQ-F-006).

### 4.3 Overflow detection

- Overflow = bit [32] of the zero-extended add (the natural carry-out).
- Overflow is recorded only when the add actually occurs, i.e., when
  `acc_add_en = s1_valid & ~i_clr`. A blocked add (valid low or clr high) cannot set ovf.
- `o_ovf` is sticky: once set, it remains 1 until `i_clr=1` or `rst_n=0` clears it.

## 5. Control Path

### 5.1 Valid propagation (REQ-F-005)

| cycle T  | cycle T+1           | cycle T+2                         |
|----------|---------------------|-----------------------------------|
| i_valid  | s1_valid = i_valid  | o_valid = s1_valid & ~i_clr@T+2   |

- `o_valid` is `i_valid` delayed by 2 cycles, suppressed by `i_clr` at Stage 2.

### 5.2 Clear propagation (REQ-F-004, REQ-F-004a)

- `i_clr` is NOT registered in Stage 1 and is consumed at the Stage 2 next-state
  logic in the same cycle it is asserted.
- Effect at rising edge of clk when `i_clr=1`:
  - `o_acc` <- 0 (regardless of `s1_valid` or the value of `s1_product`)
  - `o_ovf` <- 0
  - `o_valid` <- 0 (so the discarded product does not appear at the output)
- Clear priority order: `i_clr` > `s1_valid` (REQ-F-004 acceptance criteria).
- `i_clr` does not disturb Stage 1 (`s1_product`, `s1_valid`). The already-captured
  product is simply not added (REQ-F-004a).

### 5.3 Reset (REQ-F-007)

- `rst_n` is active-low, async-assert / sync-deassert.
- All registers (`s1_product`, `s1_valid`, `o_acc`, `o_ovf`, `o_valid`) reset to 0.
- Handled by the standard project FF template:
  `always_ff @(posedge clk or negedge rst_n) if (!rst_n) ... else ...`

## 6. Signal List Per Stage

### 6.1 Top-level ports (frozen, REQ-F-009)

| Direction | Name     | Width | Notes                                       |
|-----------|----------|-------|---------------------------------------------|
| input     | `clk`    | 1     | Rising edge                                 |
| input     | `rst_n`  | 1     | Async-assert, sync-deassert                 |
| input     | `i_clr`  | 1     | Synchronous clear, priority over `i_valid`  |
| input     | `i_valid`| 1     | Stage 1 capture enable                      |
| input     | `i_a`    | 8     | Unsigned                                    |
| input     | `i_b`    | 8     | Unsigned                                    |
| output    | `o_valid`| 1     | Registered, 2-cycle delayed `i_valid`       |
| output    | `o_acc`  | 32    | Registered accumulator Q                    |
| output    | `o_ovf`  | 1     | Registered sticky overflow                  |

### 6.2 Stage 1 internals

| Name            | Width | Kind   | Description                                |
|-----------------|-------|--------|--------------------------------------------|
| `prod_c`        | 16    | wire   | Combinational `i_a * i_b`                  |
| `s1_product`    | 16    | reg    | Stage 1 product register (held when !valid) |
| `s1_valid`      | 1     | reg    | Stage 1 valid register                     |

### 6.3 Stage 2 internals

| Name           | Width | Kind   | Description                                  |
|----------------|-------|--------|----------------------------------------------|
| `sum33`        | 33    | wire   | `{1'b0,o_acc} + {17'b0,s1_product}`          |
| `ovf_this`     | 1     | wire   | `sum33[32]`                                  |
| `acc_add_en`   | 1     | wire   | `s1_valid & ~i_clr`                          |
| `acc_nxt`      | 32    | wire   | Next-state for `o_acc`                       |
| `ovf_nxt`      | 1     | wire   | Next-state for `o_ovf`                       |
| `ovld_nxt`     | 1     | wire   | Next-state for `o_valid`                     |

## 7. Timing Diagram

Pipeline control / data flow for a representative sequence:
`i_valid` asserted on cycles T, T+1, T+3, T+4; `i_clr` asserted on cycle T+2.

```mermaid
sequenceDiagram
    participant IN as Input
    participant S1 as Stage1 (s1_product, s1_valid)
    participant S2 as Stage2 (o_acc, o_ovf, o_valid)

    Note over IN,S2: T-1: quiescent; o_acc=0, o_ovf=0, o_valid=0
    IN->>S1: T: i_valid=1, a=A0, b=B0
    Note over S1: T+1: s1_product=A0*B0, s1_valid=1
    IN->>S1: T+1: i_valid=1, a=A1, b=B1
    S1->>S2: T+2: add A0*B0 into acc
    Note over S2: T+2: o_acc=A0*B0, o_valid=1 (if !clr)
    IN->>S2: T+2: i_clr=1 (overrides)
    Note over S2: T+2: o_acc<=0, o_ovf<=0, o_valid<=0 (A0*B0 discarded at out)
    Note over S1: T+2: s1_product=A1*B1 (Stage1 untouched by clr)
    IN->>S1: T+3: i_valid=1, a=A3, b=B3
    Note over S1,S2: T+3: Stage2 sees s1_valid from T+2 but clr=0 now
    Note over S2: T+3: o_acc=A1*B1, o_valid=1
    IN->>S1: T+4: i_valid=1, a=A4, b=B4
    Note over S1,S2: T+4: accumulate A3*B3; o_acc=A1*B1 + A3*B3
    Note over S2: Overflow: if cumulative sum >= 2^32, o_ovf latches 1 and stays
```

Key observations verifiable from the diagram:
- 2-cycle latency is visible: input at T -> output at T+2 (REQ-P-002).
- Clear at T+2 simultaneously zeroes `o_acc`, `o_ovf`, `o_valid` and discards the
  in-flight product that would otherwise have been added (REQ-F-004, REQ-F-004a).
- Stage 1 is not disturbed by `i_clr` — the product captured at T+1 propagates
  normally and is added at T+3.

## 8. Synthesis Targets & Area/Power Notes

- Target frequency: 500 MHz provisional (REQ-P-003, open-1-004). 2-stage split
  makes this easily met; critical path is the 33-bit add at Stage 2.
- Area estimate (preliminary, TSMC 28 nm typ):
  - Stage 1 8x8 multiplier: ~200 gates (synth-inferred, Booth/array chosen by tool)
  - 16-bit Stage 1 register: ~96 flops
  - 32-bit adder (+1 carry): ~100 gates
  - 32-bit accumulator + 1-bit ovf + 1-bit valid: ~200 flops
  - Total order-of-magnitude: ~500-700 cells
- Power: no clock gating proposed in P2 (small design). Re-evaluate at P5 if
  utilization is low.

## 9. Verification Anchors (for P5)

- Latency check: `(i_valid @ T) -> (o_valid @ T+2)` unless `i_clr @ T+2`.
- Clear semantics: `i_clr @ T -> (o_acc @ T+1 == 0) and (o_ovf @ T+1 == 0)
  and (o_valid @ T+1 == 0)`.
- Wrap semantics: `(acc_prev + prod) mod 2^32 == o_acc_next` for every accepted beat.
- Sticky overflow: once `o_ovf` rises, it stays 1 until `i_clr` or `rst_n`.
- Reset quiescence: `!rst_n` -> all outputs 0 within 1 cycle.
- Output is registered: no combinational path from any input to any output.

## 10. Open Items Deferred to Phase 3

- Exact Stage-1 register enable style (hold-on-!valid vs always-capture with a
  parallel valid bit). Both are functionally equivalent for REQ-F-005 but differ
  on dynamic power. Phase 3 to commit.
- SDC constraint strategy (input/output delay budgeting, clock uncertainty) —
  `timing_constraints.json` to be produced at P3.
- Unit testbench structure (cocotb/UVM) and assertion bind file — P3/P4.

See `open-requirements.json` for the full list.
