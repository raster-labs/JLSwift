# Changelog

All notable changes to JLSwift will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.10.1] - 2026-10-14

### Fixed

- Make shared-contract preflight reject unsupported required backend, metadata,
  progress and transform policies instead of silently ignoring them. Report
  preferred-backend fallback and align inspection with 2–16-bit decode precision.

- Reject repeated, missing, or mixed component scans before allocating decoded
  sample planes, so extra scans cannot bypass the sample-storage budget.
- Revalidate caller-provided destinations against each decode operation's limits
  and use the same byte origin when parsing and decoding sliced `Data`.
- Preserve main's shared image contract and padded-row destinations alongside
  nonthrowing caller-owned decoding through one reconstruction kernel.
- Add scan, arithmetic, padding, storage-lifetime and contract boundary regression
  coverage. CI now retains its coverage report and builds optimized Release with
  warnings treated as errors.

### Validation

- Linux Swift 6.2: 1,129 tests in 89 suites, 95.86% source coverage, and optimized
  Release with warnings treated as errors.
- Swift 6.2.3: 136 focused tests in 10 suites and optimized Release with warnings
  treated as errors. The focused set covers caller storage, padded rows, parser
  rejection, scan topology, destination lifetime and contract policies.
- Source-specific allocation qualification is recorded in
  `docs/ALLOCATION_QUALIFICATION_0.10.1.md`. Application callback, stack and total
  resident-storage accounting remain separate integration obligations.

## [0.10.0] - 2026-10-14

### Added

- Caller-owned monochrome inspection and decoding through `inspectMonochromeQualified` and `decodeMonochromeQualified`, with nonthrowing scalar outcomes and borrowed cancellation callbacks.
- Fixed parser and decoder workspace, caller-owned UInt16 output, and capacity, overlap, cancellation, malformed-input, restart, mapping, and workspace-reuse checks.

### Changed

- Reuse the canonical marker grammar and numerical kernels across qualified and legacy APIs. Existing throwing methods retain their error and Task cancellation behavior.
- Keep compiler/runtime, execution-stack, callback, source and application control-storage qualification explicit; the caller-storage API is not a total-process memory guarantee.
- Report the library version from the CLI.

### Validation

- Swift 6.2.3: 1,067 tests in 84 suites passed; source line coverage 7,308/7,658 (95.43%); optimized Release passed with warnings treated as errors.
- Selected Swift 6.4 optimized SIL, assembly and installed macOS runtime paths were reviewed for the caller-storage allocation contract. Other compiler/runtime configurations require their own allocation qualification.

## [0.10.0-rc.1] — 2026-09-21 (release candidate)

### Added

- **Shared-contract image layer.** A validated `ImageDescriptor`, leased read-only
  and writable storage with an explicit one-shot lifecycle, `Image`,
  `ImageDestination`, `ResourceLimits`, `CopyPolicy` and an operation report,
  wired to the existing codec. Implements the suite's common memory and
  ownership contract at revision 0.7.0.
- Under `CopyPolicy.requireSharedStorage` samples stay in the caller's own
  allocation in both directions, honouring the caller's row stride and plane
  offset. Padding between the row payload and `rowBytes` is never read or
  written, so it cannot reach the codestream and caller sentinels survive.

### Changed

- The encode and decode sample stages are now each a single function called by
  both the ordinary path and the shared-storage path, so the two cannot drift.
  Output is unchanged: the contract surface encodes byte-identically to the established encoder.

### Notes

The existing public API is untouched and the deployment floor is unchanged;
this release adds a surface beside it rather than replacing it. The shared
surface covers the initial shared layout only — one plane, one component,
unsigned 16-bit, little-endian, even `rowBytes >= width * 2`, no subsampling,
lossless. Anything else is reported as an incompatibility rather than silently
converted.

**This is a release candidate, not a stable release.** The suite's release
gates have not been executed: there is no continuous-integration verification
(the organisation's Actions billing is locked, so every job reports zero steps
run), no fuzz campaign, and no benchmark evidence from controlled hardware.
Everything recorded below was measured on a single developer machine.

