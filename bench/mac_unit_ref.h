#ifndef MAC_UNIT_H
#define MAC_UNIT_H
#include <stdint.h>
#include <stdbool.h>

/*
 * 2-stage pipelined 8-bit MAC unit reference model.
 *
 * Pipeline:
 *   Stage 1: capture (a*b) into s1_product; s1_valid = i_valid
 *   Stage 2: if s1_valid => acc += s1_product (wrapping 32-bit); ovf sticks on carry-out
 *   i_clr (synchronous) at stage 2: zeros acc, clears ovf, discards current product
 *   o_valid is i_valid delayed by 2 cycles (== stage 2 s1_valid prior to step)
 *
 * Pure functional C11. No clock or reset — one mac_unit_step() call == one posedge tick.
 */

typedef struct {
    /* Stage 1 pipeline register */
    uint16_t s1_product;
    bool     s1_valid;
    /* Stage 2 state */
    uint32_t acc;
    bool     ovf;
} mac_unit_state_t;

/*
 * Zero-initialize all state (models asynchronous reset).
 */
void mac_unit_reset(mac_unit_state_t *s);

/*
 * Advance the MAC unit one clock cycle.
 *
 * Inputs:
 *   i_a, i_b   : 8-bit operands sampled at stage 1 when i_valid=1
 *   i_valid    : gate stage-1 capture
 *   i_clr      : synchronous clear applied at stage 2 (zeros acc, clears ovf,
 *                and discards the product that would have been accumulated this cycle)
 * Outputs:
 *   *o_acc     : current accumulator (post-update this cycle)
 *   *o_valid   : stage-2 valid (i_valid 2 cycles ago)
 *   *o_ovf     : sticky overflow flag (post-update this cycle)
 */
void mac_unit_step(mac_unit_state_t *s,
                   uint8_t i_a, uint8_t i_b,
                   bool i_valid, bool i_clr,
                   uint32_t *o_acc, bool *o_valid, bool *o_ovf);

#endif /* MAC_UNIT_H */
