# Release policy

The package is currently `0.1.0` and has not established a stable `1.0.0`
compatibility promise. Public API is the surface exported from `src/root.zig`;
backend modules not exported there are separate, target-specific APIs.

## Versioning and compatibility

- Keep the package version in `build.zig.zon` and `src/root.zig` identical.
- Before `1.0.0`, additive features and backward-compatible fixes use a patch
  increment; a documented public API or serialized-format break requires a
  minor increment and an `Unreleased` migration note.
- After `1.0.0`, follow SemVer: breaking public API or persisted-format
  changes increment major; compatible features increment minor; fixes increment
  patch.
- Preserve old scene readers when practical. If a format must change, document
  the old/new shape and migration path and add a fixture-based test.
- Pin Zig package dependencies by revision and lock hash. Update the toolchain
  minimum only with a tested migration and CI coverage.

## Release checklist

1. Review `CHANGELOG.md`; move completed entries under the release version and
   include migration instructions for breaking changes.
2. Update both version declarations and verify they match.
3. Run formatting, native build/tests, API docs, and the published target
   matrix from [platform support](./platform-support.md).
4. Run Linux GL/WGPU pixel regressions and live audio smoke tests where the
   required host/device is available; report unavailable checks explicitly.
5. Run `zig build scaffold-smoke` and verify a newly generated project's test
   target builds.
6. Run the fixed-workload benchmarks and record host/toolchain details when
   performance claims are part of the release.
7. Review pinned dependency changes, generated documentation, package paths,
   license notices, and the final Git diff.
8. Tag only after CI passes. Publish packages/releases only with explicit
   release authorization; this document does not trigger a publication.
