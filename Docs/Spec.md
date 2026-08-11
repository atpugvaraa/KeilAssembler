# KeilAssembler — Language and Lowering Specification

**Status:** draft 1. **Scope:** normative for `KeilAssembler`; `ARMd.app` is a client.

## 1. References

| Ref | Document |
|---|---|
| [ARMASM] | *ARM Compiler v5.06 for µVision — armasm User Guide*, ARM DUI 0379H. Release history includes ARM Compiler v4.1 for µVision, the lineage of µVision 4. Normative for source syntax, directives, condition codes, `Operand2`, and the `LDR` forms. |
| [ARMARM] | *ARM Architecture Reference Manual*, ARMv5 (ARM7TDMI is ARMv4T; ARMv5 ARM ARM documents the ARM instruction semantics used here). Normative for ARM7 instruction semantics and CPSR flag results. |
| [A64] | *Arm Architecture Reference Manual for A-profile*, A64 instruction set. Normative for the target. |
| [APPLE] | *Writing ARM64 Code for Apple Platforms*. Normative for Mach-O symbol naming, register roles, and the Darwin AArch64 ABI. |
| [UV4] | *Keil µVision 4 User Guide*. Reference for the workflow being reproduced. |

Where [ARMASM] and observed lab source disagree, §11 records the conflict; the implementation
accepts the lab form with a warning.

## 2. Pipeline

```
ARMASM source
  → Lexer          tokens, with source ranges
  → Parser         AST (syntax, verbatim — no normalisation)
  → Analyser       symbols, area layout, ARM7 addresses, immediate legality, diagnostics
  → Lowering       AArch64 emission per §7
  → Emitter        Darwin `.s` text
  → clang          assemble + link with armd_rt.o  →  Mach-O executable
  → Run            child process; writes trace.bin
  → TraceDecoder   [MachineSnapshot]  →  app
```

**Rule.** The lexer and parser preserve what the source says. `&12` is a hex literal token, not
`0x12` text; `MOVEQS` is `(mnemonic MOV, cond EQ, setFlags true)`, not an opcode string. All
normalisation happens at or after analysis.

## 3. ARM7 machine model

- **Registers.** R0–R15, 32-bit. R13 = SP, R14 = LR, R15 = PC (synthetic — see §9).
- **CPSR.** N, Z, C, V only, at their architectural bit positions 31–28. Mode bits, I/F, and T
  are not modelled.
- **Memory.** Flat, little-endian, byte-addressed, `0x00000000`–`0xFFFFFFFF`, all readable and
  writable. Every byte is zero except where the startup image (§5.3) supplies contents.
- **Reset state.** All registers zero except SP = `ARM7_STACK_TOP` (default `0x00100000`,
  full-descending). CPSR = 0.

## 4. Lexical structure

Case: mnemonics, register names, condition suffixes, shift names, and directives are
**case-insensitive**. User symbols are **case-sensitive** ([ARMASM]).

| Token | Form |
|---|---|
| Comment | `;` to end of line |
| Hex literal | `&1F`, `0x1F`, `0X1F` |
| Decimal literal | `31` |
| Based literal | `2_00011111`, `8_37`, `16_1f` |
| Character | `'A'` |
| String | `"text"` |
| Immediate prefix | `#` |
| Register | `R0`–`R15`, `SP`, `LR`, `PC` |
| Symbol | `[A-Za-z_][A-Za-z0-9_]*` |
| Punctuation | `, [ ] { } ! # = & + - * / ( ) : ^` |

### 4.1 Source line grammar

```
line   := [label] [ statement ] [ comment ]
label  := symbol                    ; column 1
stmt   := instruction | directive
```

[ARMASM] requires a label to begin in column 1 and an unlabelled statement to be preceded by
whitespace. The lab source violates this (mnemonics in column 1). See §11 Q2 — accepted with
warning `W001`.

## 5. Directives

