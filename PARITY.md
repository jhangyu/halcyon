# Platform parity rule

## 多平台實作鐵律

- 同一功能在所有目標平台（Metal/Vulkan/CPU、macOS/Android/Windows/Linux）必須採同一實作方法，並在各平台完成實作與實跑驗證後才可落地；以平台 guard 走不同路徑、或悄悄退回舊路徑，即屬分岔，一律禁止。
- 唯一例外：有證據證明實作在該平台技術上不可達——必須停下呈報使用者，取得明示允許後才可分岔；agent 不得自行裁量。

The decree above (user-decreed 2026-09-19) is the rule. It is copied here verbatim because `.claude/` is gitignored
in this repo, and an untracked rule is invisible to other machines, sessions and CI. If
the two texts ever differ, the decree in .claude/CLAUDE.md wins, and this file is
corrected in the next commit. Everything below is HOW this repo enforces the decree; none
of it relaxes it.

## Enforcement

**Platform-specific implementation forks are FORBIDDEN.** Similar functionality is one
generic module or mechanism for every supported platform.

1. A platform ADAPTER is allowed only behind a shared interface whose observable behaviour
   is identical on every platform: the same call sites, the same return-value meaning, and
   the same telemetry counters moving on every leg.
2. A stub that returns 0 or "nothing to do" while the platform holds the equivalent
   resource somewhere else is a fork, not an adapter. "Does this object hold bytes here?"
   is the wrong question; ask "does this platform hold the equivalent bytes anywhere?"
3. An ACCELERATOR (an optional speed-up present on a subset of platforms) is allowed only
   if it is output-identical, holds no resource past the call, and every resource it does
   hold is reclaimed through the same shared mechanism as on every other platform.
4. Symbol presence is not parity. A behaviour claim needs a behavioural check: a counter
   or measurement that moves the same way on every leg.
5. Every platform conditional in in-scope code is registered in the parity registry
   (ceyx: native/scripts/ci/parity_registry.py; halcyon: scripts/ci/parity_registry.py)
   with its role and one-line contract. The parity guard fails CI on an unregistered
   conditional, on a changed count in a registered file, and on a stale entry.
6. Scope: ceyx native/src, native/include, plugin/lib; halcyon lib/. Tests, vendored
   trees, and Flutter's per-platform embedder directories are out of scope. The embedder
   memory adapters are named here: the memory-pressure OS signal sources
   (macos/Runner/AppDelegate.swift, windows/runner/halcyon_channels.cpp,
   linux/runner/halcyon_channels.cc) feed one Dart policy.
7. Decisions that authorise a platform difference are committed to the repo before the
   code that relies on them. A ruling that exists only in a chat or an uncommitted log
   does not authorise anything.
8. Behavioural parity tests are DEFAULT-ON and run by the local-only pre-push gate
   (ceyx: python3 native/scripts/ci.py prepush; halcyon: python scripts/ci.py prepush),
   which must be green before every push. Remote CI is compile-only and runs only the
   static guard (lint), per the ceyx decree "CI 純編譯鐵律" (user-decreed 2026-10-02,
   ceyx/.claude/CLAUDE.md). Never tag a parity test `manual:`. The decree's "run-verified
   on each platform before landing" is met locally on Windows/Vulkan and macOS/Metal
   (clause 9 states the Linux/Android limit).
9. Accepted limitation (user ruling 2026-10-03): Linux and Android are covered
   transitively. They share the Vulkan code path exercised on Windows, and remotely they
   are compile-only. This is a recorded limitation, not a registry entry. Any NEW
   platform difference still needs the decree's explicit user approval.