**Verified locally:** 1,055 tests in 81 suites pass, of which 1,041 are the
existing suite unchanged. Byte-identical codestreams at three sizes and three
row paddings and with a non-zero plane offset. Clean under the address and
thread sanitizers. Builds on Swift 6.2.4 and 6.4.0.


## [0.9.3] - 2026-10-12

### Fixed

- Bound compressed input, effective LSE dimensions, and all decoded sample planes before allocation through `JPEGLSDecoder.Limits`.
- Reject truncated, concatenated, and trailing codestream data; allow the single legal even-length DICOM pad byte.
- Publish from the 0.9 stable line without the separate shared-storage release candidate APIs.

## [0.9.2] - 2026-09-22

### Fixed

- **Fill bytes before markers.** ITU-T T.81 B.1.1.2 (inherited by T.87) allows
  any number of 0xFF fill bytes before a marker. CharLS (DCMTK `dcmcjpls`)
  writes one before EOI whenever the entropy coder's final byte is 0xFF, and
  the parser read `FF FF D9` as an unknown marker with a length field, failing
  with "premature end of bitstream" on such single-row DICOM frames.
  `JPEGLSParser` and `JPEGLSBitstreamReader.readMarker` now skip fill bytes;
  the scan body already excluded them. Regression tests carry the CharLS
  streams.

## [0.9.0] - 2026-06-11

### Added
- **Restart-interval support (DRI/RSTm)**: opt-in `Configuration.restartInterval`
  (and `jpegls encode --restart-interval N`) writes a DRI segment and emits
  RSTm markers every N lines for lossless non-interleaved scans. Per
  ITU-T.87, every interval restarts coding as at scan start, so intervals
  encode **and** decode in parallel across cores (4096×4096 16-bit: encode
  0.84 s → 0.31 s, decode 0.69 s → 0.24 s wall, ~+0.03 % size)
- `jpegls batch encode`/`batch decode` implemented (they were
  "not yet implemented" stubs on top of the existing worker pool); batch
  encode output is byte-identical to serial encodes
- Restart-interval test suite (round-trips, marker cycling, DRI parsing,
  determinism, multi-component scans, configuration validation)

### Changed
- **Hot-path performance rewrite** (encoded bitstreams remain byte-identical;
  verified against a 44-artifact golden gate and the full conformance suite):
  - Bitstream writer: `[UInt8]` backing with a 64-bit accumulator (was
    per-byte Foundation `Data` appends with a 32-bit accumulator)
  - Bitstream reader: 64-bit window over `[UInt8]` with multi-byte refill and
    `leadingZeroBitCount` unary decode (was per-bit reads via `Data`
    subscripts)
  - Encoder scan loops: per-pixel `Dictionary` neighbour lookups hoisted out;
    gradients quantised once per pixel; lossless non-interleaved scans run
    over a flat contiguous `UInt16` plane through unsafe buffers
  - Decoder scan loops: same flat-plane treatment; decoder gained the
    encoder's init-time gradient quantisation table
  - Context model: A/B/C/N packed into one record array (one load + one store
    per pixel); bias C, Golomb k, and the k = 0 correction come from a single
    record read
  - Run detection: unrolled exact-equality scan for lossless
  - Parser records scan-body byte ranges, removing the decoder's second
    full-file marker walk; decoder results skip the redundant O(W·H)
    re-validation pass (with the ITU-T.87 C.2.4.1.1 MAXVAL ≤ 2^P−1 check
    added at parse time)
  - Measured on real radiology DICOM (107 frames, 6 modalities, lossless):
    encode 27 → 80 MB/s, decode 41 → 84 MB/s aggregate; synthetic 16-bit
    2048²: encode 37 → 98 MB/s, decode 57 → 104 MB/s
- CLI raw output accumulates in `[UInt8]` instead of per-byte `Data.append`
  (33 MB decode-to-raw: 2.0 s → 0.7 s)

### Fixed
- **Restart-marker streams decode correctly**: the parser and scan extractor
  previously treated RST markers (FFD0–FFD7) as scan terminators, truncating
  conformant streams at the first restart marker
- Encoder no longer allocates and zeroes a full-frame reconstruction buffer
  for lossless scans (it is only read for near-lossless); ~32 MB transient
  saved per 2048² scan, ~136 MB for a 17 MP mammography frame
