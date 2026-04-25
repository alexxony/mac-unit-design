/*
 * Standalone self-test for the mac_unit reference model.
 *
 * Covers:
 *   - Reset behavior
 *   - Basic accumulation latency (2-cycle)
 *   - Multi-sample accumulation: 3*5 + 7*8 = 71
 *   - Synchronous clear (i_clr) behavior
 *   - Overflow detection accumulating 0xFF*0xFF
 *   - i_valid gating (no accumulation when valid is low)
 */

#include "mac_unit.h"
#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>

static int g_pass = 0;
static int g_fail = 0;

#define CHECK(cond, msg)                                                      \
    do {                                                                      \
        if (cond) {                                                           \
            ++g_pass;                                                         \
            printf("  PASS: %s\n", msg);                                      \
        } else {                                                              \
            ++g_fail;                                                         \
            printf("  FAIL: %s\n", msg);                                      \
        }                                                                     \
    } while (0)

/* Helper: single cycle step with outputs captured into local vars. */
static void tick(mac_unit_state_t *s,
                 uint8_t a, uint8_t b, bool v, bool clr,
                 uint32_t *acc, bool *ov, bool *ovf)
{
    mac_unit_step(s, a, b, v, clr, acc, ov, ovf);
}

static void test_reset(void)
{
    printf("[test_reset]\n");
    mac_unit_state_t s;
    /* Dirty the state first to prove reset really zeros it. */
    s.s1_product = 0xBEEF;
    s.s1_valid   = true;
    s.acc        = 0xDEADBEEF;
    s.ovf        = true;

    mac_unit_reset(&s);

    CHECK(s.s1_product == 0x0000, "reset clears s1_product");
    CHECK(s.s1_valid   == false,  "reset clears s1_valid");
    CHECK(s.acc        == 0u,     "reset clears acc");
    CHECK(s.ovf        == false,  "reset clears ovf");
}

static void test_basic_accumulate(void)
{
    printf("[test_basic_accumulate]\n");
    mac_unit_state_t s;
    mac_unit_reset(&s);

    uint32_t acc; bool ov; bool ovf;

    /* Cycle 0: drive a=3,b=5,valid=1. Stage1 captures 15. o_valid=0 still. */
    tick(&s, 3, 5, true, false, &acc, &ov, &ovf);
    CHECK(acc == 0u && ov == false && ovf == false,
          "C0: a=3,b=5,v=1 -> o_valid=0, acc=0");

    /* Cycle 1: drive a=7,b=8,valid=1. Stage2 sees prev s1_valid=1 and adds 15. */
    tick(&s, 7, 8, true, false, &acc, &ov, &ovf);
    CHECK(acc == 15u && ov == true && ovf == false,
          "C1: stage2 accumulates 15, o_valid=1");

    /* Cycle 2: drive valid=0. Stage2 adds 56 (from cycle-1 s1). */
    tick(&s, 0, 0, false, false, &acc, &ov, &ovf);
    CHECK(acc == (15u + 56u) && ov == true && ovf == false,
          "C2: stage2 accumulates 56, total=71, o_valid=1");

    /* Cycle 3: nothing valid in pipe -> o_valid=0, acc holds. */
    tick(&s, 0, 0, false, false, &acc, &ov, &ovf);
    CHECK(acc == 71u && ov == false && ovf == false,
          "C3: pipeline drained, acc holds 71, o_valid=0");
}

