# Nina — Fable Read-Only Audit · 2026-07-02

Auditor: Fable (claude-fable-5) · read-only line-by-line review
Scope: entire repository at dev HEAD [bcb25ca4b195], nina v3.4.13
Checkpoint: [8e29d5f04b5d] "before fable read-only line-by-line audit"
Prior full audit baseline: checkpoint [c75cd6461a27] (treated as fresh pass, not a diff)

Every source file under src/, every root config/build/packaging file, install.sh,
and every script under test/ was read in full. Result artifacts (test/*/results/,
kiln/) were not line-audited — they are captured output, not source.

---

## Executive Summary

Nina v3.4.13 is in good shape. The codebase's core security discipline is sound:
every local subprocess is spawned with discrete argv elements (no shell string
interpolation of user input anywhere on the local path), sudo is confined to the
operations that genuinely need root and always with fixed or numerically-formatted
arguments, the self-updater verifies blake3 before an atomic rename-into-place,
and the hooks feature treats non-executable files as absent and defaults its
failure prompt to "no". No Critical or High findings. The audit surfaced nine
Medium findings, clustered in four themes: (1) the streamed build panel
accumulates nixos-rebuild stderr without newline separators, quietly degrading
the new error-translation and warning pipeline on its primary (TTY) path, and can
deadlock on a >8 KB stderr line; (2) remote (`--on`) execution loses argv
discreteness because ssh flattens arguments through the remote shell; (3)
non-interactive robustness — `confirm()` defaults to yes on EOF, the self-update
remove-then-add sequence can strand the user without nina, and `nina diff` can
integer-underflow-panic when no current generation is detectable; (4) two
commands silently do less than they claim (`nina pin` is a no-op that prints
success; `nina option` search is built on a nix eval invocation that cannot
succeed). None of these is exploitable across a privilege boundary; all are
worth fixing before wider distribution.

---

## Findings

```
ID:         NINA-001
Severity:   Medium
File:       src/exec.zig
Line:       437-446
Title:      Streamed build panel strips newlines from captured stderr, degrading error translation
Detail:     nixosRebuildRunStreamed reads child stderr with
            fr.interface.takeDelimiter('\n') and appends each returned slice to
            `accumulated`. Zig 0.16's Reader.takeDelimiter returns the line
            EXCLUDING the trailing delimiter (verified against
            lib/zig/std/Io/Reader.zig: `return inclusive[0..inclusive.len-1]`),
            so `accumulated` is all stderr lines concatenated with no '\n'
            between them. errors.setBuildStderr then receives one giant line.
            The entire translation pipeline is line-oriented: lineWith(),
            innermostError() (requires a trimmed line to START with "error:"),
            extractLocation(), cleanExtractedBody(), and extractWarnings()
            (requires a line to start with "warning:") all split on '\n'.
Impact:     On the most common interactive path (`nina apply` on a TTY with
            color), a failed build usually falls through to the generic Layer-3
            fallback instead of the pattern/structured translation; quoted-name
            extraction can grab text from the wrong original line; post-build
            warnings (extractWarnings) are silently lost. The silent-capture
            path (non-TTY) is unaffected, which is why VM captures look right.
Fix:        Append a '\n' after each takeDelimiter slice (or use
            takeDelimiterInclusive and strip only '\r' for the panel line).
            Add a unit test that feeds multi-line stderr through the streamed
            accumulation and asserts translateError still pattern-matches.
```

```
ID:         NINA-002
Severity:   Medium
File:       src/exec.zig
Line:       437, 448
Title:      Streamed stderr loop can abandon the pipe and deadlock the child
Detail:     `takeDelimiter('\n') catch break` exits the read loop on any error,
            including error.StreamTooLong, which fires when a single stderr
            line exceeds the 8192-byte reader buffer. Nix evaluation traces and
            derivation lists routinely exceed 8 KB on one line. After the
            break, the code calls child.wait() while the child's stderr pipe is
            no longer being drained; once the kernel pipe buffer fills, the
            child blocks on write() forever and wait() never returns.
Impact:     `nina apply` / `nina upgrade` hang indefinitely mid-build with the
            panel frozen; user must kill the process (leaving a partially
            complete nixos-rebuild running under sudo).
Fix:        On StreamTooLong, consume/discard the oversized remainder (e.g.
            fall back to reading raw chunks) and keep draining until EOF;
            never call wait() with an undrained pipe.
```

```
ID:         NINA-003
Severity:   Medium
File:       src/exec.zig
Line:       294-319
Title:      Remote (--on) execution loses argv discreteness — ssh flattens args through the remote shell
Detail:     buildArgv appends the command words directly to the ssh argv. ssh
            joins its trailing arguments with spaces and hands the string to
            the remote login shell, so nina's carefully-built discrete argv is
            re-parsed remotely. Any argument containing shell metacharacters
            or spaces — a package name (`nina pkg deps 'foo;reboot' --on box`
            → remote runs `reboot`), a config_path with a space, a channel URL
            with `&` — is word-split or executed on the remote host.
Impact:     Not a privilege-boundary break (the user already has ssh to that
            host), but it defeats the project's own "user input as discrete
            argv, never interpolated" rule on every remote path, breaks paths
            with spaces, and makes any wrapper script that feeds nina
            untrusted package names remotely injectable.
Fix:        Shell-quote each argument before appending to the ssh command
            (single-quote wrapping with '\'' escaping), or run the remote
            command via `ssh host -- sh -c '...'` with positional parameters.
            One helper in buildArgv covers every remote call site.
```

```
ID:         NINA-004
Severity:   Medium
File:       src/exec.zig
Line:       1870-1888
Title:      Self-update downloads to a fixed, predictable path in shared /tmp
Detail:     downloadToTemp writes to the constant path /tmp/nina-update.bin
            (the comment claims "/tmp/nina-update-<pid>", which the code does
            not do). On a multi-user machine another local user can pre-create
            that name: as a symlink, curl -o writes through it and clobbers
            any file the invoking user can write; as an attacker-owned file it
            can make the download fail or be observed. The subsequent
            blake3-verify-then-install reads the bytes once into memory and
            installs those same bytes, so a swap-after-verify does NOT lead to
            installing unverified code — the exposure is symlink clobbering,
            DoS, and disclosure. The temp file is also never cleaned up.
Impact:     Local symlink attack / denial of service on shared machines;
            stale binary left in /tmp.
Fix:        Use mktemp (as runHook already does) or O_EXCL with a random
            suffix; delete the temp file after install; fix or drop the stale
            comment.
```

```
ID:         NINA-005
Severity:   Medium
File:       src/output.zig
Line:       417-431
Title:      confirm() defaults to YES on EOF/non-TTY, auto-approving destructive operations
Detail:     confirm() returns true when stdin reaches EOF, errors, or yields an
            empty line. Every destructive confirmation routes through it:
            `nina clean` (delete generations + GC), `nina go <n>`,
            `nina gen delete`, `nina store repair`, `nina goodbye`, and the
            self-update. In any scripted/piped/cron context (`nina clean
            </dev/null`, a hook calling nina, CI), the "confirmation" is a
            silent yes. This was flagged during the June VM campaign (K-062)
            and the VM harness now *relies* on the behavior, but it remains a
            live footgun for real users' scripts.
Impact:     Unattended invocation of nina performs irreversible generation
            deletion / GC / uninstall without any consent signal.
Fix:        On EOF or !isatty(stdin), return false (abort) and print a hint to
            pass an explicit `--yes` flag; add `--yes` for legitimate
            automation. Keep confirmDefaultNo as-is (it is already safe).
```

```
ID:         NINA-006
Severity:   Medium
File:       src/commands.zig
Line:       434-462
Title:      Self-update remove-then-add window can leave nina uninstalled
Detail:     For nix-profile installs, update() works around the narHash-pinned
            originalUrl by running `nix profile remove <element>` and then
            `nix profile add --refresh <FLAKE_URL>`. Between the two, a network
            drop, kepr outage, or eval failure leaves the profile with no nina
            element. The failure message (updateSelfNixReinstallFailed) is
            honest and gives the exact reinstall command — good — but the
            operation itself is not failure-atomic, violating the "no partial
            state left behind on error" goal for the one command users run to
            keep nina current.
Impact:     A failed update uninstalls the tool being updated; recovery
            requires the user to paste a URL from the error text.
Fix:        Reorder to add-then-remove: `nix profile add --refresh <url>`
            first (nix allows a second element temporarily, or use a distinct
            name), and only remove the old element after the add succeeds —
            or pre-fetch the tarball (`nix flake prefetch`/`nix build`) so the
            re-add after remove is a local, near-infallible operation.
```

```
ID:         NINA-007
Severity:   Medium
File:       src/commands.zig
Line:       286-292
Title:      `nina diff` u32 underflow panic when no generation is marked current
Detail:     diff() computes `current` by scanning generations for
            `g.current`; if the readlink in GEN_LIST_SCRIPT fails to identify
            the current generation (non-standard profile layout, transient
            failure, or a remote host whose `find -printf` output differs),
            `current` stays 0 and the fallbacks `current - 1` (lines 286, 291,
            292) underflow u32. Nina ships as ReleaseSafe, so this is a
            runtime panic ("integer overflow"), not silent wraparound.
Impact:     Crash with a Zig panic trace instead of a friendly error on
            systems where the current generation can't be resolved.
Fix:        Guard: if current == 0 (or gens.len < 2 with no explicit args),
            print a "cannot determine current generation / nothing to diff"
            message and return. Same guard applies to the explicit-args
            parse-failure fallbacks.
```

```
ID:         NINA-008
Severity:   Medium
File:       src/commands.zig
Line:       1927-1932
Title:      `nina pin` is a silent no-op that reports success
Detail:     pin() calls exec.editFlakeLock, which is an empty stub
            (src/exec.zig:1393-1396, "Stub: full implementation would parse
            and edit flake.lock"), then prints `:: pinned <input> -> <commit>`.
            Nothing is pinned. The command is advertised in `nina help`
            ("pin flake inputs"), the man page, and the README.
Impact:     A user who pins an input before an upgrade believes a version is
            locked when it is not — the exact class of silent false success
            nina's own philosophy ("no silent failures") forbids. Trust
            damage outweighs the feature's absence.
Fix:        Either implement it (nix flake lock --override-input <in>
            github:...?rev=<commit> writes the pin with fixed argv), or make
            `nina pin` print "not implemented yet" and exit non-zero, and
            drop it from help/man until real.
```

```
ID:         NINA-009
Severity:   Medium
File:       src/api.zig
Line:       245-258
Title:      `nina option` search is built on a nix eval invocation that cannot succeed
Detail:     searchOptions runs `nix eval --json
            nixpkgs#lib.optionAttrSetToDocList nixpkgs#nixosModules`. nix eval
            takes a single installable; passing a second positional is an
            error, `lib.optionAttrSetToDocList` is a function (not
            JSON-serializable), and `nixpkgs#nixosModules` is not an output
            path evaluable this way. The call exits non-zero →
            error.SearchFailed → the TUI's doSearch catches it and renders
            "0 results" for every query; runPlain shows "no results".
            (Not executed live in this audit — no nix on the audit host — but
            the invocation is wrong by construction; the kyoshi/VM suites
            never asserted option-search results, only that it didn't crash.)
Impact:     A documented top-level command (`nina option <q>`, README, man,
            help) silently returns nothing, always.
Fix:        Evaluate the options doc list for real (e.g. build
            `nixos-option`-style eval: import <nixpkgs/nixos> with a minimal
            configuration and map options via lib.optionAttrSetToDocList in a
            --expr, or shell out to `nix-instantiate --eval --json` on a small
            expression), and add a VM assertion that a known option
            (services.openssh.enable) actually appears.
```

```
ID:         NINA-010
Severity:   Low
File:       src/exec.zig
Line:       227
Title:      runHook executes the hook via unquoted $1 in sh -c
Detail:     The runner script is `"$1 > \"$2\" 2>&1; ..."` — $2 is quoted but
            $1 is not, so the hook path undergoes word splitting and glob
            expansion. The path derives from $HOME; a HOME containing spaces
            (or glob chars) makes every hook fail with a confusing "command
            not found" from a half path. No injection (parameter expansion is
            not re-parsed as syntax), and the executability probe two lines
            up quotes the same value correctly — the inconsistency is the bug.
Impact:     Hooks break on unusual-but-legal HOME values; confusing failure
            output at the pre-apply prompt.
Fix:        Quote it: `"$1" > "$2" 2>&1; ...`.
```

```
ID:         NINA-011
Severity:   Low
File:       src/commands.zig
Line:       1669-1675
Title:      `nina service <verb>` forwards ANY verb to sudo systemctl, bypassing confirmation
Detail:     After the known subcommands, service() passes ctx.sub verbatim as
            the systemctl verb: `sudo systemctl --no-pager <verb> <name>`.
            The confirm gate covers only "stop" and "disable", so
            `nina service mask sshd`, `kill`, `revert`, `edit`, `isolate` all
            run under sudo with no prompt and no help-listing. Discrete argv
            means no injection, and the user could run systemctl directly —
            but nina's contract (curated verbs, confirmation on destructive
            ones) is silently wider than documented.
Impact:     Typos or unexpected verbs act on services with root privileges
            without the promised confirmation.
Fix:        Allowlist the verbs shown in service_help; reject others with the
            subcommand help.
```

```
ID:         NINA-012
Severity:   Low
File:       src/commands.zig
Line:       1751, 1841, 1877, 1916
Title:      Unknown subcommands of flake/channel/profile/pkg exit 0 silently
Detail:     flake(), channel(), profile(), and pkg() fall off the end of their
            if-chains for an unrecognized ctx.sub — no output, exit code 0.
            (gen() and home() correctly return an error / help.) Example:
            `nina flake updtae` prints nothing and "succeeds".
Impact:     Typos read as success in scripts and to users; violates the
            no-silent-failure principle.
Fix:        End each dispatcher with subcommandHelp(...) + non-zero exit (or
            the unknown-command error used by main dispatch).
```

```
ID:         NINA-013
Severity:   Low
File:       src/exec.zig
Line:       1477-1484
Title:      Doctor's config-syntax check runs nixos-rebuild dry-build under sudo unnecessarily
Detail:     `nixos-rebuild dry-build` is an evaluation/build dry run that works
            as an unprivileged user (it needs only read access to the config
            and the daemon socket). Running it via sudo makes `nina doctor` —
            a read-only diagnostic — trigger a password prompt and hold root
            for no benefit, contradicting the least-privilege posture the rest
            of exec.zig follows carefully.
Impact:     Unnecessary privilege use; sudo prompt in a diagnostic command;
            doctor fails on hosts where the user has no sudo.
Fix:        Drop sudo from the dry-build check (keep it for real
            switch/activate paths only). Verify once in the VM that dry-build
            passes as root-less user on both channel and flake goldens.
```

```
ID:         NINA-014
Severity:   Low
File:       src/search.zig
Line:       47-49
Title:      Raw terminal mode is not restored on signals or panics (search TUI and man pager)
Detail:     rawModeEnable disables ECHO/ICANON/ISIG and restoration relies
            solely on `defer rawModeDisable`. Defers do not run on SIGTERM/
            SIGHUP/SIGKILL, and a Zig panic in ReleaseSafe aborts without
            unwinding — either leaves the user's terminal in raw, echo-off
            mode. ISIG=false also means Ctrl+C is inert inside the widget (Esc
            is the only exit), so a wedged search (e.g. nix search blocking
            long) can't be interrupted cleanly. Same pattern in man.zig
            (lines 529-531). Normal and error returns ARE covered.
Impact:     A killed or crashed nina leaves the shell needing `reset`;
            Ctrl+C appears dead during searches.
Fix:        Install SIGTERM/SIGINT/SIGHUP handlers (or keep ISIG enabled and
            handle SIGINT) that restore the saved termios before exiting; the
            saved termios can live in a file-scope var for the handler.
```

```
ID:         NINA-015
Severity:   Low
File:       src/man.zig
Line:       929-938
Title:      Man pager help screen draws one row too many, drifting the frame
Detail:     drawHelpBody's loop prints one line per iteration except i == 0,
            which prints "...keys{s}\n\n" — two rows. The help frame is
            therefore PAGE_ROWS+1 rows tall, while every subsequent
            cursorUp(PAGE_ROWS + FOOTER_ROWS) assumes the fixed geometry, so
            after visiting '?' the frame creeps and leaves a ghost row — the
            same class of bug the v3.4.5 save fixed for the main body. Also,
            after any key dismisses help, redraw stays false, so the help
            content lingers until the next navigation key.
Impact:     Cosmetic ghosting/drift after using the pager's own help.
Fix:        Make the i == 0 arm emit exactly one row (drop the second \n and
            start pairs at i == 1 spacing), and force a body+footer redraw
            when showHelp returns.
```

```
ID:         NINA-016
Severity:   Low
File:       src/output.zig
Line:       386-408
Title:      External text (hook output, nix search descriptions) is printed with control characters unfiltered
Detail:     hookFailed prints hook output lines verbatim; the search TUI and
            plain search print package pname/version/description from nix
            search JSON verbatim; renderJsonLogLine prints raw unparseable log
            lines. Any embedded ESC bytes reach the terminal, letting a
            malicious nixpkgs description (or a compromised hook) inject
            escape sequences — title changes, screen garbage, or misleading
            rewritten lines. Hooks are the user's own code (weak boundary),
            but package descriptions come from upstream.
Impact:     Terminal escape injection from semi-trusted upstream text;
            defense-in-depth gap rather than a direct exploit.
Fix:        Route external strings through a sanitizer that strips bytes
            < 0x20 (except \n\t) — stripAnsi already exists in exec.zig and
            could be generalized and moved to output.zig.
```

```
ID:         NINA-017
Severity:   Low
File:       src/errors.zig
Line:       75-76
Title:      Error text still points at retired ~/.nina.conf path
Detail:     staticMessage says "~/.nina.conf not found" / "could not parse
            ~/.nina.conf" and config.zig:185 suggests "check ~/.nina.conf",
            but since the XDG migration the real path is
            ~/.config/nina/config (the man page documents this correctly,
            and load() auto-migrates the legacy file away).
Impact:     A user with a machine-resolution or parse problem is sent to a
            file that no longer exists after migration.
Fix:        Update the three strings to ~/.config/nina/config.
```

```
ID:         NINA-018
Severity:   Low
File:       build.zig.zon
Line:       12
Title:      build.zig.zon version (3.4.3) has drifted from VERSION (3.4.13)
Detail:     The zon .version was bumped in lockstep with VERSION through
            v3.4.x history (CONTINUITY records paired bumps), but stopped at
            3.4.3 while VERSION advanced to 3.4.13. Runtime version comes
            from VERSION via build_options (correct), and kepr --builds
            prefers VERSION, so impact is limited to package metadata — but
            the kepr publishing doc lists .version as the VERSION fallback,
            so losing the VERSION file would publish as 3.4.3.
Impact:     Metadata drift; wrong fallback version in packaging edge cases.
Fix:        Bump .version to match VERSION and restore the paired-bump habit
            (or generate one from the other).
```

```
ID:         NINA-019
Severity:   Low
File:       src/man.zig
Line:       171
Title:      Docs drift: man page and README describe the pre-v3.0.15 search key model and wrong log path
Detail:     The man "search" callout still documents "i or Enter profile
            install · s system install · t try · c copy attr" and the cmd_block
            at line 164 shows the same hints; README lines 168-182 show
            "[i] profile [s] system [t] try [c] copy". The actual widget (since
            the key-collision fix) is Enter/Tab/arrows/Esc only — 'c copy attr'
            does not exist at all. man.zig:259 says the log lives at
            ~/.local/share/nina/nina.log; it is ~/.nina.log. README lines 135
            and 199 document config at ~/.nina.conf (see NINA-017).
Impact:     The built-in manual teaches keys that type into the query instead
            of acting, and points at files that don't exist.
Fix:        Sync man.zig MAN_PAGE + README with the current widget keys, log
            path, and config path.
```

```
ID:         NINA-020
Severity:   Low
File:       src/commands.zig
Line:       2102-2109
Title:      logAction builds JSON by format string without escaping the machine name
Detail:     The JSONL log entry embeds ctx.machine.name directly into a JSON
            template. A machine name containing '"' or '\' (legal in the
            config parser) produces an invalid JSON line; renderJsonLogLine
            then falls back to dumping the raw line in the date column.
Impact:     Corrupt log rows for exotic machine names; no crash.
Fix:        Escape the string (or restrict machine names at config parse).
```

```
ID:         NINA-021
Severity:   Informational
File:       src/api.zig
Line:       144-170
Title:      getLicense is dead code and leaks its buffer by design
Detail:     No caller anywhere in src/ (the Tab detail pane uses packageMeta).
            It also returns a slice into result.stdout that the caller could
            never free correctly.
Impact:     None at runtime; maintenance noise.
Fix:        Delete it.
```

```
ID:         NINA-022
Severity:   Informational
File:       src/exec.zig
Line:       1534-1544
Title:      commandExists interpolates its argument into a shell string
Detail:     `command -v {s} >/dev/null` via sh -c. The only call site passes
            the literal "home-manager", so this is not currently reachable
            with attacker input — but it is the single place in exec.zig that
            builds shell syntax from a parameter, and a future caller could
            pass user input without noticing.
Impact:     Latent footgun only.
Fix:        Use argv form: sh -c 'command -v "$1"' _ <name>, matching the
            pattern used everywhere else.
```

```
ID:         NINA-023
Severity:   Informational
File:       src/output.zig
Line:       721-728
Title:      bootEntry allocates via page_allocator inline and leaks per entry
Detail:     The date suffix is allocPrint(std.heap.page_allocator, ...) inside
            the format call, never freed, and inconsistent with the arena
            discipline used everywhere else. Bounded by boot-entry count in a
            one-shot process, so harmless in practice.
Fix:        Print the date as a separate p() call; no allocation needed.
```

```
ID:         NINA-024
Severity:   Informational
File:       src/exec.zig
Line:       476, 910
Title:      Generation/status shell snippets are GNU-only
Detail:     GEN_LIST_SCRIPT uses `find -printf` and STATUS_SCRIPT uses
            `stat -c %Y` — fine on NixOS (the only supported target for these
            commands), but they will fail on a remote --on host that isn't
            GNU userland, and they are the path NINA-007's current==0 case
            comes from. Noted so a future macos/BSD remote doesn't surprise.
```

```
ID:         NINA-025
Severity:   Informational
File:       install.sh
Line:       38
Title:      install.sh aborts unhelpfully when /dev/tty is unavailable
Detail:     `read -r answer </dev/tty` under `set -e` kills the script with a
            bare redirection error in fully non-interactive contexts (CI,
            provisioning). Everything else about the script is exemplary:
            https-only pinned URL, prompt-before-acting, no sudo, no temp
            files, banner and messaging per the Asha standard.
Fix:        Guard: if ! [ -r /dev/tty ]; print the command and exit 0.
```

```
ID:         NINA-026
Severity:   Informational
File:       test/vm/boot-overlay.sh
Line:       23
Title:      Two harness scripts still use `rm -rf` in EXIT traps
Detail:     boot-overlay.sh:23 and run-in-vm.sh:20 trap with `rm -rf "$work"`;
            the newer scripts (run-once.sh, build-golden-unstable.sh) already
            use `trash`. House rule is trash-only in all scripts. mktemp-scoped
            dirs, so risk is nil — this is a consistency/process note.
Fix:        Switch both traps to `trash "$work" 2>/dev/null || true`.
```

---

## Positive Findings

- **Argv discipline (local).** Every local subprocess across exec.zig/api.zig is
  spawned with discrete argv arrays. Where a shell is genuinely needed, values
  travel as positional parameters, not splices: `flakeUpdateAt` passes the dir
  as `$0` (exec.zig:1048), and the setup writer runs
  `sudo sh -c 'cp -- "$0" "$0.nina-bak" && cp -- "$1" "$0"' path tmp`
  (exec.zig:2104-2106) — exactly the right pattern, including the `--` guards.
- **Sudo scope.** All 19 sudo call sites are state-changing system operations
  (rebuild, generations, GC, channels, systemctl, store repair) with fixed
  verbs and numeric or config-sourced arguments; `sudo -E` for the editor is a
  deliberate, documented choice. The one over-reach is the doctor dry-build
  (NINA-013).
- **Self-update integrity.** verifyAndInstall (exec.zig:1899-1944) reads the
  download once, blake3-verifies the in-memory bytes, writes `<path>.new`,
  re-signs on macOS, and renames atomically — the verify/install race is
  structurally closed, and failure paths clean up the .new file. curl calls
  use `--` before the URL and bounded timeouts.
- **Hooks design.** Non-executable or missing hooks are treated as absent; the
  failure prompt is confirmDefaultNo (a stray Enter aborts); post-hook failure
  warns without converting a success into a failure; output is size-capped
  (tail -c 4096 + stdout_limit) so a runaway hook can't flood memory; the abort
  path returns a distinct error that exits non-zero without double-printing.
  The 18/18 golden hook suite (test/vm/tests/hooks-verify.sh) is genuinely
  thorough — edge cases include no-output hooks and 20-line ring-buffer capping.
- **Passthrough flag mechanism.** Forwarded flags are appended as discrete argv
  elements to every wrapped command; the `--` separator hard-stops nina's own
  flag matching (main.zig:288-299); and home-manager build's shell wrapper takes
  them via `"$@"` after a literal `--` (exec.zig:1728) with a comment explaining
  why. A flag cannot smuggle shell metacharacters anywhere. The nine-case
  passthrough VM suite pins each wrapped tool's marker echo.
- **Memory model.** The cmd_arena in main.zig (freed on return, with the
  documented std.process.exit caveat) eliminates the leak class wholesale; the
  search TUI dupes the chosen package out of its dying arena (the documented
  use-after-free fix); parse helpers copy out of transient buffers before
  freeing (readNinaLog, parseHomeGenerations).
- **Parser robustness.** The config parser cannot crash on malformed input:
  unknown keys are ignored, bad booleans/integers fall back to defaults, and
  the alternate-boolean and machine-block semantics are unit-tested. JSON from
  nix is always parseFromSlice with type-checked access and graceful nulls.
- **Terminal correctness work shows.** The streaming (not positional) stdout
  writer fix, the OPOST-preserving raw mode shared by both TUIs, clamped
  selection indexing after debounced result swaps, and the exact-row redraw
  arithmetic in the man pager are all evidence of real bugs found, fixed, and
  regression-guarded on hardware.
- **Verification culture.** Nearly every behavior above is pinned by a
  real-tool golden-VM script or kyoshi read-only run with recorded artifacts —
  the passthrough, hooks, home-init, pkg, and panel suites assert argv-level
  ground truth, not just exit codes.

---

## Recommendations

1. **Make non-interactive behavior a first-class contract.** The single most
   user-affecting cluster (NINA-005, -006, -007) is "nina in a pipe". Define
   the rule once — destructive prompts require a TTY or an explicit `--yes`;
   multi-step mutations must be failure-atomic or resume-able — and audit every
   confirm()/state-change against it. The VM harness should then test
   `</dev/null` invocations expecting *abort*, not success.
2. **Centralize child-process text handling.** The stderr-accumulation bug
   (NINA-001/-002) exists because streaming, capture, and translation each
   reinvent line handling. A single `CapturedStream` helper (drain fully,
   preserve newlines, cap size, optional per-line callback) would serve the
   panel, capture(), and runHook, and be unit-testable off-host.
3. **Treat the remote path as a product surface, not a variant.** buildArgv is
   the one chokepoint (good architecture); adding shell-quoting there (NINA-003)
   plus one ssh-to-self VM assertion with a metacharacter argument would close
   the whole class permanently.
4. **Ship-what's-real in the surface area.** `pin` (NINA-008) and `option`
   (NINA-009) are advertised but non-functional; silent-unknown subcommands
   (NINA-012) hide typos. A small "every advertised command does something or
   says it can't" sweep — plus one golden assertion per command that its happy
   path produces its signature output — would align the surface with nina's
   no-silent-failure identity.
5. **Add a docs-drift check.** The man page is compiled into the binary, which
   is a strength — extend it: a tiny test that greps MAN_PAGE/README for
   retired strings ("~/.nina.conf", "c copy attr", the old log path) would have
   caught NINA-017/-019 at build time.

---

*Read-only session — no source files modified; this report is the sole artifact.*