- Robustness fixes from the branch security/correctness review:
  - `decode(_:)` rebases `Data` slices with non-zero `startIndex` (slices
    previously mis-sliced scan ranges — silent wrong pixels or a trap)
  - Encoder rejects sub-sampled component planes up front (previously an
    out-of-bounds read in release builds) and preset MAXVAL > 2^P−1
    (previously a trap or an unparseable stream)
  - Decoder requires every frame component to have a scan, applies the DRI
    in effect at each SOS (T.81 B.2.4.4 per-scan semantics), accepts
    interleaved streams whose DRI ≥ height (no actual markers), and rejects
    stray RSTm markers in scans without an active restart interval
    (previously absorbed silently as entropy data)
  - Parser rejects undersized LSE segments and dimension products that
    overflow (crafted LSE type-4), both previously uncatchable traps

### Removed
- **The entire `Platform/` acceleration layer** (Metal, Vulkan, Accelerate,
  ARM64/x86-64 SIMD wrappers, ~4,400 lines), plus `JPEGLSBufferPool`,
  `JPEGLSCacheFriendlyBuffer`, and `JPEGLSTileProcessor`: profiling showed
  none of it was invoked on the codec hot path, and the GPU kernels could not
  produce conformant streams (JPEG-LS entropy coding is sequential by
  construction). Restart intervals are the supported parallelism mechanism.
  Docs and README updated to describe only what ships.

## [0.8.0] - 2026-05-30

### Added

#### Validation & Conformance (Milestone 8)
- JPEG-LS validation corpus (later replaced by Raster-authored generated vectors)
- JPEG-LS conformance and regression suite with 589 tests
- Defensive low-valued continuation handling (0xFF60-0xFF7F) in parser
- TestFixtureLoader utility for PGM/PPM format parsing
- Comprehensive performance benchmark suite (18 benchmarks)
- Performance timing framework with throughput calculation (MB/s, Mpixels/s)
- Cross-platform memory tracking (macOS/iOS)
- Benchmarks for various image sizes (256x256 to 4096x4096)
- Benchmarks for various bit depths (8-bit, 12-bit, 16-bit)
- Benchmarks for various component counts (greyscale, RGB)
- Near-lossless benchmarks (NEAR=3, NEAR=10)
- Interleaving mode benchmarks (none, line, sample)
- Content-type-specific benchmarks (flat, gradient, medical-like)
- Comprehensive edge case test suite (EdgeCasesTests.swift) with 38 tests
- Boundary condition tests (MAXVAL, NEAR, dimensions)
- Invalid parameter combination tests
- Memory pressure scenario tests

#### Documentation (Milestone 9)
- Comprehensive DocC documentation for all public APIs
- GETTING_STARTED.md guide with installation and quick start examples
- PERFORMANCE_TUNING.md guide covering hardware acceleration and optimisation
- TROUBLESHOOTING.md guide with solutions for common issues
- USAGE_EXAMPLES.md with 25+ real-world standalone examples
- SWIFTUI_EXAMPLES.md with SwiftUI integration patterns for iOS/macOS
- APPKIT_EXAMPLES.md with AppKit integration patterns for macOS
- Man page documentation (man/jpegls.1) in groff format
- Man page installation instructions in README

#### DICOM Test Harness & Tooling
- `jpegls bench-dicom` command: JPEG-LS round-trip benchmark over a DICOM corpus, reporting per-modality encode/decode throughput and lossless verification
- First-mismatch diagnostics on `bench-dicom` lossless failures (reports row/col and decoded vs original sample value, written to stderr)

#### DICOM Independence & Final Integration (Milestone 20)
- Non-DICOM usage examples in USAGE_EXAMPLES.md (general-purpose compression, web assets, archival storage)
- DICOM-aware/DICOM-independent architecture documented in README.md

### Changed
- Overall project test coverage measured at 95.80% on Linux x86_64 (exceeds 95% threshold)
- Coverage varies by platform due to conditional compilation of platform-specific optimisations
- README.md updated with accurate coverage measurements and platform notes
- README.md updated with links to new documentation guides
- MILESTONES.md updated to reflect progress on Milestone 8 and 9
- Reorganised repository layout: documentation moved into `docs/`, man page into `man/`
- Renamed executable target `jpegls` → `jpeglscli` to avoid a case-insensitive-filesystem collision with the `JPEGLS` library target (the built product is still named `jpegls`)

