/*
 * 2-stage pipelined 8-bit MAC unit reference model implementation.
 *
 * Bit-accurate, pure-C (C11) DPI-C-compatible. Matches RTL semantics:
 *   - Stage 2 is evaluated BEFORE stage 1 within the step so stage 1's NEW
 *     value written this cycle is not consumed by stage 2 this cycle (i.e.
 *     the pipeline register semantics of a posedge flop are preserved).
 *   - i_clr is synchronous: it zeros the accumulator and clears the overflow
 *     flag, and it discards any product that would have been accumulated
 *     this cycle (models clear-dominant behavior at stage 2).
 *   - Overflow detection uses 33-bit addition to capture the carry-out.
 *   - Overflow flag is sticky: only i_clr or mac_unit_reset() can clear it.
 */

#include "mac_unit.h"
#include <string.h>

void mac_unit_reset(mac_unit_state_t *s)
{
    /* Model asynchronous reset: clear all pipeline + stage-2 state. */
    memset(s, 0, sizeof(*s));
}

void mac_unit_step(mac_unit_state_t *s,
                   uint8_t i_a, uint8_t i_b,
                   bool i_valid, bool i_clr,
                   uint32_t *o_acc, bool *o_valid, bool *o_ovf)
{
    /*
     * Evaluate stage 2 first using the CURRENT pipeline register values
     * (those latched on previous cycles). This is the RTL "read old reg"
     * semantics — the stage-1 capture below will only be visible next step.
     */

    /* o_valid reflects the stage-2 valid, which is simply s1_valid from the
     * previous cycle (i_valid delayed by 2 cycles total once considering
     * stage-1 capture). */
    const bool  s2_valid_in   = s->s1_valid;
    const uint16_t s2_product = s->s1_product;

    uint32_t next_acc = s->acc;
    bool     next_ovf = s->ovf;

    if (i_clr) {
        /* Synchronous clear at stage 2: discard this cycle's product,
         * zero the accumulator, and clear the sticky overflow flag. */
        next_acc = 0u;
        next_ovf = false;
    } else if (s2_valid_in) {
        /* 33-bit addition to detect overflow of the 32-bit accumulator. */
        uint64_t sum = (uint64_t)s->acc + (uint64_t)s2_product;
        if (sum > (uint64_t)0xFFFFFFFFu) {
            next_ovf = true; /* sticky */
        }
        next_acc = (uint32_t)(sum & 0xFFFFFFFFu);
    }

    /*
     * Stage 1: capture (a*b) into the pipeline register when i_valid=1.
     * When i_valid=0 the register holds (we still set s1_valid=false so
     * stage 2 does not accumulate stale data).
     */
    uint16_t next_s1_product = s->s1_product;
    if (i_valid) {
        next_s1_product = (uint16_t)((uint16_t)i_a * (uint16_t)i_b);
    }
    const bool next_s1_valid = i_valid;

    /* Commit all nextstate values (posedge edge). */
    s->acc        = next_acc;
    s->ovf        = next_ovf;
    s->s1_product = next_s1_product;
    s->s1_valid   = next_s1_valid;

    /* Drive outputs from committed state.
     *
     * NOTE (P3 Round 2 fix): o_valid is suppressed by i_clr at the Stage 2
     * input per architecture.md §5.1 / REQ-A-007 acceptance criteria
     * ("o_valid is exactly i_valid delayed by 2 cycles, gated AND-NOT with
     * i_clr at the Stage 2 input"). Prior to this fix, the model returned
     * raw s2_valid_in which violated REQ-A-007 on the cycle of i_clr.
     */
    *o_acc   = s->acc;
    *o_valid = s2_valid_in && !i_clr;
    *o_ovf   = s->ovf;
}