| Directive | Form | Semantics |
|---|---|---|
| `AREA` | `AREA name, attr {, attr}` | Begin/select a section. Recognised attributes: `CODE`, `DATA`, `READONLY`, `READWRITE`, `ALIGN=n`. Others parse and are ignored with `W003`. |
| `ENTRY` | `ENTRY` | Mark the module entry point. Exactly one required. |
| `END` | `END` | End of source. Text after it is ignored. |
| `EQU` | `sym EQU expr` | Compile-time constant. |
| `ALIGN` | `ALIGN {n}` | Align the current area position to `n` bytes (default 4). |
| `DCB` | `{label} DCB expr{,expr}` | Emit bytes. Accepts string literals. |
| `DCW` | `{label} DCW expr{,expr}` | Emit halfwords, 2-byte aligned. |
| `DCD` | `{label} DCD expr{,expr}` | Emit words, 4-byte aligned. |
| `SPACE` | `{label} SPACE n` | Reserve `n` zero bytes. |
| `LTORG` | `LTORG` | Accepted, no effect (§7.6). |
| `EXPORT` / `GLOBAL` | `EXPORT sym` | Accepted, no effect. |

Anything else — `MACRO`, `IF`/`ELSE`/`ENDIF`, `GBLA`, `RN`, `PROC`, `CODE16`, `THUMB` — is a
hard error `E010: directive not supported in this subset`.

### 5.1 Expressions

Integer only, 32-bit wrapping. Operators, by descending precedence:
`( )` · unary `+ - ~` · `* / :MOD:` · `+ -` · `:SHL: :SHR:` · `:AND: :OR: :EOR:`.
Operands: literals, `EQU` symbols, labels (resolve to their ARM7 address), `.` (current
position). Forward references are permitted; expression evaluation is a fixpoint pass after
layout.

### 5.2 Area layout and ARM7 addressing

Every area is assigned a base ARM7 address at analysis time. Areas are laid out in declaration
order, 4-byte aligned, starting at `ARM7_ORIGIN` (default `0x00008000`). Every label — in both
`CODE` and `DATA` areas — receives an ARM7 address. `CODE` labels advance 4 bytes per
instruction. Those addresses are what appear in the PC field, in the memory browser, and in
`ADR` / `LDR Rd, label` results.

The contents of `DATA` areas form the **data image**: a list of `(arm7Address, bytes)` blobs
written to the startup image file (§5.3) and copied into ARM7 memory by the runtime at startup.
`CODE` areas are *not* present in ARM7 memory — see §9 D3.

### 5.3 The startup image

ARM7 memory is initialised from a single sidecar file, `image.bin`, read by the runtime at
startup (§7.8). It is a concatenation of blobs:

```
blob := u32 arm7Address · u32 byteCount · byteCount bytes · zero-pad to a 4-byte boundary
```

The file has two parts, applied in order:

1. **Data image** — emitted by the compiler from the `DATA` areas (§5.2).
2. **Preload image** — supplied by the client, not by the source.

Later blobs overwrite earlier ones, so a preload entry wins over a `DCD` at the same address.

The preload image is how the lab's memory contents are set. Exercises such as 1(d) load from
`0x00001000` and `0x00001004` without any source construct placing values there; in µVision
those cells are typed into the Memory window before running. The preload image is the same
input, expressed as data:

```swift
public struct MemoryPreload: Sendable {
    public var entries: [(address: UInt32, bytes: [UInt8])]
}
```

It is an input to *running*, not to *compiling*. Because it is a separate file, changing a
memory value does not require re-emitting or re-linking anything — the app's memory editor
rewrites `image.bin` and re-runs. Tests supply it in the same way, as a literal.

## 6. Instructions

Every instruction accepts an optional condition suffix and, where architecturally valid, the
`S` suffix: `<MNEMONIC>{<cond>}{S}`. Suffix parse order is `cond` then `S` (`ADDEQS`), and
[ARMASM] also accepts the reverse for some forms; both are accepted.

### 6.1 Condition codes

| Suffix | Meaning | Flags | A64 branch used to guard | Inverse used to skip |
|---|---|---|---|---|
| `EQ` | equal | Z=1 | `b.eq` | `b.ne` |
| `NE` | not equal | Z=0 | `b.ne` | `b.eq` |
| `CS`/`HS` | carry set / unsigned ≥ | C=1 | `b.hs` | `b.lo` |
| `CC`/`LO` | carry clear / unsigned < | C=0 | `b.lo` | `b.hs` |
| `MI` | negative | N=1 | `b.mi` | `b.pl` |
| `PL` | positive or zero | N=0 | `b.pl` | `b.mi` |
| `VS` | overflow | V=1 | `b.vs` | `b.vc` |
| `VC` | no overflow | V=0 | `b.vc` | `b.vs` |
| `HI` | unsigned > | C=1 ∧ Z=0 | `b.hi` | `b.ls` |
| `LS` | unsigned ≤ | C=0 ∨ Z=1 | `b.ls` | `b.hi` |
| `GE` | signed ≥ | N=V | `b.ge` | `b.lt` |
| `LT` | signed < | N≠V | `b.lt` | `b.ge` |
| `GT` | signed > | Z=0 ∧ N=V | `b.gt` | `b.le` |
| `LE` | signed ≤ | Z=1 ∨ N≠V | `b.le` | `b.gt` |
| `AL` | always | — | none emitted | — |

