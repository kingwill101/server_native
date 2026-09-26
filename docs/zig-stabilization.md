# Zig stabilization

Keep fixes on `fix/zig-ci-stabilization` until the draft PR is ready for review.
The starting baseline is `e3e2ba9` on `main`. Local passes do not replace hosted
CI evidence. Preserve SDK/direct/bridge parity and existing benchmark thresholds.

## Hosted baseline: 2026-09-26

| Workflow | Result | Evidence |
| --- | --- | --- |
| Framework compatibility | All four Shelf/Relic SDK/native jobs passed | [Run](https://github.com/kingwill101/server_native/actions/runs/36239341121) |
| HTTP/3 integration | Passed | [Run](https://github.com/kingwill101/server_native/actions/runs/36239341097) |
| server_native CI | Incomplete streamed bridge response failed | [Run](https://github.com/kingwill101/server_native/actions/runs/36239341048) |
| Zig CI | Same response failure | [Run](https://github.com/kingwill101/server_native/actions/runs/36239341107) |
| Benchmark gate | Throughput and p95 thresholds failed | [Run](https://github.com/kingwill101/server_native/actions/runs/36239341108) |

## Blockers

- [ ] Fix failure handling after HTTP/1 response headers have been sent. The
  missing-response-end test receives a chunk-parser error (`72 is expected to
  be a Hex digit`), indicating unexpected bytes in the chunk stream. Check all
  error handlers before deciding whether the old 502 expectation remains valid.
  Before headers are committed, preserve valid gateway-error responses; after
  commitment, validate truncated-stream behavior against `dart:io`.
- [ ] Diagnose hosted benchmark performance. The baseline native/reference
  throughput ratio is 0.623 (minimum 0.70); p95 ratio is 2.387 (maximum 1.60).
  Reproduce with the workflow's 2,500 requests, concurrency 64, 300 warmups,
  and three iterations. Do not weaken the gates to obtain a pass.
- [ ] Keep all SDK/direct/bridge regression tests and both framework modes green.
- [ ] Obtain passing results for all five workflows on the same PR head SHA.
- [ ] Review the accumulated implementation changes before marking the PR ready.

## Updating this record

Add reproduction commands, scoped fixes, and validation results as commits land.
Record hosted run links and the tested commit; distinguish a failed assertion,
implementation defect, and environment failure. Serinus is outside the maintained
compatibility matrix; Relic coverage targets version 2 RC and later releases.
