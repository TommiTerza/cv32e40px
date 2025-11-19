/*
 * Simple vector addition microbenchmark that demonstrates the custom SIMT
 * warp control instructions (wspawn/exit).  Four warps cooperatively add two
 * integer vectors and write the result into a third array.
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "mem_stall.h"

#define SIMT_OPCODE_CUSTOM0 0x0b
#define SIMT_FUNCT3_DEFAULT 0x0
#define SIMT_FUNCT7_WSPAWN  0x01
#define SIMT_FUNCT7_EXIT    0x02

#define NUM_WARPS     4u
#define VECTOR_LENGTH 64u
#define CHUNK_SIZE    ((VECTOR_LENGTH + NUM_WARPS - 1u) / NUM_WARPS)

static int32_t vec_a[VECTOR_LENGTH];
static int32_t vec_b[VECTOR_LENGTH];
static volatile int32_t vec_c[VECTOR_LENGTH];

static volatile uint32_t warp_claim = 0;
static volatile uint32_t warp_done = 0;

static void vector_add_kernel(void);

static inline void simt_wspawn(uint32_t warp_mask, void (*entry)(void)) {
    asm volatile(".insn r %3, %4, %2, x0, %0, %1"
                 :
                 : "r"(warp_mask), "r"(entry), "i"(SIMT_FUNCT7_WSPAWN),
                   "i"(SIMT_OPCODE_CUSTOM0), "i"(SIMT_FUNCT3_DEFAULT)
                 : "memory");
}

static inline void simt_exit(void) __attribute__((noreturn));
static inline void simt_exit(void) {
    asm volatile(".insn r %1, %2, %0, x0, x0, x0"
                 :
                 : "i"(SIMT_FUNCT7_EXIT), "i"(SIMT_OPCODE_CUSTOM0), "i"(SIMT_FUNCT3_DEFAULT)
                 : "memory");
    __builtin_unreachable();
}

int main(void) {
#ifdef RANDOM_MEM_STALL
    activate_random_stall();
#endif

    for (uint32_t i = 0; i < VECTOR_LENGTH; ++i) {
        vec_a[i] = (int32_t)i;
        vec_b[i] = (int32_t)(VECTOR_LENGTH - i);
        vec_c[i] = 0;
    }

    warp_claim = 0;
    warp_done = 0;

    /* Spawn four warps onto the vector addition kernel. */
    simt_wspawn((1u << NUM_WARPS) - 1u, vector_add_kernel);

    /* The program never returns: all warps exit via the kernel. */
    while (1) {
        __asm__ volatile("wfi");
    }
}

static void vector_add_kernel(void) {
    uint32_t warp_local_id = __sync_fetch_and_add(&warp_claim, 1);
    uint32_t start = warp_local_id * CHUNK_SIZE;
    uint32_t end = start + CHUNK_SIZE;
    if (end > VECTOR_LENGTH) {
        end = VECTOR_LENGTH;
    }

    for (uint32_t idx = start; idx < end; ++idx) {
        vec_c[idx] = vec_a[idx] + vec_b[idx];
    }

    uint32_t finished = __sync_add_and_fetch(&warp_done, 1);
    if (finished == NUM_WARPS) {
        int errors = 0;
        for (uint32_t i = 0; i < VECTOR_LENGTH; ++i) {
            if (vec_c[i] != vec_a[i] + vec_b[i]) {
                ++errors;
            }
        }
        if (errors == 0) {
            printf("SIMT vector add succeeded using %u warps\n", NUM_WARPS);
        } else {
            printf("SIMT vector add failed: %d mismatches\n", errors);
        }
    }

    simt_exit();
}