static void test_clear(void)
{
    printf("[test_clear]\n");
    mac_unit_state_t s;
    mac_unit_reset(&s);
    uint32_t acc; bool ov; bool ovf;

    /* Prime the accumulator. */
    tick(&s, 10, 10, true, false, &acc, &ov, &ovf); /* C0: s1=100 */
    tick(&s, 20, 20, true, false, &acc, &ov, &ovf); /* C1: acc+=100 -> 100 */
    tick(&s,  0,  0, false,false, &acc, &ov, &ovf); /* C2: acc+=400 -> 500 */
    CHECK(acc == 500u, "pre-clear acc==500");

    /* Apply i_clr: acc must go to 0 and any in-flight product is discarded. */
    /* First load a pending product, then assert clr on the cycle it would
     * accumulate. */
    tick(&s, 5, 5, true, false, &acc, &ov, &ovf); /* C3: s1=25, stage2 noop */
    CHECK(acc == 500u, "acc holds 500 while s1 loads 25");

    tick(&s, 0, 0, false, true, &acc, &ov, &ovf); /* C4: clr wins, acc=0 */
    CHECK(acc == 0u && ovf == false, "i_clr zeros acc and clears ovf");

    /* After clear, ensure pipeline still accepts new data. */
    tick(&s, 2, 3, true, false, &acc, &ov, &ovf); /* C5: s1=6 */
    tick(&s, 0, 0, false, false, &acc, &ov, &ovf); /* C6: acc+=6 */
    CHECK(acc == 6u, "post-clear pipeline resumes correctly");
}

static void test_overflow(void)
{
    printf("[test_overflow]\n");
    mac_unit_state_t s;
    mac_unit_reset(&s);
    uint32_t acc; bool ov; bool ovf;

    /* 0xFF*0xFF = 0xFE01 = 65025. 0xFFFFFFFF / 65025 ~= 66051. We drive
     * valid=1 with a=b=0xFF continuously and watch ovf assert when the
     * accumulator rolls over. */
    bool saw_ovf = false;
    bool ovf_prev = false;
    for (int i = 0; i < 80000; ++i) {
        tick(&s, 0xFFu, 0xFFu, true, false, &acc, &ov, &ovf);
        if (ovf && !ovf_prev) {
            saw_ovf = true;
        }
        ovf_prev = ovf;
    }
    CHECK(saw_ovf == true, "overflow flag asserts on 32-bit rollover");
    CHECK(ovf == true, "overflow flag is sticky across further additions");

    /* i_clr must clear ovf. */
    tick(&s, 0, 0, false, true, &acc, &ov, &ovf);
    CHECK(ovf == false, "i_clr clears sticky ovf");
    CHECK(acc == 0u,    "i_clr zeros acc after overflow");
}

static void test_valid_gating(void)
{
    printf("[test_valid_gating]\n");
    mac_unit_state_t s;
    mac_unit_reset(&s);
    uint32_t acc; bool ov; bool ovf;

    /* Drive valid=0 the entire time: acc must stay 0, o_valid always 0. */
    for (int i = 0; i < 10; ++i) {
        tick(&s, (uint8_t)(i+1), (uint8_t)(i+2), false, false, &acc, &ov, &ovf);
        CHECK(acc == 0u && ov == false,
              "valid=0 never accumulates, o_valid stays 0");
    }

    /* Now inject a single valid pulse, confirm only one accumulation. */
    tick(&s, 4, 4, true,  false, &acc, &ov, &ovf); /* C0: s1=16, o_valid=0 */
    CHECK(acc == 0u && ov == false, "single pulse C0: pipeline load only");

    tick(&s, 9, 9, false, false, &acc, &ov, &ovf); /* C1: acc+=16, s1 invalid */
    CHECK(acc == 16u && ov == true, "single pulse C1: one accumulation");

    tick(&s, 7, 7, false, false, &acc, &ov, &ovf); /* C2: nothing valid */
    CHECK(acc == 16u && ov == false, "single pulse C2: no further accumulation");

    tick(&s, 8, 8, false, false, &acc, &ov, &ovf); /* C3: still nothing */
    CHECK(acc == 16u && ov == false, "single pulse C3: acc holds");
}

int main(void)
{
    printf("== mac_unit reference model self-test ==\n");
    test_reset();
    test_basic_accumulate();
    test_clear();
    test_overflow();
    test_valid_gating();

    printf("\n== Summary: %d PASS, %d FAIL ==\n", g_pass, g_fail);
    return (g_fail == 0) ? 0 : 1;
}
