"""Platform-parity registry (PARITY.md). DATA ONLY; read by parity_guard.py.
Same schema and roles as ceyx native/scripts/ci/parity_registry.py.

role:
  adapter      same observable contract on every platform, OS API bound per platform
  accelerator  optional speed-up on a subset of platforms; output-identical and holds
               nothing past the call (PARITY.md clause 3)
  parked       a platform divergence outside the memory-reclamation campaign; reported
               to the user at campaign close, not fixed here
  fork-host    file still hosts a campaign fork listed in open_forks
open_forks: campaign fork ids (plan section 4). A milestone deletes ONLY its own ids,
in the same commit that removes the fork. Campaign end state: no open_forks anywhere.
"""

REQUIRE_CLOSED = False

REGISTRY: dict[str, dict] = {
    "lib/services/platform/file_retry.dart": {
        "guard_lines": 1, "role": "adapter",
        "contract": "comment-only match: documents that the retry loop is deliberately unconditional (no platform branch)"},
    "lib/views/layout/common/app_actions_menu.dart": {
        "guard_lines": 1, "role": "adapter",
        "contract": "Open Folder chord label: cmd-O on macOS, Ctrl+O elsewhere; the binding itself accepts both modifiers"},
    "lib/views/main_screen.dart": {
        "guard_lines": 2, "role": "parked",
        "contract": "mobile (Android/iOS) vs desktop layout surface selection; UI, not memory reclamation"},
    "lib/views/settings_dialog/shortcuts_tab.dart": {
        "guard_lines": 1, "role": "adapter",
        "contract": "shortcut chip label: cmd glyph on macOS, Ctrl elsewhere; bindings identical on every platform"},
}
