# M6 Cross-Platform DNG Master Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete the approved five-platform DNG architecture: Dart owns extraction and control flow, while one FFI RAW decoder renders valid preview-less DNGs on macOS, Windows, Android, iOS, and Linux.

**Architecture:** Work is split into four independently testable plans. Finish the Dart contract first; iOS and Linux decoder ports can then run in parallel in the sibling decoder repository; native-path deletion and five-platform closure run only after both ports and all gates pass.

**Tech Stack:** Flutter 3.44.6, Dart 3.12.2, `dart:io`, `dart:ffi`, C++17, CMake/Ninja, Halide 21, Metal, Vulkan, CocoaPods.

---

## Authoritative inputs

- Design: `docs/superpowers/specs/2026-08-24-m6-cross-platform-dng-design.md`
- Plan anchor: Halcyon commit `ce7983a`
- Decoder repository: sibling `../flutter_dng_decoder`
- Canonical valid preview-less sample: `local_data/photo_samples/DNG/2024-07-03-18-52-26.dng`
- Plugin smoke sample: `../flutter_dng_decoder/image_samples/lossless_dng_sample.dng` (expected full decode `4080x3056`)

The dirty files already present in the main worktree are external work. Implementers must stage only files named by the active task.

## Execution order

- [ ] **Plan 1 — Dart contract and cutover**

  Execute `docs/superpowers/plans/2026-08-24-m6-dng-dart-cutover-plan.md`.

  Exit gate: request-aware one-walk Dart inspection is authoritative; malformed input and valid no-preview DNG are distinct; valid no-preview DNG enters the shared decode-required path; no legacy OS fallback remains in `PhotoSource`; bridge-negative and decode-count tests pass.

- [ ] **Plan 2 — iOS FFI decoder port**

  Execute `docs/superpowers/plans/2026-08-24-m6-dng-ios-ffi-plan.md` in `../flutter_dng_decoder` plus Halcyon iOS build verification.

  Exit gate: iOS arm64 app binary statically contains all DNG C symbols, `flutter build ios --no-codesign` passes, and a physical-device run displays the canonical preview-less DNG.

- [ ] **Plan 3 — Linux FFI decoder port**

  Execute `docs/superpowers/plans/2026-08-24-m6-dng-linux-ffi-plan.md` on an x86-64 Linux Vulkan machine.

  Exit gate: the committed `.so` exports the C ABI, the plugin smoke test decodes `4080x3056`, Halcyon release bundle contains the `.so`, and the canonical preview-less DNG displays.

  Plans 2 and 3 may run concurrently after Plan 1's result contract is committed. They must not edit the same sibling-repository files concurrently: merge iOS native CMake changes before applying the Linux CMake changes, then rebase the second branch.

- [ ] **Plan 4 — Five-platform closure and native deletion**

  Execute `docs/superpowers/plans/2026-08-24-m6-dng-five-platform-closure-plan.md` only after Plans 1–3 are merged.

  Exit gate: macOS, Windows, Android, iOS, and Linux all display valid preview-less DNGs through the same Dart decision path; performance and packaging gates pass; macOS/Windows DNG policy code, `NO_EMBEDDED_PREVIEW`, `allowRawDecodeSignal`, and `DngPreviewExtractor.swift` are deleted.

## Global stop conditions

Stop the active plan and report evidence instead of patching one platform when any of these occurs:

- a valid canonical DNG fails only on one supported target;
- Dart extraction exceeds the preregistered 2x limit;
- an embedded path invokes RAW decode, a platform channel, or re-encode;
- a deferred path invokes the decoder;
- an expensive path invokes the decoder more than once;
- iOS/Linux packaging requires a platform-specific product fallback;
- a cleanup task begins before its zero-call-site and rollback gates pass.

A stop never authorizes restoring the Swift extractor. Fix the shared Dart or FFI implementation, then re-run the same gate.
