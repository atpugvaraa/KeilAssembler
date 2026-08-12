//  armd_rt.c — KeilAssembler runtime. Spec §7.8.
//
//  Linked into every transpiled program. Owns the ARM7 address space, loads the
//  startup image, and appends one trace record per ARM7 instruction.

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>

#define ARM7_ADDRESS_SPACE (1ULL << 32)   // Spec §7.8: the whole 32-bit space
#define ARM7_STACK_TOP     0x00100000u    // Spec §3

struct ARMdState {          // Spec §7.2 — offsets are normative
    uint32_t r[16];         // 0x00 .. 0x3C
    uint32_t cpsr;          // 0x40
};

struct ARMdTraceRecord {    // Spec §7.7 — 96 bytes
    uint32_t seq;
    uint32_t srcLine;
    uint32_t pc;
    uint32_t r[16];
    uint32_t cpsr;
    uint32_t storeAddr;
    uint32_t storeValue;
    uint32_t storeWidth;
    uint32_t _pad;
};

// Pins the three independent definitions of these layouts (this struct, the
// emitter's hardcoded [x27, #(n*4)] offsets in Emitter.swift, and Spec
// §7.2/§7.7) to the same shape at compile time. A mismatch here would
// otherwise surface only as garbage register values in a running program,
// with nothing pointing back at this file.
_Static_assert(offsetof(struct ARMdState, r) == 0x00, "ARMdState.r must start at offset 0 (Spec §7.2)");
_Static_assert(offsetof(struct ARMdState, cpsr) == 0x40, "ARMdState.cpsr must be at offset 0x40 (Spec §7.2)");
_Static_assert(sizeof(struct ARMdState) == 0x44, "ARMdState must be 68 bytes (Spec §7.2)");
_Static_assert(sizeof(struct ARMdTraceRecord) == 96, "ARMdTraceRecord must be 96 bytes (Spec §7.7)");

struct ARMdState armd_state;

static uint8_t *armd_memory;
static FILE *armd_trace_file;
static uint32_t armd_sequence;

/// Loads `image.bin`: repeated (u32 address, u32 length, bytes, pad to 4).
/// Blobs are applied in file order, so later blobs overwrite earlier ones.
/// Every iteration consumes at least the 8-byte header before it can loop
/// again, and any malformed length/address is rejected before it is acted
/// on, so a truncated or corrupt file always reaches EOF or `break` rather
/// than spinning.
static void armd_load_image(void) {
    FILE *file = fopen("image.bin", "rb");
    if (!file) { return; }               // no image is not an error: memory is zero

    uint32_t header[2];
    while (fread(header, sizeof(uint32_t), 2, file) == 2) {
        uint32_t address = header[0];
        uint32_t length  = header[1];
        uint32_t padded  = (length + 3u) & ~3u;

        if ((uint64_t)address + length > ARM7_ADDRESS_SPACE) { break; }
        if (fread(armd_memory + address, 1, length, file) != length) { break; }
        if (padded > length) { fseek(file, (long)(padded - length), SEEK_CUR); }
    }
    fclose(file);
}

void *armd_init(void) {
    armd_memory = mmap(NULL, ARM7_ADDRESS_SPACE, PROT_READ | PROT_WRITE,
                       MAP_ANON | MAP_PRIVATE | MAP_NORESERVE, -1, 0);
    if (armd_memory == MAP_FAILED) {
        fprintf(stderr, "armd: could not reserve the ARM7 address space\n");
        return NULL;
    }

    memset(&armd_state, 0, sizeof(armd_state));
    armd_state.r[13] = ARM7_STACK_TOP;

    armd_load_image();
    armd_trace_file = fopen("trace.bin", "wb");
    // The trace is this tool's entire product, and a crash is exactly when its
    // history matters most — but `fopen`'s default full buffering only reaches
    // disk when the buffer fills or `armd_fini` flushes it, and a crash (a
    // signal, not a normal exit) skips `armd_fini` entirely. Unbuffered I/O
    // makes every `fwrite` below its own `write()` syscall, so whatever
    // executed before a crash survives it. Cost is nil at ~96 bytes/instruction.
    if (armd_trace_file) { setvbuf(armd_trace_file, NULL, _IONBF, 0); }
    return armd_memory;
}

void armd_trace(uint32_t line, uint32_t storeAddr, uint32_t storeWidth) {
    if (!armd_trace_file) { return; }

    struct ARMdTraceRecord record;
    memset(&record, 0, sizeof(record));
    record.seq        = armd_sequence++;
    record.srcLine    = line;
    record.pc         = armd_state.r[15];
    record.cpsr       = armd_state.cpsr;
    record.storeAddr  = storeAddr;
    record.storeWidth = storeWidth;
    memcpy(record.r, armd_state.r, sizeof(record.r));

    // storeWidth == 0 means "no store" (Spec §7.7): skip the read, leaving
    // storeValue at 0. Also reject a width/address combination that would
    // read past the mapped 4 GiB region -- storeAddr is a full uint32_t, so
    // e.g. storeAddr = 0xFFFFFFFE with storeWidth = 4 would otherwise read
    // two bytes past the end of the mapping.
    if (storeWidth != 0 && (uint64_t)storeAddr + storeWidth <= ARM7_ADDRESS_SPACE) {
        if (storeWidth == 1)      { record.storeValue = armd_memory[storeAddr]; }
        else if (storeWidth == 2) { uint16_t half; memcpy(&half, armd_memory + storeAddr, 2); record.storeValue = half; }
        else if (storeWidth == 4) { memcpy(&record.storeValue, armd_memory + storeAddr, 4); }
    }

    fwrite(&record, sizeof(record), 1, armd_trace_file);
}

void armd_fini(void) {
    if (armd_trace_file) {
        fflush(armd_trace_file);
        fclose(armd_trace_file);
        armd_trace_file = NULL;
    }
}