`NV` is deprecated and rejected: `E011`.

### 6.2 Operand2

```
Operand2 := #<expr>
          | Rm
          | Rm, <shift> #<expr>
          | Rm, <shift> Rs
          | Rm, RRX
shift    := LSL | LSR | ASR | ROR
```

`#<expr>` must be encodable as an ARM7 modified immediate — an 8-bit value rotated right by an
even amount ([ARMARM]). Values that are not are rejected with `E020: immediate cannot be
encoded`, matching real `armasm`, even though the *emitted* AArch64 has no such restriction.
The transpiler must not silently accept what the reference assembler rejects.

### 6.3 Supported instructions

**Data processing** — `Rd, Rn, Operand2`, or `Rd, Operand2` for `MOV`/`MVN`, or `Rn, Operand2`
for the compare forms:

`MOV` `MVN` `ADD` `ADC` `SUB` `SBC` `RSB` `RSC` `AND` `ORR` `EOR` `BIC` `CMP` `CMN` `TST` `TEQ`

`CMP` `CMN` `TST` `TEQ` always set flags and have no destination.

**Multiply:** `MUL Rd, Rm, Rs` · `MLA Rd, Rm, Rs, Rn`.

**Memory:** `LDR` `STR` `LDRB` `STRB` `LDRH` `STRH`, with addressing modes:

| Form | Meaning |
|---|---|
| `[Rn]` | address = Rn |
| `[Rn, #±off]` | address = Rn + off |
| `[Rn, ±Rm]` | address = Rn + Rm |
| `[Rn, ±Rm, <shift> #k]` | address = Rn + shift(Rm, k) |
| `[Rn, #±off]!` | pre-indexed, Rn ← address |
| `[Rn], #±off` | post-indexed, address = Rn, then Rn ← Rn + off |
| `label` | literal load: Rd ← memory[address-of-label] (§7.6) |

**Stack:** `PUSH {reglist}` · `POP {reglist}` · `STMFD SP!, {reglist}` · `LDMFD SP!, {reglist}`.
Full-descending only; register lists are stored lowest-register-at-lowest-address per [ARMARM].
General `LDM`/`STM` addressing modes: `E012`, not in this subset.

**Branch:** `B label` · `BL label` · `BX Rm`.

**Pseudo:** `LDR Rd, =<expr>` · `ADR Rd, label` · `NOP`.

Anything else: `E013: instruction not supported in this subset`, naming the mnemonic.

## 7. Target model and lowering

### 7.1 Host register conventions

| Host register | Role |
|---|---|
| `x27` | pointer to `_armd_state` (ARM7 register file) |
| `x28` | ARM7 memory base — host address of ARM7 `0x00000000` |
| `w9`–`w12` | scratch, dead at every instruction boundary |
| `x0`–`x2` | runtime helper arguments |

`x27` and `x28` are callee-saved in the Darwin AArch64 ABI ([APPLE]), so runtime helper calls
preserve them. Their values are established once in the prologue.

### 7.2 Register file

```c
struct ARMdState {          // offsets are normative
    uint32_t r[16];         // 0x00 .. 0x3C   R0..R15
    uint32_t cpsr;          // 0x40           NZCV at bits 31..28
};
extern struct ARMdState armd_state;   // asm symbol: _armd_state
```

Rn is at `[x27, #(n*4)]`. No register allocation is performed: every ARM7 instruction is lowered
as load-operands → operate → store-result. This is deliberate (PRD G6) — the generated assembly
maps one-to-one onto the source, and the register file is directly the Registers panel's model.

### 7.3 Flags

The CPSR is the single source of truth; host `PSTATE.NZCV` is live only within one lowered
instruction. AArch64 NZCV bit positions match ARM CPSR bits 31–28, so no re-packing is needed.

