# JLSwift 0.10.1 allocation qualification

This receipt covers `inspectMonochromeQualified` and
`decodeMonochromeQualified`, using caller-owned output and workspace. It does
not describe the allocating legacy or shared-image contract APIs.

## Exact source and execution profile

- Qualified source commit: `cea74028825afa44b79d0bccd5b09b691f249c8d`.
  Subsequent release documentation does not change the qualified Swift sources.
- [Source hashes and generated artifact hashes](ALLOCATION_SOURCE_0.10.1.json):
  all 37 `Sources/JPEGLS` Swift files, including the shared contract code.
- Apple Swift 6.4 (`swiftlang-6.4.0.34.1`, `clang-2100.3.34.1`), language mode 6,
  `-O -whole-module-optimization`, target `arm64-apple-macos12`.
- Installed runtime: macOS 27.0.1, build 26A434; libswiftCore UUID
  `C9B36DA7-BB34-35AF-BC5D-91ECBCAA9ED0`; libsystem_platform UUID
  `080E4444-A0FB-3913-9756-4E470015F32F`.
- Normal runtime operation, with ARC override disabled and without runtime
  interposition, debugger or profiler hooks. Runtime identity and flags were
  inspected read-only. No runtime mutation or warm-up waiver was used.

## Selected allocation paths

The canonical parser has concrete cursor-only state and borrows encoded bytes.
Its qualified storage discards ancillary payloads without retaining arrays or
marker lists. Both entry points return scalar, nonthrowing outcomes, including
malformed-input and cancellation exits.

The concrete region consumer passes the image width as row stride and always
supplies the caller workspace. The shared kernel consequently disables the
owned gradient table. All five context buffers borrow caller memory and keep
nil owned-array slots. Array allocation, copy-on-write and generic metadata
helpers remain present in shared code, but are excluded by these actual branch
values. Shared-contract wrappers are not reachable from the qualified roots.
No selected Error witness lookup, throwing runtime call, allocated closure or
owned container is introduced.

The workspace remains **144,864 bytes**, including a **11,744-byte** context
region at offset **133,120**. Span capacity, alignment and overlap are checked
before use. Every invocation requires valid, disjoint borrows for encoded
input, samples and workspace. Failure or cancellation may leave partial output;
that output must be discarded.

Selected external operations are memory primitives, nil ARC releases and the
caller's optional synchronous C cancellation function. On the recorded runtime,
the memory primitive instruction regions and nil-release paths contain no
allocation. Owned-array cleanup and its indirect calls are excluded; they are
not classified as cancellation callbacks.

## Fixed stack bound

A separate assembly control-flow audit found 55 reachable module function bodies,
no recursive call cycles and no dynamic stack updates. All 74 stack-pointer
updates are fixed; downward updates cannot repeat within a function invocation.
The parser's computed jump table resolves entirely to same-function labels.

Conservative module-only bounds are **4,064 bytes** for inspection and
**5,712 bytes** for decoding. These include otherwise excluded owned branches
and conservatively charge both sides of tail calls. They exclude external
runtime/libc frames, application wrappers, cancellation callbacks, callback
reentrancy and worker stack backing. Applications must admit and charge their
complete execution storage separately.

## Functional validation

- [Linux Swift 6.2 CI](https://github.com/raster-labs/JLSwift/actions/runs/38556815445):
  1,129 tests in 89 suites, 95.86% source coverage, optimized Release with
  warnings treated as errors.
- Apple Swift 6.2.3: 136 focused tests in 10 suites and optimized Release with
  warnings treated as errors. The focused set covers caller storage, parser
  rejection, scan budgets, padded rows, destination lifetime and contract policy.
- Independent source, selected generated-code and fixed-stack reviews were
  performed. The repository-requested automated `code_review` and
  `codeql_checker` execution tools were unavailable; no security-scan result is
  claimed.

## Integration boundary

This is source- and profile-specific evidence. Different compilers, optimization
settings or runtimes need renewed allocation qualification. Source storage,
application control storage, callback work, concurrent operations, lifetime
retirement and total resident-memory accounting remain downstream obligations.
No total-process or universal out-of-memory guarantee is made.