### Fixed
- Parser now handles streams containing low-valued standalone continuation codes
- All 12 legacy validation vectors could be parsed without errors
- Build & test compilation on case-insensitive (Apple) filesystems
- `SIMDMask.any()` build error on ARM64 (replaced with an equality check)
- Metal GPU path now works under `swift build`/`swift test`: when no precompiled `default.metallib` is present (SwiftPM copies the `.metal` source rather than compiling it), `MetalAccelerator` compiles the bundled shader source at runtime instead of failing with "no default library was found"
- `ARM64Accelerator.computeGolombRiceParameter` now clamps the result to the documented `[0, 31]` range for pathological `a/n` ratios (previously could return an unclamped value; now matches `X86_64Accelerator`)
- `MetalAccelerator.computeGradientsBatch` CPU fallback now uses wrapping subtraction to match the GPU shader's two's-complement semantics, keeping the two paths bit-identical and preventing a trap on extreme `Int32` inputs (e.g. `0 - Int32.min`)

#### DICOM Independence & Final Integration (Milestone 20)
- Fixed incorrect threshold values in `JPEGLSPresetParametersTests` for 8-bit and 12-bit images; test expectations now match the ITU-T.87 Table C.2 formula (8-bit: T1=3, T2=7, T3=21; 12-bit: T1=18, T2=67, T3=276)
- Fixed incorrect expected values in `JPEGLSNearLosslessTests` for reconstructed-value boundary tests; test inputs now avoid the ITU-T.87 modular-wrap threshold, correctly exercising the clamp-to-MAXVAL and clamp-to-zero paths

## [0.7.0] - Completed

### Added

#### Command-Line Interface (Milestone 7)
- `jpegls info` command for displaying file information
  - Human-readable output format
  - JSON output format with `--json` flag
  - Quiet mode with `--quiet` flag (single line output)
  - Displays frame header (dimensions, bits per sample, components)
  - Displays scan headers (interleave mode, NEAR parameter)
  - Displays preset parameters if present
  - Calculates compression statistics
- `jpegls verify` command for file integrity validation
  - Validates file structure (SOI, SOF, SOS, EOI markers)
  - Validates frame header parameters
  - Validates scan header consistency
  - Validates preset parameters
  - Verbose mode with `--verbose` flag
  - Quiet mode with `--quiet` flag (no output on success)
- `jpegls encode` command (argument parsing complete, bitstream I/O pending)
  - Input/output file path specification
  - `--width`, `--height` dimension parameters
  - `--bits-per-sample` parameter (2-16 bits)
  - `--components` parameter (1 or 3)
  - `--near` parameter for near-lossless encoding (0-255)
  - `--interleave` mode selection (none, line, sample)
  - `--color-transform` selection (none, hp1, hp2, hp3)
  - `--preset` parameter parsing (T1, T2, T3, RESET)
  - `--verbose` and `--quiet` output modes
- `jpegls decode` command (argument parsing complete, bitstream I/O pending)
  - Input/output file path specification
  - `--format` output format selection (raw, png, tiff)
  - `--verbose` and `--quiet` output modes
- `jpegls batch` command for batch processing
  - Support for glob patterns (`*.jls`, `images/*.raw`)
  - Directory scanning for batch operations
  - Parallel processing with configurable `--parallelism`
  - Progress reporting with `--verbose` mode
  - Error handling with optional `--fail-fast` mode
  - Support for info, verify, encode, and decode operations
- `jpegls completion` command for shell completions
  - Bash completion script generation
  - Zsh completion script generation
  - Fish completion script generation
  - Installation instructions in help text
- Comprehensive help messages for all commands with examples
- Mutual exclusivity validation for `--verbose`/`--quiet` and `--json`/`--quiet`
- ValidationError type for consistent CLI argument validation
- Comprehensive CLI argument parsing test suite (CLIArgumentParsingTests.swift)
  - 60 tests organised into 11 test suites
  - Tests for all commands (encode, decode, info, verify, batch, completion)
  - Tests for flag combinations and mutual exclusivity
  - Parameter validation tests (width, height, bits-per-sample, NEAR, etc.)
  - Edge case testing for boundary values
  - Overall project coverage maintained at 96.08%

