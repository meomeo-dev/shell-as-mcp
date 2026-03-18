# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog, and this project follows Semantic Versioning (SemVer).

## [Unreleased]

### Added
- Added regression command `make regress-pack-smoke` to run build + pack + strict streamable-http handshake smoke checks.
- Added bundle-level and per-target smoke test scripts for `ass`, `brew`, `ffmpeg`, `host_info`, `runprompt`, `shell`, and `ytdlp` bundles.
- Added lint gate `validate_tested_has_smoke_test.sh` and integrated it into `scripts/lint/lint_all.sh`.
- Added streamable-http e2e test coverage for MCP initialize and tools/list flow.

### Changed
- Updated streamable-http server transport to generate session IDs via UUID and emit transport errors to stderr.
- Updated ytdlp scripts to disable update check (`--no-update`) and aligned transcript output directory fallback behavior.
- Updated runprompt type-spec docs and README to align tested-target smoke-test conventions and regression workflow docs.

### Notes
- This changelog entry corresponds to commit `c5cb7be` on 2026-03-18.
