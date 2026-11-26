# Bikemap integration artifact

This branch includes the Rust XCFramework so a SwiftPM consumer can build
without a sibling checkout or an installed Rust toolchain.
The archive is committed directly to this integration branch.
It does not require Git LFS, a GitHub release, or a separate artifact download.

- Source revision: `8051c21e185b3c9db40009e78d918cacf6c3e19c`.
- Rust source tree (`git rev-parse HEAD:common`): `0cc33a42c82900903e331ef8348a3238aed97388`.
- Rust compiler: `rustc 1.97.0 (2d8144b78 2026-07-07)`.
- Build: `cd common && ./build-ios.sh`, using that compiler's installed iOS targets.
- Platforms: arm64 iOS device; arm64 and x86_64 iOS Simulator.
- Archive SHA-256: `bd8b6489e3d828e850d50aa4e8e1006dbe9160805d64cbcb744f34d726410cbb`.
- `common/Cargo.lock` SHA-256: `e527c7c2fe8a565431780e5f374145918a92876ba227e27f62c99a550af5eca3`.
- Generated Swift bindings SHA-256: `399478279c7683be54c04a446b976705cf91b2082868dfc79ca33a6fb1aa97c8`.

Regeneration updated the Swift documentation for the step-advance condition.
The selected sources include the short-tail step-exit, retraced U-turn,
and JSON round-trip fixes.
Using the upstream 0.59.0 artifact would omit those fixes.

When Rust sources or bindings change, rebuild and replace the archive together.
From the repository root after the standard build:

```sh
ditto -c -k --keepParent common/target/ios/libferrostar-rs.xcframework \
  Binaries/libferrostar-rs.xcframework.zip
swift package compute-checksum Binaries/libferrostar-rs.xcframework.zip
```

Update this provenance and verify the consumer build with the replacement.
This packaging and the fork dependency belong only to the integration branch;
keep them out of the focused upstream PR branches.