## [0.6.0] - Completed

### Added

#### Memory Optimisation (Milestone 5.4)
- `JPEGLSBufferPool` for reusable buffer management
  - Thread-safe buffer acquisition and release
  - Support for multiple buffer types (context arrays, pixel data, bitstream)
  - Automatic cleanup of expired buffers
  - Shared global pool via `sharedBufferPool`
  - 11 comprehensive tests
- `JPEGLSTileProcessor` for tile-based processing of large images
  - Configurable tile size and overlap
  - Memory savings estimation
  - Support for images larger than available memory
  - 16 comprehensive tests
- `JPEGLSCacheFriendlyBuffer` with contiguous memory layout
  - Row-major order for cache efficiency
  - Optimised neighbour access patterns
  - Batch row access for vectorised operations
  - 22 comprehensive tests

## [0.5.0] - Completed

### Added

#### Apple Silicon Optimisation (Milestone 5)
- `ARM64Accelerator` with NEON/SIMD optimisations
  - NEON-optimised gradient computation
  - NEON-optimised MED prediction
  - NEON-optimised context quantisation
  - Uses Swift SIMD4 types for vectorised operations
  - Compiles to native NEON instructions on Apple Silicon
  - Bit-exact results verified by comprehensive tests
- `X86_64Accelerator` with SSE/AVX optimisations
  - SSE/AVX-optimised gradient computation
  - SSE/AVX-optimised MED prediction
  - SSE/AVX-optimised context quantisation
  - Uses Swift SIMD4 types for vectorised operations
  - Compiles to SSE/AVX instructions on Intel processors
  - Bit-exact results verified by comprehensive tests
- `AccelerateFrameworkAccelerator` using Apple's vDSP library
  - Batch gradient computation for multiple pixels
  - Statistical analysis (mean, variance, standard deviation, min/max)
  - Histogram computation for image analysis
  - Batch vector operations (addition, subtraction, scalar multiplication)
  - 50+ comprehensive tests
  - Performance benchmarks comparing Accelerate vs scalar
- Platform abstraction protocols for clean separation
  - `PlatformAccelerator` protocol
  - Conditional compilation for architecture-specific code
  - Benchmarks for platform performance comparison
- Comprehensive test suite with 100% coverage for platform code

#### x86-64 Implementation (Milestone 6)
- Separate x86-64 module with clear boundaries
- All x86-64 code conditionally compiled with `#if arch(x86_64)`
- X86_64_REMOVAL_GUIDE.md with step-by-step removal instructions
- Documentation of all x86-64 files and dependencies
- Cross-platform compatibility tests
- Bit-exact output verification between ARM64 and x86-64
- 100% test coverage for x86-64 code paths (78/78 lines)

## [0.4.0] - Completed

### Added

#### Multi-Component & Interleaved Encoding (Milestone 3.4)
- Component interleaving modes (None, Line, Sample)
- Multi-component frame handling
- `PixelBuffer` abstraction for multi-component pixel access
- Line-interleaved encoding implementation
- Sample-interleaved encoding implementation
- 14 comprehensive tests covering all interleaving modes
- 100% test coverage for interleaved encoding

#### Multi-Component Decoding (Milestone 4.4)
- Deinterleaving for all modes (None, Line, Sample)
- Component reconstruction from interleaved data
- Colour transformation inverse operations
- 92.10% test coverage for multi-component decoding

## [0.3.0] - Completed

### Added

#### JPEG-LS Decoder (Milestone 4)
- `JPEGLSParser` for JPEG-LS file format parsing
  - Marker segment parsing and validation
  - Frame header decoding
  - Scan header decoding
  - Preset parameter table decoding
  - Extension marker handling
  - 100% test coverage for parsing
- Regular mode decoding
  - Prediction reconstruction using MED
  - Golomb-Rice decoding
  - Prediction error recovery with bias correction
  - Context state reconstruction
  - Sample value computation with clamping
  - 96.90% test coverage
- Run mode decoding
  - Run-length decoding logic
  - Run interruption sample decoding
  - Run mode context reconstruction
  - 100% test coverage