- After a flag-setting instruction: `mrs x9, nzcv` · `str w9, [x27, #0x40]`
- Before a conditional instruction: `ldr w9, [x27, #0x40]` · `msr nzcv, x9`

This is required, not an optimisation opportunity: `bl` to a runtime helper clobbers `PSTATE`.

### 7.4 Operand2 materialisation

`Operand2` is always materialised into `w10` before use, then the plain register form of the
A64 instruction is emitted. Uniform, and it sidesteps every A64 operand-encoding restriction.

| Source form | Emitted |
|---|---|
| `#imm` | `movz w10, #(imm & 0xFFFF)` · `movk w10, #(imm >> 16), lsl #16` |
| `Rm` | `ldr w10, [x27, #(m*4)]` |
| `Rm, LSL #k` | `ldr w10, [x27, #(m*4)]` · `lsl w10, w10, #k` |
| `Rm, LSR #k` | … · `lsr w10, w10, #k` |
| `Rm, ASR #k` | … · `asr w10, w10, #k` |
| `Rm, ROR #k` | … · `ror w10, w10, #k` |
| `Rm, LSL Rs` | `ldr w10, [x27,…]` · `ldr w11, [x27,…]` · `lslv w10, w10, w11` |
| `Rm, LSR Rs` | … · `lsrv w10, w10, w11` |
| `Rm, ASR Rs` | … · `asrv w10, w10, w11` |
| `Rm, ROR Rs` | … · `rorv w10, w10, w11` |
| `Rm, RRX` | `ldr w10,…` · `ldr w11,[x27,#0x40]` · `msr nzcv,x11` · `rrx`-equivalent: `adc`-based sequence per §9 D1 |

`movz`/`movk` is used unconditionally for immediates: always two instructions, always correct,
no encoding analysis. ARM7-side legality is already enforced by §6.2.

### 7.5 Instruction lowering

Notation: `LD(Rn) ≡ ldr w9, [x27, #(n*4)]`; `ST(Rd) ≡ str w11, [x27, #(d*4)]`; `OP2 ≡ w10` per
§7.4. `{S}` selects the flag-setting A64 form and appends the §7.3 CPSR store. A condition
suffix wraps the entire block in `b.<inverse> Lskip_N` … `Lskip_N:` per §6.1.

| ARM7 | Emitted A64 body |
|---|---|
| `MOV Rd, Op2` | `OP2` · `mov w11, w10` · `ST(Rd)` |
| `MOVS Rd, Op2` | `OP2` · `ands w11, w10, w10` · `ST(Rd)` · store CPSR |
| `MVN Rd, Op2` | `OP2` · `mvn w11, w10` · `ST(Rd)` |
| `ADD Rd, Rn, Op2` | `LD(Rn)` · `OP2` · `add w11, w9, w10` · `ST(Rd)` |
| `ADDS Rd, Rn, Op2` | … · `adds w11, w9, w10` · `ST(Rd)` · store CPSR |
| `ADC{S}` | restore CPSR · `adc{s} w11, w9, w10` |
| `SUB{S}` | `sub{s} w11, w9, w10` |
| `SBC{S}` | restore CPSR · `sbc{s} w11, w9, w10` |
| `RSB{S}` | `sub{s} w11, w10, w9` |
| `RSC{S}` | restore CPSR · `sbc{s} w11, w10, w9` |
| `AND{S}` | `and{s} w11, w9, w10` |
| `ORR{S}` | `orr w11, w9, w10` (+ `ands w11,w11,w11` if `S`) |
| `EOR{S}` | `eor w11, w9, w10` (+ `ands` if `S`) |
| `BIC{S}` | `bic{s} w11, w9, w10` |
| `CMP Rn, Op2` | `LD(Rn)` · `OP2` · `subs wzr, w9, w10` · store CPSR |
| `CMN Rn, Op2` | `adds wzr, w9, w10` · store CPSR |
| `TST Rn, Op2` | `ands wzr, w9, w10` · store CPSR |
| `TEQ Rn, Op2` | `eor w11, w9, w10` · `ands wzr, w11, w11` · store CPSR |
| `MUL Rd, Rm, Rs` | `mul w11, w9, w10` · `ST(Rd)` |
| `MLA Rd, Rm, Rs, Rn` | `madd w11, w9, w10, w12` · `ST(Rd)` |

