# Benchmark baseline

Run the fixed-workload core benchmarks from the repository root:

```sh
zig build bench -Doptimize=ReleaseFast
```

The command reports total time and nanoseconds per operation for:

| Workload | Fixed input |
| --- | --- |
| `ecs_query` | 10,000 entities with one component, 100 full query passes |
| `render_extract_cull_batch` | 2,000 sprites, 100 extract/cull/sort passes |
| `collision_pairwise` | 512 non-overlapping colliders, 100 pairwise passes |
| `asset_ztex_decode_64x64` | 1,000 decodes of a generated 64×64 RGBA ZTEX |

These are reproducible workloads, not performance guarantees. Results vary
with CPU, Zig version, optimization mode, thermal state, and background load.
Compare repeated runs on the same host/toolchain; do not use a single run as a
CI threshold. The asset workload measures decoding and allocation, not disk or
GPU upload latency.

## Initial local baseline

Captured 2026-11-03 with Zig 0.16.0 on Linux x86_64 (16 logical CPUs), using
`ReleaseFast`:

| Workload | Iterations | Total | Per iteration |
| --- | ---: | ---: | ---: |
| `ecs_query` | 1,000,000 entity visits | 2.004 ms | 2.0 ns |
| `render_extract_cull_batch` | 200,000 sprite visits | 7.965 ms | 39.8 ns |
| `collision_pairwise` | 100 passes | 20.851 ms | 208.5 µs |
| `asset_ztex_decode_64x64` | 1,000 decodes | 8.234 ms | 8.234 µs |

This is a local reference point, not a CI threshold or a cross-machine
performance claim. Re-run the command on the same host and record the
toolchain/host alongside any later comparison.
