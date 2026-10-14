# Caller-owned monochrome decode storage

Local candidate based on JLSwift 0.9.3. The existing owned API remains available.

`inspectMonochrome` and `decodeMonochrome` borrow encoded bytes and fixed aligned
caller scratch. Decode writes unsigned UInt16 samples in host byte order directly
into caller storage. All spans must be disjoint, exclusive and alive for the
synchronous call. Failed or cancelled output is not publishable.

The canonical parser has a storage policy that borrows marker/entropy payloads,
retains bounded scalar descriptors and collects only the selected reachable mapping
values. The canonical flat kernel reuses caller adaptive context storage. Restart
regions decode serially; their payloads and output planes are not copied into an
unbounded array of regions. Final mapping-table and preset semantics are preserved.
The API's byte limit counts UInt16 output, rather than the legacy Int sample plane.

Scratch is 144,864 bytes on supported 64-bit platforms: 256 Int table widths,
65,536 UInt16 reachable palette values and 11,744 bytes of adaptive context. The
result includes precision, NEAR, point transform, mapping selection/presence and
color transformation. These facts allow DICOMKit's existing narrow precision
recovery policy to remain unchanged; empty borrowed parser collections are not
proof that a source had no mapping metadata.

Only one-component, one non-interleaved scan is supported by this additive API.
Legacy color paths do not become accounted and are not used as a fallback. The
shared context representation retains value semantics for existing owned copies.

Full suite and golden encode/decode parity are required for representational
changes. Caller-storage tests also cover restarts, final mapping/preset replacement,
malformed input, capacity/overlap and cancellation. Runtime, parser/control and
error allocations are explicitly outside this payload-only capacity declaration;
complete admission requires separate qualification and lifetime ownership.