`ORR`/`EOR`/`TEQ` have no flag-setting A64 form, so `S` is realised by a following
`ands w11, w11, w11`, which sets N and Z and leaves C and V — matching ARM7, where logical
operations without a shifted operand leave C and V unchanged.

**Memory.** The effective ARM7 address is computed into `w9`, then a single access through the
memory base:

```
; LDR R3, [R1]
  ldr   w9,  [x27, #(1*4)]        ; R1 = ARM7 address
  ldr   w11, [x28, w9, uxtw]      ; x28 + zero-extended ARM7 address
  str   w11, [x27, #(3*4)]        ; R3
```

`ldrb`/`ldrh`/`strb`/`strh` substitute directly. `uxtw` zero-extends the 32-bit ARM7 address into
the 64-bit host space, so every ARM7 address maps to exactly one host byte. Pre-index writes `w9`
back to Rn before the access; post-index accesses at the original Rn, then writes Rn + offset.

**Stack.** SP is ARM7 R13 and lives entirely inside ARM7 memory; it is unrelated to the host
stack pointer. `PUSH {r1,r4}` decrements R13 by 4 per register and stores in ascending register
order at ascending addresses. `POP` reverses it.

**Branch.** `B label` → `b Larm7_label`. `BL label` → set R14 to the ARM7 address of the next
instruction (for display), then `bl Larm7_label`. Any label that is the target of a `BL` is
emitted with `stp x29, x30, [sp, #-16]!` at entry; `BX LR` and `MOV PC, LR` emit
`ldp x29, x30, [sp], #16` · `ret`. Nested and recursive calls work. `BX Rm` where Rm ≠ LR, and
any other write to R15, are rejected: `E014: computed branch not supported`.

### 7.6 `LDR` forms

Three distinct constructs share the `LDR` mnemonic; they must not be conflated.

| Form | Meaning | Lowering |
|---|---|---|
| `LDR Rd, =expr` | Pseudo-instruction. Rd ← the *value* of `expr`. | `movz`/`movk` of the resolved value; no memory access. Literal pools are therefore never emitted, and `LTORG` is a no-op. |
| `ADR Rd, label` | Rd ← the *ARM7 address* of `label`. | `movz`/`movk` of the label's ARM7 address. |
| `LDR Rd, label` | Literal load. Rd ← the *word stored at* `label`. | Materialise the label's ARM7 address into `w9`, then `ldr w11, [x28, w9, uxtw]`. |

The third form is what the labs use, and it is why `VALUE1 DCD &00001000` followed by
`LDR R1, VALUE1` yields `R1 = 0x00001000`: the label's *contents*, not its address. §11 Q3 flags
this for confirmation against a real Keil build.

### 7.7 Trace

Every lowered instruction ends with:

```
  ; instruction that performs no store
  movz w0, #<source line index>       ; movk for indices >= 65536
  mov  w1, wzr
  mov  w2, wzr
  bl   _armd_trace

  ; instruction that performs a store — w9 still holds the effective
  ; ARM7 address computed for the store, and the store does not clobber it
  movz w0, #<source line index>
  mov  w1, w9
  movz w2, #<store width: 1, 2, or 4>
  bl   _armd_trace
```

The store address is a **runtime value**, not an immediate: for `STR R0, [R1]` it is
whatever R1 holds when the instruction executes. It is therefore passed from `w9` — the
register the memory lowering already computed it into — and the memory lowering must leave
`w9` live until the trace call. Passing an immediate here would record address 0 for every
store and leave the memory view permanently empty.

`_armd_trace` appends one fixed-size record:

```c
struct ARMdTraceRecord {   // 96 bytes
    uint32_t seq;          // monotonic
    uint32_t srcLine;      // 0-based index into the source
    uint32_t pc;           // synthetic ARM7 address of this instruction
    uint32_t r[16];
    uint32_t cpsr;
    uint32_t storeAddr;    // ARM7 address written, or 0
    uint32_t storeValue;   // value after the write
    uint32_t storeWidth;   // 1, 2, 4, or 0 for no store
    uint32_t _pad;
};
```

Because each record carries any memory write, ARM7 memory at step *n* is a fold of the data
image and the first *n* records. The memory browser, the registers panel, step, step-back, and
run-to-line are all views over the decoded trace array. No debugger is involved.

### 7.8 Runtime (`armd_rt.c`)

Three entry points, plus one BSS symbol:

