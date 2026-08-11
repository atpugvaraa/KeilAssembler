# ARMd — Product Requirements

## 1. Problem

ARM7 lab exercises are written in Keil µVision 4 ARMASM and can only be built and run on the
lab's Windows PCs. There is no `armasm` for Apple Silicon, and macOS's native assembler targets
AArch64 — a different architecture with different syntax, register naming, and no conditional
execution suffixes. Working outside the lab is currently impossible.

## 2. Product

A native macOS application, **ARMd**, that accepts unmodified Keil ARMASM source, transpiles it
to AArch64/Darwin assembly, assembles and links it with the system Clang toolchain, executes it,
and presents the resulting ARM7 machine state in a µVision-style interface.

ARMd is split into two components:

| Component | Kind | Responsibility |
|---|---|---|
| `KeilAssembler` | Swift package, no UI dependencies | Lex, parse, analyse, lower, emit, build, run, decode trace |
| `ARMd.app` | SwiftUI macOS app | Editor, build controls, registers, memory, disassembly, diagnostics |

The package must be usable, and fully testable, without SwiftUI.

## 3. Users

One: the author, a student learning ARM7 assembly with an interest in reverse engineering and
security research. Design for that user. Do not build multi-user, multi-project, or
collaboration features.

## 4. Goals

- **G1** — Build and run the given lab exercises without editing their source.
- **G2** — Show ARM7 register and CPSR state that matches hand-computation, per instruction.
- **G3** — Make the machine model visible: memory is a browsable, editable address space, not an
  implementation detail. Writing values into memory before a run is a supported workflow, not a
  workaround — several lab exercises read from addresses that nothing in their source ever
  writes, exactly as they do in µVision's Memory window. Editing a cell must not require a
  rebuild.
- **G4** — Step forwards and backwards through execution, with the current source line
  highlighted in the editor.
- **G5** — Report errors against ARM7 semantics using ARMASM terminology, at a source location.
- **G6** — Expose the generated AArch64 assembly as a first-class, readable view. Seeing what the
  transpiler produced is a learning feature, not debug output.

## 5. Non-goals

- Not a general-purpose ARM assembler. The supported language is a defined subset (Spec §5, §6).
- Not a cycle-accurate or timing-accurate ARM7 model.
- Not an emulator. Arithmetic executes natively on the host CPU.
- No Thumb state, coprocessors, MMU/MPU, caches, interrupts, exception vectors, or privilege
  modes. User mode with NZCV only.
- No debugger integration (LLDB, GDB, ptrace). Observability comes from the emitted trace.
- No Windows or Linux support. macOS on Apple Silicon only.
- No project/workspace format, no build configurations, no linker scripts.

## 6. Success criteria

**S1 — Correctness.** Each exercise in the test corpus (Spec §10) produces the expected final
register state. Expected values are hand-derived from ARM7 semantics and committed as tests
*before* the corresponding lowering is written.

**S2 — Fidelity of workflow.** Edit → Build → Run → inspect registers → Step → inspect memory
is available without leaving the app, and matches the µVision loop closely enough to be used in
the lab in place of a lab PC.

**S3 — Honest failure.** Unsupported constructs produce a diagnostic naming the construct and
the source location. Silently emitting wrong code is a defect of the highest severity.

**S4 — Boundary.** `KeilAssembler` has no `import SwiftUI` and no AppKit dependency. Its test
suite runs via `swift test` with no app target present.

## 7. Constraints

- macOS 15+, Apple Silicon (arm64) only.
- Swift 6.3, `swiftLanguageModes: [.v6]`, strict concurrency.
- Swift Testing (`@Test` / `#expect`), not XCTest.
- Toolchain dependency: `/usr/bin/clang` (Command Line Tools). No Homebrew packages, no
  `arm-none-eabi-*`, no QEMU.
- Zero third-party Swift dependencies.
- Package builds and tests headlessly (CI-able, no UI required).

## 8. Milestones

| # | Milestone | Definition of done |
|---|---|---|
| M0 | Spec + PRD | This document and `Spec.md` reviewed and committed |
| M1 | Front end | Lexer + parser + AST; every corpus program parses; round-trip printer |
| M2 | Analysis | Symbol table, area layout, ARM7 address assignment, diagnostics |
| M3 | Backend | AArch64 emission for exercises 1(a)–1(e); text output snapshot-tested |
| M4 | Runtime | `armd_rt.c` — mmap, startup-image load, trace writer |
| M5 | End-to-end CLI | `swift test` builds, links, runs with a preload, decodes trace; final state asserted |
| M6 | Teaching core | Remaining instructions in Spec §6 with per-instruction tests |
| M7 | App shell | Editor + Build + Registers panel wired to the package |
| M8 | Debug UX | Editable memory browser (preload), trace scrubber, step/step-back, line highlight |
| M9 | Polish | Generated-assembly view, diagnostics gutter, syntax highlighting |

M1–M6 are the product. M7–M9 are the interface to it. M5 is the point at which the project is
already useful.

## 9. Risks

| Risk | Mitigation |
|---|---|
| Lab source uses ARMASM forms the real assembler rejects | Accept-with-warning, and verify against a real Keil install (Spec §11) |
| Barrel-shifter carry-out has no AArch64 equivalent | Explicitly out of scope; diagnosed, documented (Spec §9) |
| Scope creep toward a full emulator | Non-goals above are binding; every ARM7 behaviour is either lowered or diagnosed, never simulated |
| Generated assembly is unreadable | Emit the ARM7 source line as a comment above each lowered block; snapshot-test the text |