## [0.2.0] - Completed

### Added

#### JPEG-LS Encoder (Milestone 3)
- Regular mode encoding
  - Gradient computation for mode detection
  - MED (Median Edge Detector) prediction
  - Prediction error computation with modular reduction
  - Golomb-Rice parameter estimation (k calculation)
  - Golomb-Rice encoding of prediction errors
  - Context-based bias correction
  - 100% test coverage
- Run mode encoding
  - Run-length detection logic
  - Run-length encoding with interruption samples
  - J[RUNindex] mapping table
  - Run mode context updates
  - Run-length limit handling
  - 100% test coverage
- Near-lossless encoding
  - NEAR parameter handling (error tolerance 1-255)
  - Quantised prediction error calculation
  - Reconstructed value computation for decoder tracking
  - Modified threshold parameters for near-lossless
  - Error bounds compliance validation
  - 98.14% test coverage

## [0.1.0] - Completed

### Added

#### Project Foundation (Milestone 1 & 2)
- Swift Package Manager manifest (Swift 6.2+)
- Project structure: `Sources/`, `Tests/`
- GitHub Copilot instructions (`.github/copilot-instructions.md`)
- CI pipeline with GitHub Actions
- >95% test code coverage enforcement in CI
- Initial documentation (README.md, MILESTONES.md)

#### JPEG-LS Foundation (Milestone 2.1 & 2.2)
- Project architecture with separate targets
  - `JPEGLS` library target
  - `jpegls` command-line tool target
- Directory structure:
  - `Sources/JPEGLS/Core/` — Core codec types and protocols
  - `Sources/JPEGLS/Encoder/` — Encoding implementation
  - `Sources/JPEGLS/Decoder/` — Decoding implementation
  - `Sources/JPEGLS/Platform/` — Platform-specific optimisations
  - `Sources/JPEGLS/Platform/ARM64/` — Apple Silicon / ARM NEON code
  - `Sources/JPEGLS/Platform/x86_64/` — x86-64 specific code
  - `Sources/jpeglscli/` — CLI tool source
- JPEG-LS marker segment types (SOI, EOI, SOF, SOS, LSE, etc.)
- `JPEGLSFrameHeader` structures per ITU-T.87
- `JPEGLSScanHeader` structures
- `JPEGLSPresetParameters` (MAXVAL, T1, T2, T3, RESET)
- Colour transformation types (None, HP1, HP2, HP3)
- `JPEGLSError` type with comprehensive error codes
- `JPEGLSBitstreamReader` and `JPEGLSBitstreamWriter` utilities
- 96.24% test coverage for core types

#### Context Modelling (Milestone 2.3)
- Context quantisation (Q1, Q2, Q3 gradient calculations)
- Context index computation (365 regular contexts)
- Run-length context handling
- Context state management (A, B, C, N arrays)
- Context initialization with default parameters
- Context update and adaptation logic
- 96.88% test coverage for context modelling

## Release Notes Format

See [RELEASE_NOTES_TEMPLATE.md](docs/RELEASE_NOTES_TEMPLATE.md) for the release notes template used for GitHub releases.

## Version History

- **0.1.0** - Project foundation and JPEG-LS core types
- **0.2.0** - JPEG-LS encoder (regular mode, run mode, near-lossless)
- **0.3.0** - JPEG-LS decoder (parsing, regular mode, run mode)
- **0.4.0** - Multi-component support (RGB, interleaving)
- **0.5.0** - Platform optimisation (ARM64, x86_64, Accelerate)
- **0.6.0** - Memory optimisation (buffer pooling, tile processing)
- **0.7.0** - CLI tool (info, verify, encode, decode, batch, completion)
- **0.8.0** - Validation and conformance (regression vectors, benchmarks, edge cases)
- **0.9.0** - Hot-path performance rewrite, restart-interval parallelism, acceleration-layer removal
- **1.0.0** - Planned stable release

[Unreleased]: https://github.com/Raster-Lab/JLSwift/compare/v0.9.0...HEAD
[0.9.0]: https://github.com/Raster-Lab/JLSwift/releases/tag/v0.9.0
[0.8.0]: https://github.com/Raster-Lab/JLSwift/releases/tag/v0.8.0
