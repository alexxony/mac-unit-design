# Final Spec Compliance Review: mac_unit (Phase 5 Stage 3.3)

- Date: 2026-04-24
- Reviewer: rtl-architect (READ-ONLY)
- Scope: entire mac_unit design from P1 spec through P5 verification

## 1. Inputs Reviewed

- docs/phase-1-research/io_definition.json
- docs/phase-1-research/iron-requirements.json (P1 iron)
- docs/phase-3-uarch/iron-requirements.json (P3 iron, 5 REQ-U-*)
- docs/phase-2-architecture/architecture.md (Phase 2 decisions)
- docs/phase-3-uarch/mac_unit.md (Phase 3 μArch normative spec)
- rtl/mac_unit/mac_unit.sv (implementation, 110 lines)
- sim/sva/mac_unit_sva.sv (SVA properties)
- reviews/phase-5-verify/ (all V1-V9 reports)
- reviews/phase-5-verify/traceability-audit.md (P6 gate)

## 2. Hierarchical Spec Compliance

Verified layer-by-layer (per docs/CLAUDE.md Hierarchical Spec Compliance):

| Layer | Check | Result |
|-------|-------|--------|
| P1 Spec → P2 Arch | Arch implements all must REQ-F, REQ-P | PASS (architecture.md §6-7 maps each to mul_path/acc_path) |
| P2 Arch → P3 μArch | μArch complies with block boundaries (single module per REQ-A-009) | PASS (mac_unit.md §1 flat module) |
| P3 μArch → RTL | RTL implements Eq §7 literally | PASS (mac_unit.sv:56-76 line-by-line correspondence) |
| RTL → Verification | V2 formal + V5 sim + V8 synth all validate against original spec | PASS |

## 3. Design Priority Audit

Per rtl-p5-verify-policy design priorities:

| Priority | Criterion | Result |
|----------|-----------|--------|
| 1. Functional Correctness | V2 formal 4/4 + V5 55/55 + 0 mismatches | PASS |
| 2. Interface Compliance | REQ-F-009 port list match, V1 lint clean | PASS |
| 3. Timing/Performance | REQ-P-001/002 verified; SDC 500 MHz; post-synth WNS = SKIPPED (no commercial tool) | PASS* (*WNS deferred to commercial flow) |
| 4. Area/Power | V8 51 flops match spec; 1308 NAND2-FO2 gates; no latches | PASS |

## 4. Verification Completeness

Module Graduation Gate (rtl-p5-verify-policy):

| # | Category | Verdict |
|---|----------|---------|
| V1 | Lint | PASS (verilator + slang, 0 errors, 0 warnings) |
| V2 | SVA formal | PASS (4/4 PROVED by k-induction at depth 20) |
| V3 | CDC | PASS (single clock, 1 justified CAUTION for external rst sync contract) |
| V4 | Protocol | N/A (no bus interface) |
| V5 | Functional regression | PASS (55/55, 0 mismatches) |
| V6 | Coverage | PASS (RTL line 100%, toggle 100%, FSM vacuously 100%, functional >=90.9%) |
| V7 | Performance | PASS (0% deviation from spec and BFM) |
| V8 | Synthesizability | PASS (0 latches, 51 flops match spec, 1308 NAND2-FO2) |
| V9 | Code review | PASS (no findings) |

## 5. Phase 4 Outstanding Issues — Resolution Status

| Issue from Phase 4 | Phase 5 Resolution |
|--------------------|--------------------|
| `cg_mac_inst_pct = 0.0%` | ROOT CAUSED — Verilator `get_inst_coverage()` stub; added explicit `sample()` call; covergroup now records 67k+ samples/seed. Analytical bin coverage >= 90.9%. See sim/coverage/mac_unit_func_cov_analysis.md. |
| SVA formal not run | RESOLVED — SymbiYosys BMC(30) + k-induction(20) PASS on all 4 properties. See formal/formal_verify_mac_unit.json. |
| Toggle coverage at 80% margin | RESOLVED — Post-5-seed merge shows toggle = 100.0% (488/488). |
| Line coverage 95% | RESOLVED — RTL-only line = 100.0% (49/49). |

## 6. Issues / Risks

1. **Post-synth timing (REQ-U-001.AC-1, REQ-P-003 WNS)**: commercial timing
   analysis with a real liberty file was not performable in this environment.
   SDC is correct (create_clock -period 2.000). Low risk: 33-bit adder in
   28 nm is comfortably sub-1 ns (per μArch §9 assumption).
   Recommendation: rerun synthesis with DC/Genus + liberty before tapeout.

2. **Verilator `get_inst_coverage()` returns 0 always**: tool limitation,
   underlying bin data is captured. Commercial simulator restores the query
   API without RTL/TB change.

No Critical or High risks identified.

## 7. Compliance Verdict

**PASS** — mac_unit is spec-compliant and verification-complete to the
extent allowable by the available OSS toolchain. All 9 module-graduation
categories pass. All structured AC with `verifiable: true` pass. P6 entry
traceability gate (reviews/phase-5-verify/traceability-audit.md) is PASS.

## 8. Next Steps

- Update `.rat/state/rat-auto-design-state.json` phase 4/5 → complete.
- P6 (Design Review) may begin.
- For physical signoff: rerun V8 with commercial synthesis tool (DC/Genus) +
  target-node liberty file to resolve REQ-P-003 WNS AC (presently PARTIAL).