- `void *armd_init(void)` — `mmap(NULL, 4 GiB, PROT_READ|PROT_WRITE, MAP_ANON|MAP_PRIVATE|MAP_NORESERVE, -1, 0)`, read `image.bin` and copy each blob to its ARM7 address in file order (§5.3), set `armd_state.r[13] = ARM7_STACK_TOP`, open `trace.bin`, return the base. A missing `image.bin` is not an error; memory is simply all zero.
- `void armd_trace(uint32_t line, uint32_t storeAddr, uint32_t storeWidth)` — append a record.
- `void armd_fini(void)` — flush and close.
- `struct ARMdState armd_state;`

A 4 GiB anonymous mapping reserves address space, not memory. Pages commit only when touched, so
a lab that touches four words costs four pages. Nothing needs configuring, and every one of the
2³² ARM7 addresses is valid — including `0x00001000` and `0x3000F000`, neither of which can be
mapped natively.

Mach-O prefixes C symbols with an underscore: `_armd_init`, `_armd_trace`, `_armd_state`.

### 7.9 Emitted program shape

```asm
        .section __TEXT,__text
        .globl _main
        .p2align 2
_main:
        stp     x29, x30, [sp, #-16]!
        stp     x27, x28, [sp, #-16]!
        bl      _armd_init
        mov     x28, x0
        adrp    x27, _armd_state@PAGE
        add     x27, x27, _armd_state@PAGEOFF
        b       Lentry                    ; ENTRY directive target

        ; ... lowered instruction blocks, each preceded by
        ; ; <line N>  MOV R1, #0x12
        ; as a comment ...

Larmd_exit:
        bl      _armd_fini
        mov     w0, #0
        ldp     x27, x28, [sp], #16
        ldp     x29, x30, [sp], #16
        ret
```

There is no data section: ARM7 memory contents live in `image.bin` (§5.3), not in the
executable. The emitted assembly is code only.

Build: `clang -c armd_rt.c` · `clang -c out.s` · `clang -o program out.o armd_rt.o`. No linker
script, no custom segments, no entitlements.

**Run directory.** `armd_init` and `armd_fini` resolve `image.bin` and `trace.bin` relative to
the working directory. Each run gets its own directory containing the executable, the image, and
the trace, so runs never collide and a run is fully reproducible from its directory alone.

## 8. Diagnostics

```swift
struct Diagnostic: Sendable {
    enum Severity: Sendable { case error, warning, note }
    let severity: Severity
    let code: String          // "E020", "W001"
    let message: String       // ARMASM vocabulary, not compiler-internal vocabulary
    let range: SourceRange    // line, column, length
    let note: String?         // what to do instead
}
```

Errors are collected, not thrown: one build reports every error it can find. A build with any
error emits no assembly. Reserved ranges: `E0xx` syntax, `E1xx` unsupported construct, `E2xx`
semantics, `W0xx` compatibility warnings.

### 8.1 Allocated codes

Every code lives here, including codes reserved for stages not yet written. An implementer can
only see code that already ships, so without this list they cannot avoid colliding with a code a
later stage has claimed — which has already happened once. **Allocate from this table, and add
the row in the same commit as the code.**

