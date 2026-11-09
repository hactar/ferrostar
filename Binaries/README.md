# Bikemap integration artifact

This branch includes the Rust XCFramework so a SwiftPM consumer can build
without a sibling checkout or an installed Rust toolchain.
The archive is committed directly to this integration branch.
It does not require Git LFS, a GitHub release, or a separate artifact download.

- Source revision: `55b90b8eb36fc4f6830a229fc365dbf798ba2466`.
- Rust source tree (`git rev-parse HEAD:common`): `14705c1c3173aa75ced35d5658a1a5c78177a697`.
- Rust compiler: `rustc 1.97.0 (2d8144b78 2026-07-07)`.
- Build: `cd common && ./build-ios.sh`, using that compiler's installed iOS targets.
- Platforms: arm64 iOS device; arm64 and x86_64 iOS Simulator.
- Archive SHA-256: `201abd768e1213088183cdb2eb0442121fe447ac5861b90b9da322db9726f56c`.
- `common/Cargo.lock` SHA-256: `e527c7c2fe8a565431780e5f374145918a92876ba227e27f62c99a550af5eca3`.
- Generated Swift bindings SHA-256: `d3132184a3e43cd507d3464cdb7576b5372fc7b0e266c1045f1b5e306abc9c67`.

The rebuild left the committed generated Swift bindings unchanged.
The selected sources include the short-tail step-exit and JSON round-trip fixes.
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
