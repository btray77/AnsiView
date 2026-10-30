# swift-nio-ssh-bbs: patches on top of swift-nio-ssh 0.15.1

Upstream: https://github.com/apple/swift-nio-ssh, tag `0.15.1`, commit `d1985926494b624e751b379009dc83f3395fd88a`
(2026-10-26). Licence: Apache 2.0 (`LICENSE.txt`, unchanged). Upstream has no NOTICE file.

Purpose: let AnsiView's terminal reach classic BBS SSH servers (Synchronet and other cryptlib
servers, ENiGMA 1/2) as well as OpenSSH. See
`docs/superpowers/plans/2026-10-30-ansiview-2.0-ssh-compat.md` in the AnsiView repository.

To rebase: copy a newer upstream `Sources/NIOSSH` and `Tests/NIOSSHTests` over this folder, then
re-apply each hunk below (new files can be copied back as they are).

## Packaging

- `Package.swift`: renamed to `swift-nio-ssh-bbs`; only the `NIOSSH` library and `NIOSSHTests`
  are kept (the upstream `NIOSSHClient`, `NIOSSHServer` and `NIOSSHPerformanceTester` examples
  and `Benchmarks/` are left out); the unused `strictConcurrencyDevelopment` switch is removed.