| Code | Meaning | Stage |
|---|---|---|
| `E001` | unexpected character | Lexer |
| `E002` | unterminated string literal | Lexer |
| `E003` | unterminated character literal | Lexer |
| `E004` | unterminated `:OPERATOR:` | Lexer |
| `E005` | invalid numeric literal, or invalid base | Lexer |
| `E006` | expected an instruction or directive | Parser |
| `E007` | `EXPORT` expects a symbol name | Parser |
| `E008` | `AREA` expects a section name | Parser |
| `E009` | data directive needs at least one value | Parser |
| `E010` | directive not supported in this subset | Parser |
| `E011` | `NV` condition is deprecated and rejected | Parser |
| `E012` | general `LDM`/`STM` not in this subset | Parser |
| `E013` | instruction not supported in this subset | Parser |
| `E014` | computed branch not supported | Analyser |
| `E015` | expected `)` | Parser |
| `E016` | expected a value | Parser |
| `E017` | `EQU` requires a preceding label | Parser |
| `E018` | expected a register or an immediate | Parser |
| `E019` | shift needs a shift amount | Parser |
| `E020` | immediate cannot be encoded | Analyser |
| `E021` | R15 cannot be used as a data operand | Analyser |
| `E022` | expected a base register after `[` | Parser |
| `E023` | expected a post-indexed offset | Parser |
| `E024` | expected `,` or `]` | Parser |
| `E025` | expected `]` | Parser |
| `E026` | expected an offset register or `#` | Parser |
| `E027` | expected a shift after the offset register | Parser |
| `E028` | scaled register offset needs an immediate shift | Parser |
| `E029` | expected a register in the list | Parser |
| `E030` | expected `}` | Parser |
| `E031` | symbol is not defined | Analyser |
| `E032` | division by zero | Analyser |
| `E033` | no `ENTRY` directive | Analyser |
| `E034` | more than one `ENTRY` directive | Analyser |
| `E035` | instruction appears in a `DATA` area | Analyser |
| `E036` | `RRX` is not lowered in this milestone | Backend |
| `E037` | operand is not valid here | Backend |
| `E038` | expected an operand | Parser |
| `E039` | expected `,` between data-list values | Parser |
| `E040` | expected `,` or end of line after operand | Parser |
| `E041` | expected `,` between registers in a register list | Parser |
| `W001` | statement in the label column | Parser |
| `W002` | stray `,` after a data directive | Parser |
| `W003` | `AREA` attribute ignored | Parser |
| `W004` | `AREA` name declared more than once | Analyser |
| `W010` | barrel-shifter carry not modelled (§9 D1) | Analyser |
| `W011` | unaligned access not modelled (§9 D4) | Analyser |
| `W012` | shift amount ≥ 32 (§9 D8) | Analyser |

Next free error code: `E042`. Next free warning code: `W005` (or `W013` in the deviation band).

## 9. Deviations from real ARM7

Each is a deliberate, documented limit. Where a program's behaviour would differ, the analyser
emits a diagnostic rather than emitting wrong code.

- **D1 — Barrel-shifter carry-out.** On ARM7, a flag-setting data-processing instruction with a
  shifted `Operand2` sets C from the shifter, not the ALU. AArch64 has no equivalent. `MOVS`,
  `ANDS`, `ORRS`, `EORS`, `BICS`, `TST`, `TEQ` with a shift emit `W010: carry flag result of the
  barrel shifter is not modelled; C is unchanged`. N and Z are always correct. `ADDS`/`SUBS`/
  `CMP`/`CMN` are unaffected — their C and V come from the ALU and match exactly.
- **D2 — R15 / PC.** ARM7 reads of R15 yield the instruction address + 8. Not modelled. R15
  holds the synthetic ARM7 address of the current instruction, for display. Reading R15 as a data
  operand is `E021`.
- **D3 — Code is not in memory.** `CODE` areas receive ARM7 addresses for labels and PC display,
  but their instruction encodings are not present in ARM7 memory. Loading from a code address
  returns zero. Self-modifying code is unsupported.
- **D4 — Unaligned access.** ARM7 rotates unaligned `LDR` results. Not modelled; the host
  performs a plain unaligned load. Statically detectable cases emit `W011`.
- **D5 — Endianness.** Little-endian only; big-endian configuration is not modelled.
- **D6 — Modes and exceptions.** User mode only. No banked registers, SPSR, `SWI`/`SVC`,
  interrupts, or vector table.
- **D7 — Timing.** No cycle counts, no wait states, no pipeline effects.
- **D8 — `Operand2` shift amounts.** ARM7 shift-by-register uses the bottom 8 bits of Rs with
  saturating behaviour at ≥32. A64 `lslv`/`lsrv`/`asrv` use the bottom 5 bits and wrap.
  Shift amounts ≥ 32 are diagnosed `W012` where statically known.

## 10. Test corpus

Committed under `Tests/KeilAssemblerTests/Corpus/`. Expected values are hand-derived from ARM7
semantics and written **before** the corresponding lowering. Each entry asserts the final
register state and, where relevant, memory.

