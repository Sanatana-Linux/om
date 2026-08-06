# Nina — Fable Audit 2026-07-02 — Resolution Log

Companion to `docs/fable-audit-2026-07-02.md` (left intact as the historical
audit record — do not edit that file). This document tracks how each of the
26 findings was resolved during the 9-wave fable audit fix campaign that
followed the audit, plus one pre-campaign prerequisite fix that materially
affects how much to trust pre-campaign "tests passed" claims.

Campaign checkpoint: `[bb0d3179140c]` "before fable audit fix campaign"
(dev lane). Source of truth for save ids: `LOG.md` (rolling window, currently
covers the full campaign) cross-referenced with `.agent/CONTINUITY.md`.

---

## Pre-campaign prerequisite: the `zig build test` blind spot

Before Wave 2 could be trusted, a test-infrastructure gap was found and
fixed: `zig build test` only discovered `test { ... }` blocks reachable from
`src/main.zig`, and `main.zig` never called `std.testing.refAllDecls(@This())`.
Test blocks in `exec.zig`, `commands.zig`, `errors.zig`, `config.zig`, and
`types.zig` were never compiled or run — the test count was stuck at 12
regardless of how many tests existed. This means **every pre-campaign
CONTINUITY/commit claim of "zig build test passed" for changes touching
those files was not actually verified by the runner** — the tests existed
and looked green in isolation but were never invoked.

- Checkpoint: `[24d1416a4765]` "before wiring refAllDecls into zig build test"
- Fix + fallout (fixed pre-existing leaks in `errors.zig`/`config.zig` test
  blocks surfaced by the newly-running tests): `[64b6755254d1]`
- Documentation of the gap in CONTINUITY.md: `[74c9cc1a35ab]`

Test count after this fix: 45 (was 12), zero leaks. It climbed to 73 by the
end of the campaign as later waves added regression coverage.

---

## Findings