| ID | Source | Expected |
|---|---|---|
| `1a` | `MOV R1,#0x12` · `MOV R2,R1` · `MOV R3,R1` | R1=R2=R3=`0x00000012` |
| `1b` | `MOV R1,#0x12` · `MOV R2,#0x15` · `ADD R4,R1,R2` | R4=`0x00000027` |
| `1c` | `LDR R1,VALUE1` · `LDR R2,VALUE2` · `ADD R3,R1,R2`; `VALUE1 DCD &12`, `VALUE2 DCD &13` | R1=`0x12`, R2=`0x13`, R3=`0x25` |
| `1d` | `LDR R1,VALUE1` · `LDR R2,VALUE2` · `LDR R3,[R1]` · `LDR R4,[R2]` · `ADD R6,R4,R3`; `VALUE1 DCD &1000`, `VALUE2 DCD &1004`; **preload** `0x1000 ← 0x00000012`, `0x1004 ← 0x00000013` | R1=`0x1000`, R2=`0x1004`, R3=`0x12`, R4=`0x13`, R6=`0x25` |
| `1d-zero` | `1d` with no preload | R3=R4=R6=`0` — pins the documented zero-fill behaviour of unwritten memory |
| `1e` | `MOV R1,#0x12` · `MVN R2,R1` | R2=`0xFFFFFFED` |
| `2a` | `LDR R1,VALUE` · `MOV R3,R1,LSL #2`; `VALUE DCD &3000F000` | R1=`0x3000F000`, R3=`0xC003C000` |
| `2b` | `MOVS R3,#0` · `MOVEQ R3,R1,LSL #3` | Exercises §7.3 CPSR round-trip and §6.1 conditional lowering |

Layered test levels: **lex** (token stream), **parse** (AST round-trip), **lower** (emitted `.s`
snapshot), **run** (build, execute, decode trace, assert state). Every instruction added in M6
gets at least a lower-level and a run-level test.

## 11. Open questions — verify against a real Keil µVision 4 install

Until answered, the implementation takes the lenient path noted, and records a warning.

- **Q1 — `VALUE1 DCD, &00000012`.** The stray comma after `DCD` appears throughout the lab
  source and is not canonical [ARMASM]. Does real `armasm` accept it?
  *Current behaviour:* accepted, `W002`.
- **Q2 — Mnemonics in column 1.** [ARMASM] treats column 1 as the label field. The lab source
  puts `MOV` there. Does real `armasm` accept it?
  *Current behaviour:* if the first token is a known mnemonic or directive, treat as a statement,
  `W001`.
- **Q3 — `LDR Rd, label`.** Confirm it loads the *word at* the label, not its address (§7.6).
  Assemble `1c` under Keil and read R1 in the simulator.
- **Q4 — Reusing an `AREA` name.** The labs declare `AREA PROGRAM, CODE, READONLY` and later
  `AREA PROGRAM, DATA, READONLY` — the same name with different attributes, which [ARMASM]
  treats as an error. Does real `armasm` accept it?
  *Current behaviour:* accepted as two distinct areas, `W004`.
**Resolved.** *Q5 — reset memory contents.* Exercise `1d` reads `0x1000`/`0x1004` without any
source construct writing them because in µVision those cells are set by hand in the Memory
window before running. Memory contents are therefore a user-supplied input, not a target
default. Modelled as the preload image (§5.3); unwritten memory reads as zero.

## 12. Alternatives considered

- **Real ARM32 toolchain.** `arm-none-eabi-as` + `arm-none-eabi-gdb`'s built-in ARM simulator is
  installed on this machine and would execute ARMv4 bit-exactly, including the barrel-shifter
  carry (D1) and PC+8 semantics (D2). Rejected: the point of the project is to build the
  compiler, and driving GDB is process plumbing rather than compiler work. Recorded because it
  remains the correct fallback for any question of ARM7 ground truth — including all of §11.
- **ARM7 interpreter in Swift.** Simpler and more faithful than transpiling, but produces no
  native code and teaches interpreter construction rather than code generation. Rejected as a
  matter of project intent.
- **Real host registers instead of a memory register file (§7.2).** ARM7 has 16 registers plus
  CPSR; the Darwin ABI offers ten callee-saved registers, and any `bl` clobbers `PSTATE` and
  `x0`–`x18`. A register allocator plus flag spilling would be required to reach the same
  correctness, in exchange for output that is faster but no longer readable line-by-line, and a
  register panel that needs a mapping layer. Rejected: performance is irrelevant at ten
  instructions per program, and readability of the generated assembly is a stated goal.
- **LLDB-driven inspection.** Rejected: process management, output scraping, and a
  `com.apple.security.cs.debugger` entitlement, in exchange for capability the trace already
  provides — including step-*back*, which a debugger does not give.