| ID | Description | Status | Save id(s) |
|----|---|---|---|
| NINA-001 | Streamed build stderr concatenated with no newlines, degrading error translation | resolved | `2d2b5035db17` |
| NINA-002 | Streamed stderr loop abandons the pipe on `StreamTooLong`, can deadlock the child | resolved | `2d2b5035db17` (same save as NINA-001 — one combined fix) |
| NINA-003 | Remote (`--on`) execution loses argv discreteness through the remote shell | resolved | `08ace490d251` |
| NINA-004 | Self-update downloads to a fixed, predictable `/tmp` path | resolved | `d4dd5ae4eb6e` |
| NINA-005 | `confirm()` defaults to YES on EOF/non-TTY | resolved | `2bc90194d359` |
| NINA-006 | Self-update remove-then-add window can leave nina uninstalled | resolved | `d5b8315c6ade` |
| NINA-007 | `nina diff` u32 underflow panic with no current generation | resolved | `a2c2b67bd83a` |
| NINA-008 | `nina pin` silent no-op reporting fake success | resolved — `pin <input> <rev>` now parses `flake.lock`, derives a commit-specific override ref for supported GitHub/GitLab/generic-git inputs, and runs `nix flake lock --override-input <input> <ref>` before printing success. Unsupported input source types fail loudly instead of guessing. Golden VM closeout proved `nina pin nixpkgs <locked-rev>` reaches `PIN_PASS=1`. | `721ba656a3a3` + v3.4.14 closeout |
| NINA-009 | `nina option` search built on a `nix eval` invocation that cannot succeed | resolved — `searchOptions` now evaluates a minimal `nixosSystem`, converts `eval.options` through `optionAttrSetToDocList`, filters by the query inside Nix before JSON serialization, and then parses the smaller matching doc list. Golden VM closeout proved `nina option openssh` returns 77 rows including `services.openssh.enable` (`OPTION_PASS=1`). | `d55b75fe962b` + v3.4.14 closeout |
| NINA-010 | `runHook` executes the hook via unquoted `$1` in `sh -c` | resolved | `26454ed98d54` |
| NINA-011 | `nina service <verb>` forwards any verb to `sudo systemctl`, bypassing confirmation | resolved | `4f0092888eb7` |
| NINA-012 | Unknown subcommands of `flake`/`channel`/`profile`/`pkg` exit 0 silently | resolved | `e923ab8ccb1a` |
| NINA-013 | Doctor's config-syntax dry-build check runs under `sudo` unnecessarily | **resolved, verified by code inspection only** — no VM doctor test harness existed to extend within campaign scope, so this fix was not exercised against a live golden VM. | `92e29d901105` |
| NINA-014 | Raw terminal mode not restored on signals or panics (search TUI, man pager) | resolved | `48628db291a4` |
| NINA-015 | Man pager help screen draws one row too many, drifting the frame | resolved | `a4d2b79b37cb` |
| NINA-016 | External text (hook output, nix search descriptions) printed with control characters unfiltered | resolved | `135d27fa00b4` |
| NINA-017 | Error text still points at retired `~/.nina.conf` path | resolved | `2b98515f8dae` (combined with NINA-019) |
| NINA-018 | `build.zig.zon` version drifted from `VERSION` | resolved | `d598fb1dd67b` |
| NINA-019 | Man page / README describe the pre-v3.0.15 search key model and wrong log path | resolved | `2b98515f8dae` (combined with NINA-017) |
| NINA-020 | `logAction` builds JSON without escaping the machine name | resolved | `a801f719897c` |
| NINA-021 | `getLicense` is dead code that also leaks its buffer by design | resolved (deleted) | `ceda368a6dea` |
| NINA-022 | `commandExists` interpolates its argument into a shell string | resolved | `b3f422a2f4b6` |
| NINA-023 | `bootEntry` allocates via `page_allocator` inline and leaks per entry | resolved | `e5a03023f758` |
| NINA-024 | Generation/status shell snippets (`find -printf`, `stat -c %Y`) are GNU-only | **acknowledged, no fix applied** — the audit itself flagged this as informational with no actionable `Fix:` (NixOS/GNU userland is the only supported target for these commands); noted purely so a future non-GNU remote host doesn't surprise. No koh save addresses it directly and none was expected to. |
| NINA-025 | `install.sh` aborts unhelpfully when `/dev/tty` is unavailable | resolved | `28a27c6d7ba4` |
| NINA-026 | `boot-overlay.sh` and `run-in-vm.sh` use `rm -rf` in EXIT traps instead of `trash` | **resolved on disk; not koh-tracked** — both traps now read `trash "$work" 2>/dev/null || true`, matching `run-once.sh` and `build-golden-unstable.sh`. `test/` is listed in `.kohignore` (confirmed: `koh status --json` reported a clean tree immediately after editing both files), so this fix does not and cannot appear in any koh save. This is expected given a prior wave's finding, not a defect in the fix. | none (kohignored) |

---

## Summary

- 24 of 26 findings fully resolved and koh-tracked with a real code/doc fix.
- NINA-008 is now a real implementation for supported flake-lock input sources
  (`github`, `gitlab`, and generic `git`), verified in the golden VM.
- NINA-009 is now live-verified in the golden VM (`nina option openssh` returned
  77 matching option rows including `services.openssh.enable`).
- 1 finding (NINA-013) fixed and verified by code inspection only, for lack
  of an existing doctor VM harness to extend.
- 1 finding (NINA-024) required no fix — informational, accepted constraint.
- 1 finding (NINA-026, this wave) fixed on disk but invisible to koh due to
  `test/` being `.kohignore`d — flagged explicitly rather than claimed as
  koh-tracked.
- One pre-campaign prerequisite fix (the `refAllDecls` gap) is noted above
  because it changes how much trust to place in any pre-campaign "tests
  green" claim for `exec.zig`/`commands.zig`/`errors.zig`/`config.zig`/`types.zig`.

Final local test count at campaign close: 73/73 passing, zero leaks
(`zig build test --summary all`).
