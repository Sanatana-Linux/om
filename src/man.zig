// man.zig — `om man`, an interactive, colorful pager for om's built-in docs.
//
// The pager is inline (no alternate screen), like search.zig's widget, so the
// terminal stays where it was when the user quits. It draws a header and footer,
// paginates the rendered content vertically, and accepts vim/less-style keys.
//
// Content lives in `MAN_PAGE` below — a static tree of chapters that mirrors
// the docs site. Everything renders through `renderLine`, which translates a
// typed block into an ANSI-styled string. No external files; the manpage is
// part of the binary.
//
// Keys: j/k or arrows scroll one line · space / b page down/up · g / G top /
// bottom · n / p (or → / ←) next / previous section · ? help · q or esc quit.
// Colors match the website palette: pink #AA6A52, gold #AD8A50, mint #708881,
// lavender #7A8162 on bg-surface #EEE6DB / bg-deep #CDBFAE.
const std = @import("std");
const output = @import("output.zig");
const rawterm = @import("rawterm.zig");
const build_options = @import("build_options");

const PINK = "\x1b[38;2;170;106;82m"; // --pink (#AA6A52)
const GOLD = "\x1b[38;2;173;138;80m"; // --gold (#AD8A50)
const MINT = "\x1b[38;2;112;136;129m"; // --mint (#708881)
const LAV = "\x1b[38;2;122;129;98m"; // --lavender (#7A8162)
// Body text. The website's --text-mid (#665D55) is calibrated for a cream
// background; on a dark terminal it sinks in and becomes unreadable. Lifted to
// a warm light tone so paragraphs, callout bodies, and flag descriptions read
// against the terminal's default (usually dark) background.
const TEXT = "\x1b[38;2;217;207;195m"; // body text, lightened for dark terminals
const TEXT_DIM = "\x1b[38;2;136;124;113m"; // --text-dim (#887C71)
const BG_HI = "\x1b[48;2;238;230;219m"; // --bg-surface (#EEE6DB)
const BG_BAR = "\x1b[48;2;205;191;174m"; // --bg-deep (#CDBFAE)
const RESET = "\x1b[0m";
const BOLD = "\x1b[1m";
const DIM = "\x1b[2m";
const INV = "\x1b[7m";

// Returns a code (e.g. color) gated by output.colorEnabled() so piped NO_COLOR
// output stays plain — matches the rest of om's output module.
fn c(code: []const u8) []const u8 {
    return if (output.colorEnabled()) code else "";
}

// --- Block types ---

const Block = union(enum) {
    chapter: []const u8, // small caps divider like "GETTING STARTED"
    title: []const u8, // section title
    badge: []const u8, // accent badge on the right of the title row
    accent: Accent, // which color paints the title + badge border
    para: []const u8, // wrapped paragraph
    cmd_sig: []const u8, // `om install <pkg>` — green-on-dark-ish signature line
    cmd_block: []const u8, // monospace example block
    flags_row: FlagsRow, // two-column row
    callout: Callout, // boxed tip with kaomoji
    kaomoji_card: KaomojiCard,
    blank,

    const Accent = enum { gold, mint, pink, lav };

    const FlagsRow = struct {
        flag: []const u8,
        desc: []const u8,
    };

    const Callout = struct {
        body: []const u8,
        color: Accent,
    };

    const KaomojiCard = struct {
        name: []const u8,
        desc: []const u8,
        when: []const u8,
        color: Accent,
    };
};

const Section = struct {
    id: []const u8, // for `om man <id>` direct jumps
    title: []const u8,
    accent: Block.Accent,
    blocks: []const Block,
};

// --- Content tree ---
//
// Mirrors ninawebsite/src/pages/docs.astro sections. Tweak here, rebuild, and
// the binary's manpage reflects the change. Keep IDs stable — `om man <id>`
// depends on them.

const MAN_PAGE = [_]Section{
    .{
        .id = "intro",
        .title = "what is om?",
        .accent = .gold,
        .blocks = &[_]Block{
            .{ .para = "om is a NixOS Intuitive Navigation Assistant — a gentle command-line tool that wraps the full NixOS workflow in one quiet, consistent voice." },
            .{ .para = "she handles package search, rebuilds, flakes, services, generation history, and remote machines — all without dropping you into a different screen, switching tools, or making you memorise long nixos-rebuild incantations." },
            .{ .para = "written in zig. zero runtime dependencies. a single binary. runs the same on any NixOS machine." },
            .{ .para = "the goal is simple: NixOS should feel like home. om is one step toward that." },
            .{
                .callout = .{
                    .color = .gold,
                    .body = "om stays inline at your prompt. search results, install confirmations, diff previews — everything comes to you. you never leave the shell you're already in.",
                },
            },
        },
    },
    .{
        .id = "install",
        .title = "installation",
        .accent = .gold,
        .blocks = &[_]Block{
            .{ .para = "om is a nix flake. two ways to install:" },
            .{ .para = "both methods require nix-command and flakes to be enabled. add this to ~/.config/nix/nix.conf (or /etc/nix/nix.conf on NixOS):" },
            .{ .cmd_block = "experimental-features = nix-command flakes" },
            .{ .para = "or run `om setup` after installing — she will add the line for you." },
            .{ .para = "direct url (simplest):" },
            .{ .cmd_block = "$ nix profile add 'https://kepr.uk/nina/archive/HEAD.tar.gz#om'" },
            .{ .para = "or build from source with koh:" },
            .{ .cmd_block = "$ koh steal kepr.uk/nina && koh build" },
            .{
                .callout = .{
                    .color = .mint,
                    .body = "after installing, run `om setup` — it makes sure the nix features om needs are turned on, and on NixOS walks you through the one config line.",
                },
            },
        },
    },
    .{
        .id = "setup",
        .title = "om setup",
        .accent = .mint,
        .blocks = &[_]Block{
            .{ .para = "`om setup` is your onboarding step. it makes sure nix's experimental features are enabled, which is all om needs to search and install packages. if they're already on, it prints `all set` and exits." },
            .{ .cmd_block = "$ om setup" },
            .{ .para = "on NixOS, om offers to add this line to /etc/nixos/configuration.nix (keeping a `.om-bak` backup):" },
            .{ .cmd_block = "nix.settings.experimental-features = [ \"nix-command\" \"flakes\" ];" },
            .{ .para = "press y and om appends it for you. press n and om shows you the line to paste. either way it ends with one step:" },
            .{ .cmd_block = "$ sudo nixos-rebuild switch" },
            .{ .para = "everywhere else, om writes `experimental-features = nix-command flakes` to ~/.config/nix/nix.conf. no sudo needed." },
        },
    },
    .{
        .id = "first-run",
        .title = "first run",
        .accent = .gold,
        .blocks = &[_]Block{
            .{ .para = "just type `om help` at the prompt. she will show you every command she knows." },
            .{ .para = "then try `om hello` to see the machines om has configured, or jump straight to `om search` to find a package." },
            .{ .para = "from here, search for a package, apply a change, or wander through the tips section to see what is possible." },
        },
    },
    .{
        .id = "search",
        .title = "search & discovery",
        .accent = .mint,
        .blocks = &[_]Block{
            .{ .para = "inline search that never takes over your screen. results appear right below the prompt, and you navigate them with the keyboard. press esc any time to go back to what you were doing." },
            .{ .para = "search nixpkgs for packages in an 18-line inline widget — no fullscreen takeover, no context switch." },
            .{ .cmd_block = "$ om search ripgrep\n:: search nixpkgs ripgrep  3 results\n\n   ripgrep       14.1.0   recursively search directories\n   ripgrep-all   0.10.0   ripgrep, but also search in PDFs\n   ripgrep-fixed  0.1.0    ripgrep with fixed-string matching\n\n   enter install  ·  tab info  ·  [up/down] nav  ·  esc cancel" },
            .{ .para = "search nixpkgs options the same way:" },
            .{ .cmd_block = "$ om option logind\n:: search options logind  N results" },
            .{
                .callout = .{
                    .color = .mint,
                    .body = "keys: [up/down] move through results · enter install the highlighted package · tab toggle package info · esc cancel",
                },
            },
        },
    },
    .{
        .id = "packages",
        .title = "packages",
        .accent = .lav,
        .blocks = &[_]Block{
            .{ .para = "install packages into your profile with a single command. om searches nixpkgs, shows you what it found, and asks how you want it." },
            .{ .para = "[i] profile install — runs `nix profile install nixpkgs#attr`. available immediately, no rebuild needed." },
            .{ .para = "[s] system install — opens configuration.nix in your editor at the systemPackages line. add the package, save, and om asks whether to apply." },
            .{ .para = "[t] try now — drops you into a `nix shell` with the package available. gone when you exit." },
            .{ .cmd_block = "$ om install neovim\n:: neovim  0.10.4\n\n   [i] profile install    instant  no rebuild\n   [s] system install     opens editor  requires apply\n   [t] try now            exits when done\n\n   > i\n:: installing neovim  profile\n   -> nix profile install nixpkgs#neovim\n:: neovim installed  available now" },
            .{ .para = "explain why a package is installed:" },
            .{ .cmd_block = "$ om why ripgrep\n:: why ripgrep  kyoshi\n\n   ripgrep is a direct profile package" },
            .{ .para = "`om pin <input> <rev>` reads the input source from `flake.lock` and runs `nix flake lock --override-input` with a commit-specific flake ref. `om unpin <input>` releases it again by running `nix flake update` on that input." },
        },
    },
    .{
        .id = "system",
        .title = "system changes",
        .accent = .pink,
        .blocks = &[_]Block{
            .{ .para = "preview, apply, and roll back changes to your nixos system. om shows you exactly what will change before it happens, and arms a rollback the moment things go sideways." },
            .{ .para = "compare two generations using `nix store diff-closures`:" },
            .{ .cmd_block = "$ om diff\n:: gen 348 -> gen 349  kyoshi\n\n   + neovim   0.10.4\n   ^ ripgrep  14.0.3 -> 14.1.1" },
            .{ .para = "validate your configuration with `nixos-rebuild build`. catches syntax errors and missing references before they reach a running system." },
            .{ .para = "rebuild and switch to the new generation:" },
            .{ .cmd_block = "$ om apply\n:: rebuilding kyoshi...\n:: generation 349  [4.1s]" },
            .{ .para = "roll back one generation. to jump to a specific generation, use `om go <n>`." },
            .{ .cmd_block = "$ om back\n:: rolling back  kyoshi  gen 349 -> gen 348\n:: done  gen 348" },
            .{
                .flags_row = .{ .flag = "--on <machine>", .desc = "rebuild a remote machine over SSH" },
            },
            .{
                .flags_row = .{ .flag = "--dry", .desc = "dry-activate only — build without switching" },
            },
            .{
                .flags_row = .{ .flag = "--check", .desc = "validate config only, same as `om check`" },
            },
            .{
                .callout = .{
                    .color = .pink,
                    .body = "generations are immutable snapshots. `om back` always has somewhere to go, and `om go <n>` can reach any point in your history.",
                },
            },
        },
    },
    .{
        .id = "flakes",
        .title = "flakes & dev shells",
        .accent = .mint,
        .blocks = &[_]Block{
            .{ .para = "inspect flake outputs, step into dev shells, build specific outputs, and manage the flake lifecycle — all with the same quiet vocabulary." },
            .{ .para = "show what the current directory's flake exposes — packages, apps, dev shells, nixos configurations." },
            .{ .cmd_block = "$ om flake show\n:: .\n\n   packages     x86_64-linux   om\n   apps         x86_64-linux   om\n   devShells    x86_64-linux   default" },
            .{ .para = "run `nix flake update`. pass a specific input name to update only that one. prints a confirmation when `flake.lock` is written." },
            .{ .para = "enter the flake's dev shell with `nix develop`. type `exit` to return. `develop run <cmd>` runs a single command without an interactive shell." },
            .{ .para = "build a flake output with `nix build`. result is linked as `./result`. run a package without installing it — bare names are resolved as `nixpkgs#<pkg>`." },
        },
    },
    .{
        .id = "inspection",
        .title = "inspection & care",
        .accent = .lav,
        .blocks = &[_]Block{
            .{ .para = "check on the health of your system, follow service logs, inspect the store, and reclaim disk space — without jumping between different tools." },
            .{ .para = "show the current generation and reachability of the target machine:" },
            .{ .cmd_block = "$ om status\n:: status\n\n   kyoshi   gen 349   1h ago   10.2 GB\n            hm  gen 2   2h ago" },
            .{ .para = "run a health diagnostic. checks the nix daemon, config syntax, channels, and home manager." },
            .{ .cmd_block = "$ om doctor\n:: diagnosing  kyoshi\n\n   nix daemon      ok\n   config syntax   ok\n   channel         ok\n   home manager    standalone  gen 2\n\n:: all good" },
            .{ .para = "manage systemd services. `service logs <name> -f` follows the journal live. `stop` and `disable` prompt for confirmation when `confirm = true`. all service commands accept `--user` to target user-managed services." },
            .{ .para = "inspect and maintain the nix store. `store info` shows total size, live paths, and reclaimable space. `store gc` runs garbage collection. `store path <attr>` evaluates a store path for a nixpkgs attribute." },
            .{ .para = "remove old generations and run garbage collection. keeps the number of generations set by `generations` in your config (default: 5). `--all` removes all old generations regardless." },
            .{ .cmd_block = "$ om clean\n:: cleaning  kyoshi  keeping 5 of 14\n   continue? [Y/n]  y\n:: freed 4.2 GB" },
        },
    },
    .{
        .id = "generations",
        .title = "generation history",
        .accent = .gold,
        .blocks = &[_]Block{
            .{ .para = "your system's whole story is saved in generations. browse them, compare them, travel back to any of them. nothing is gone until you clean it up." },
            .{ .cmd_block = "$ om history\n:: generations  kyoshi\n\n   349   2026-05-30   09:32:01   current\n   348   2026-05-29   14:22:44\n   347   2026-05-25   11:05:33" },
            .{ .para = "switch to any specific generation by number using `nix-env --switch-generation`. use this when `om back` is not far enough." },
            .{ .para = "show om's operation log from ~/.om.log. displays the last 50 entries by default. use `--last N` to show more or fewer." },
            .{
                .callout = .{
                    .color = .gold,
                    .body = "generations are your safety net. apply freely, knowing you can always go back. `om history` shows the whole story. `om go` takes you there.",
                },
            },
        },
    },
    .{
        .id = "home",
        .title = "home manager",
        .accent = .lav,
        .blocks = &[_]Block{
            .{ .para = "om manages your home manager configuration with the same vocabulary as your system. all `om home` commands work with standalone home manager and NixOS module setups. om detects which mode you're using automatically." },
            .{ .para = "bootstrap home manager for the first time. runs `nix run home-manager/<branch> -- init`, which creates ~/.config/home-manager/home.nix with a starter configuration. passing `--switch` activates the configuration immediately." },
            .{ .cmd_block = "$ om home init --switch\n:: setting up home manager  ~/.config/home-manager\n   -> will activate after init\n\n:: home manager ready" },
            .{ .para = "apply your home manager configuration. runs `home-manager switch` under the hood. `--dry` builds without activating." },
            .{ .para = "roll back to the previous home manager generation. list home generations. show what changed between the last two with `home diff`. validate without applying with `home check`. open `home.nix` with `home edit`." },
            .{ .cmd_block = "$ om home packages\n\n:: home packages  kyoshi\n\n   hello    2.12.1\n   jq       1.7.1" },
            .{
                .callout = .{
                    .color = .lav,
                    .body = "the same apply → diff → back pattern works for your home config, just as it does for your system. om uses the same verbs so you do not have to learn a second vocabulary.",
                },
            },
        },
    },
    .{
        .id = "machine-config",
        .title = "machine config",
        .accent = .pink,
        .blocks = &[_]Block{
            .{ .para = "edit your configuration safely, inspect the running system, manage channels, and set boot defaults — all without needing to remember the right file path or nixos-rebuild flag." },
            .{ .para = "open configuration.nix in your configured editor (default: vim). pass `hardware` to open hardware-configuration.nix instead. after saving, run `om check` to validate before applying." },
            .{ .para = "format configuration.nix with `nixpkgs-fmt`. `--check` reports whether formatting is needed without writing. show the nixos version, kernel version, and uptime of the target machine. list boot entries from the bootloader. launch `nix repl` with nixpkgs loaded." },
            .{
                .callout = .{
                    .color = .pink,
                    .body = "`om edit` uses the `editor` value from ~/.config/om/config (default: vim). set it to your editor of choice and om will use it everywhere.",
                },
            },
        },
    },
    .{
        .id = "remote",
        .title = "remote machines",
        .accent = .lav,
        .blocks = &[_]Block{
            .{ .para = "the same voice, even over SSH. every om command accepts `--on <machine>` and behaves identically on a remote host. no separate tooling, no context switching." },
            .{ .cmd_block = "$ om apply --on azula\n  ✦ rebuilding azula over ssh\n  · building generation 193\n  generation 193.\n\n$ om service logs ollama -f --on azula\n  ✦ following logs for ollama on azula\n  [info] serving on 0.0.0.0:11434" },
            .{ .para = "define remote machines in ~/.config/om/config:" },
            .{ .cmd_block = "[machine]\nname    = azula\nhost    = june@azula\nssh_key = ~/.ssh/id_ed25519" },
            .{ .para = "fleet commands:" },
            .{
                .flags_row = .{ .flag = "om hello", .desc = "list all configured machines and their kind (local / ssh)" },
            },
            .{
                .flags_row = .{ .flag = "om status --on <m>", .desc = "show generation and uptime for a remote machine" },
            },
            .{
                .flags_row = .{ .flag = "om doctor --on <m>", .desc = "run a full health diagnostic on any machine" },
            },
            .{
                .flags_row = .{ .flag = "om apply --on <m>", .desc = "rebuild and switch a remote machine over SSH" },
            },
            .{
                .callout = .{
                    .color = .lav,
                    .body = "om keeps remote work from turning into a whole new personality. same verbs, same little reassurances, same sense of where you are.",
                },
            },
        },
    },
    .{
        .id = "hooks",
        .title = "hooks",
        .accent = .mint,
        .blocks = &[_]Block{
            .{ .para = "om can run optional executable scripts before and after state-changing commands. hooks live in ~/.config/om/hooks/. missing hooks are ignored, and files that are not executable are treated as absent." },
            .{ .para = "available hook files:" },
            .{ .cmd_block = "pre-apply     post-apply\npre-back      post-back\npre-home      post-home\npre-upgrade   post-upgrade" },
            .{ .para = "`pre-apply` runs before `om apply`, `pre-back` before `om back`, `pre-home` before `om home apply`, and `pre-upgrade` before `om upgrade`. the matching `post-*` hooks run only after the command succeeds." },
            .{ .para = "if a pre-hook exits non-zero, om shows the exit code and the last five lines of hook output, then asks whether to continue. that prompt defaults to no." },
            .{ .cmd_block = ":: pre-apply hook exited with code 1\n\n   uncommitted changes - commit before applying\n\n   continue anyway? [y/N]  n\n:: aborted" },
            .{ .para = "if a post-hook fails, om prints a warning after the success line. the original command already succeeded, so the hook warning does not turn the operation into a failure." },
            .{ .para = "example: stop `om apply` when your nixos config has uncommitted changes." },
            .{ .cmd_block = "#!/usr/bin/env sh\n# ~/.config/om/hooks/pre-apply\nif git -C ~/nixos-config status --porcelain | grep -q .; then\n    echo \"uncommitted changes - commit before applying\"\n    exit 1\nfi" },
            .{ .para = "make hook scripts executable with `chmod +x ~/.config/om/hooks/pre-apply`. om creates the hooks directory automatically the first time it checks for hooks." },
        },
    },
    .{
        .id = "configuration",
        .title = "configuration",
        .accent = .gold,
        .blocks = &[_]Block{
            .{ .para = "om's config file lives at ~/.config/om/config (XDG). the format is plain key=value, one per line. comments start with #. all settings are optional — om works out of the box with no config file." },
            .{
                .callout = .{
                    .color = .gold,
                    .body = "if you have an existing ~/.om.conf from an earlier version, om migrates it to ~/.config/om/config automatically on first run.",
                },
            },
            .{ .para = "full example:" },
            .{ .cmd_block = "editor      = nvim\ngenerations = 5\nconfirm     = true\nteach       = false\ncolor       = true\n\n[machine]\nname    = kyoshi\nconfig  = /etc/nixos\nlocal   = true\ndefault = true\n\n[machine]\nname    = azula\nhost    = june@azula\nssh_key = ~/.ssh/id_ed25519" },
            .{ .para = "if you have a [machine] host set, `local` automatically becomes false and `om --on azula` runs everything over SSH. `default = true` on a machine block selects it when no `--on` is given." },
            .{ .para = "every config key accepts the values you'd expect. booleans read true / false / yes / no. integers are decimal. `~` in `ssh_key` expands to `$HOME`." },
        },
    },
    .{
        .id = "expressions",
        .title = "expressions ♡",
        .accent = .pink,
        .blocks = &[_]Block{
            .{ .para = "om uses a rotating set of mantras instead of a mascot. each time one is shown it is picked at random, so the same moment rarely repeats. they stay tucked into the UI, show a little feeling, and leave the work itself readable." },
            .{ .para = "the rule is simple: calm most of the time, brighter when something lands, softer when something goes wrong." },
            .{
                .kaomoji_card = .{
                    .name = "hello",
                    .color = .lav,
                    .desc = "a warm, quiet welcome. om is ready to help and not making a fuss about it.",
                    .when = "setup wizard, first-run greeting",
                },
            },
            .{
                .kaomoji_card = .{
                    .name = "starting",
                    .color = .mint,
                    .desc = "settling in and getting to work. something meaningful is beginning.",
                    .when = "apply start, home apply start, entering a dev shell",
                },
            },
            .{
                .kaomoji_card = .{
                    .name = "relief",
                    .color = .gold,
                    .desc = "something that was broken is working again. a small celebration for persistence.",
                    .when = "first success after a previously failed build",
                },
            },
            .{
                .kaomoji_card = .{
                    .name = "done",
                    .color = .lav,
                    .desc = "calm satisfaction. a rollback landed cleanly and the system is in good hands.",
                    .when = "back success",
                },
            },
            .{
                .kaomoji_card = .{
                    .name = "clean",
                    .color = .mint,
                    .desc = "light and tidy. the work is done and things look better than before.",
                    .when = "clean done",
                },
            },
            .{
                .kaomoji_card = .{
                    .name = "all good",
                    .color = .gold,
                    .desc = "everything checked out. a quiet joy that the system is healthy.",
                    .when = "doctor all clear, mood all good",
                },
            },
            .{
                .kaomoji_card = .{
                    .name = "exiting",
                    .color = .lav,
                    .desc = "a gentle close. nothing went wrong — it's just time to step out.",
                    .when = "try exit, leaving a dev shell",
                },
            },
            .{
                .kaomoji_card = .{
                    .name = "sorry",
                    .color = .pink,
                    .desc = "something went sideways, and om is honest about it. details are right there with her.",
                    .when = "network or SSH errors, search timeout",
                },
            },
            .{
                .callout = .{
                    .color = .pink,
                    .body = "if you prefer a quieter experience, set `color = false` in your config. om will still show everything — just without the ansi palette.",
                },
            },
        },
    },
    .{
        .id = "tips",
        .title = "tips & recipes",
        .accent = .mint,
        .blocks = &[_]Block{
            .{ .para = "a few patterns that make daily nixos life a little smoother." },
            .{ .para = "a quiet morning with om:" },
            .{ .cmd_block = "# update flake inputs and preview changes\n$ om flake update\n$ om diff\n\n# apply if the diff looks good\n$ om apply" },
            .{ .para = "try a package without committing to it:" },
            .{ .cmd_block = "$ om try bat\n:: trying bat  exit when done\n   → bat is available in this shell only, gone when you exit" },
            .{ .para = "push the same config change to multiple machines:" },
            .{ .cmd_block = "$ om apply --on kyoshi\n:: generation 349  [4.1s]\n$ om apply --on azula\n:: generation 193  [6.3s]" },
            .{ .para = "something broke and you want to find when:" },
            .{ .cmd_block = "$ om history\n  → find the last known-good generation number\n$ om diff 344 349\n  → see what changed across those generations\n$ om go 344\n:: done  gen 344" },
            .{ .para = "useful shell aliases:" },
            .{ .cmd_block = "alias ns=\"om search\"\nalias no=\"om option\"\nalias na=\"om apply\"\nalias nd=\"om diff\"\nalias nb=\"om back\"" },
            .{
                .callout = .{
                    .color = .mint,
                    .body = "when something goes wrong, `om back` is always there. when you're not sure what to try next, `om diff` shows you the picture. and when things go right, om keeps the terminal feeling light.",
                },
            },
        },
    },
};

// --- Pager state ---

// Visible content rows. Set once per run from the real terminal height, so
// the pager fills the window instead of a fixed guess that left half the
// screen unused on tall terminals. Falls back to this default when the
// window size can't be read.
var PAGE_ROWS: u16 = 22;
const MIN_PAGE_ROWS: u16 = 5;
const COL_WIDTH: u16 = 96; // wrap width for paragraphs
// Frame geometry. The header paints exactly HEADER_ROWS lines and the footer
// FOOTER_ROWS; redraw arithmetic depends on these being right, so name them
// instead of magic +2 guesses that drift.
const HEADER_ROWS: u16 = 3;
const FOOTER_ROWS: u16 = 1;
fn frameRows() u16 {
    return HEADER_ROWS + PAGE_ROWS + FOOTER_ROWS;
}

// Reads the terminal's row count via TIOCGWINSZ and converts it to a content
// row budget by subtracting the fixed header/footer. Any failure (not a tty,
// ioctl error, absurdly small window) falls back to the default PAGE_ROWS.
fn detectPageRows(io: std.Io) u16 {
    var ws: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const result = io.operate(.{ .device_io_control = .{
        .file = std.Io.File.stdout(),
        .code = std.posix.T.IOCGWINSZ,
        .arg = &ws,
    } }) catch return PAGE_ROWS;
    if (result.device_io_control < 0) return PAGE_ROWS;
    if (ws.row <= HEADER_ROWS + FOOTER_ROWS + MIN_PAGE_ROWS) return PAGE_ROWS;
    return ws.row - HEADER_ROWS - FOOTER_ROWS;
}

pub fn run(io: std.Io, topic: []const u8) !void {
    // Plain fallback for non-tty (piped, redirected). Print every section in
    // order with a colored chapter divider — same vibe, but no interactivity.
    if (!(std.Io.File.stdout().isTty(io) catch false)) {
        return runPlain(io, topic);
    }

    // Raw mode so we can read keys without waiting for Enter. Match search.zig.
    var saved: std.posix.termios = undefined;
    try rawterm.rawModeEnable(STDIN_FD, &saved);
    defer rawterm.rawModeDisable(STDIN_FD, saved);

    PAGE_ROWS = detectPageRows(io);

    const start_section: usize = if (topic.len == 0) 0 else blk: {
        for (MAN_PAGE, 0..) |sec, i| {
            if (std.mem.eql(u8, sec.id, topic)) break :blk i;
        }
        output.p("{s}om man: no such topic: {s}{s}\n", .{ c(PINK), topic, c(RESET) });
        output.flush();
        return;
    };

    // Pre-render every section into an array of styled lines so the page loop
    // never has to format anything — it just slices the right range. This keeps
    // redraw cost constant and makes `g`/`G` instant.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var rendered = std.ArrayList([]const u8).empty;
    defer rendered.deinit(allocator);

    // Per-section, prepend a chapter divider so the content has visual breathing
    // room and the pager can show progress.
    var section_starts = std.ArrayList(usize).empty;
    defer section_starts.deinit(allocator);
    var section_titles = std.ArrayList([]const u8).empty;
    defer section_titles.deinit(allocator);

    try section_starts.append(allocator, 0);
    for (MAN_PAGE) |sec| {
        try section_titles.append(allocator, sec.title);
        try renderSection(allocator, &rendered, sec);
        try section_starts.append(allocator, rendered.items.len);
    }
    const total: usize = rendered.items.len;

    var top: usize = 0;
    var cur_section: usize = start_section;
    top = section_starts.items[start_section];

    drawHeader();
    drawBody(rendered.items, top, total, section_titles.items, cur_section);
    drawFooter(cur_section, MAN_PAGE.len, top, total);
    output.flush();

    var pfd = [_]std.posix.pollfd{.{ .fd = STDIN_FD, .events = std.posix.POLL.IN, .revents = 0 }};
    while (true) {
        _ = std.posix.poll(&pfd, -1) catch break;

        var buf: [8]u8 = undefined;
        const n = std.posix.read(STDIN_FD, &buf) catch break;
        if (n == 0) break;

        const advance_section = struct {
            fn f(starts: []const usize, cur: usize, delta: i32) usize {
                var idx: i32 = @intCast(cur);
                idx += delta;
                if (idx < 0) idx = 0;
                if (idx >= @as(i32, @intCast(starts.len - 1))) idx = @intCast(starts.len - 2);
                return starts[@intCast(idx)];
            }
        }.f;

        // Find the section that owns `top`. Used after manual scrolling.
        const sectionOf = struct {
            fn f(starts: []usize, t: usize) usize {
                var s: usize = 0;
                for (starts[1..], 1..) |start, i| {
                    if (t < start) return i - 1;
                    s = i;
                }
                return s;
            }
        }.f;

        var redraw = true;
        if (n >= 3 and buf[0] == 0x1b and buf[1] == '[') {
            switch (buf[2]) {
                'A' => top = if (top > 0) top - 1 else 0, // up
                'B' => top = if (top + 1 < total) top + 1 else top, // down
                'C' => top = advance_section(section_starts.items, cur_section, 1), // right: next section
                'D' => top = advance_section(section_starts.items, cur_section, -1), // left: prev
                '5' => top = if (top >= PAGE_ROWS) top - PAGE_ROWS else 0, // pgup
                '6' => top = if (top + PAGE_ROWS < total) top + PAGE_ROWS else total - 1, // pgdn
                'H' => top = 0, // home
                'F' => top = if (total > 0) total - 1 else 0, // end
                else => redraw = false,
            }
        } else switch (buf[0]) {
            'q', 'Q', 0x1b => break, // quit
            'j' => top = if (top + 1 < total) top + 1 else top,
            'k' => top = if (top > 0) top - 1 else 0,
            ' ' => top = if (top + PAGE_ROWS < total) top + PAGE_ROWS else total - 1,
            'b' => top = if (top >= PAGE_ROWS) top - PAGE_ROWS else 0,
            'g' => top = 0,
            'G' => top = if (total > 0) total - 1 else 0,
            'n' => top = advance_section(section_starts.items, cur_section, 1),
            'p' => top = advance_section(section_starts.items, cur_section, -1),
            'h' => top = 0,
            '?' => {
                showHelp();
                // showHelp leaves the help screen on the terminal until the
                // next redraw; force one now instead of waiting for the next
                // navigation key, so dismissing help doesn't leave stale
                // help content on screen (NINA-015).
                redraw = true;
            },
            else => redraw = false,
        }

        if (redraw) {
            cur_section = sectionOf(section_starts.items, top);
            // Header is static; repaint only the body + footer below it. Move up
            // exactly the rows we repaint. The old `+ 2` overshot by one, so each
            // redraw crept the frame up a row and left the previous footer
            // behind as a ghost line.
            output.cursorUp(PAGE_ROWS + FOOTER_ROWS);
            drawBody(rendered.items, top, total, section_titles.items, cur_section);
            drawFooter(cur_section, MAN_PAGE.len, top, total);
            output.flush();
        }
    }

    // Clear the whole inline frame on exit — header included — so the shell
    // prompt lands on a clean line. The old PAGE_ROWS + 2 count missed the top
    // two header rows, leaving them stranded above the prompt.
    output.cursorUp(frameRows());
    for (0..frameRows()) |_| {
        output.raw("\x1b[K\n");
    }
    output.cursorUp(frameRows());
    output.flush();
}

fn runPlain(_: std.Io, topic: []const u8) !void {
    const start_section: usize = if (topic.len == 0) 0 else blk: {
        for (MAN_PAGE, 0..) |sec, i| {
            if (std.mem.eql(u8, sec.id, topic)) break :blk i;
        }
        output.p("{s}om man: no such topic: {s}{s}\n", .{ c(PINK), topic, c(RESET) });
        output.flush();
        return;
    };

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var rendered = std.ArrayList([]const u8).empty;
    defer rendered.deinit(allocator);

    var i: usize = start_section;
    while (i < MAN_PAGE.len) : (i += 1) {
        try renderSection(allocator, &rendered, MAN_PAGE[i]);
    }
    for (rendered.items) |line| output.raw(line);
    output.raw("\n");
    output.flush();
}

const STDIN_FD = rawterm.STDIN_FD;

// Raw mode enable/disable, including signal-safe restoration on
// SIGINT/SIGTERM/SIGHUP, now lives in rawterm.zig — shared with search.zig
// (NINA-014).

// --- Rendering ---

const AccentColor = struct {
    fg: []const u8,
    bar: []const u8,
};

fn accentColors(a: Block.Accent) AccentColor {
    return switch (a) {
        .gold => .{ .fg = GOLD, .bar = GOLD },
        .mint => .{ .fg = MINT, .bar = MINT },
        .pink => .{ .fg = PINK, .bar = PINK },
        .lav => .{ .fg = LAV, .bar = LAV },
    };
}

fn renderSection(allocator: std.mem.Allocator, out: *std.ArrayList([]const u8), sec: Section) !void {
    // Chapter divider — small caps with the section index number
    var idx_buf: [16]u8 = undefined;
    const idx_str = std.fmt.bufPrint(&idx_buf, "{d:0>2}", .{sectionIndexOf(sec.id) + 1}) catch "00";

    const accent = accentColors(sec.accent);
    const divider = try std.fmt.allocPrint(allocator, "{s}── {s}{s}{s}  {s}{s}{s}\n", .{
        c(TEXT_DIM),
        c(accent.fg), sec.title, c(RESET),
        c(TEXT_DIM), idx_str, c(RESET),
    });
    try out.append(allocator, divider);

    for (sec.blocks) |block| {
        try renderBlock(allocator, out, block);
    }

    // Soft blank line at end of section
    try out.append(allocator, "\n");
}

fn sectionIndexOf(id: []const u8) usize {
    for (MAN_PAGE, 0..) |sec, i| {
        if (std.mem.eql(u8, sec.id, id)) return i;
    }
    return 0;
}

fn renderBlock(allocator: std.mem.Allocator, out: *std.ArrayList([]const u8), block: Block) !void {
    switch (block) {
        .chapter => try out.append(allocator, try std.fmt.allocPrint(allocator, "\n{s}{s}  {s}{s}\n\n", .{ c(TEXT_DIM), block.chapter, c(RESET), "" })),
        .title => {
            const accent = accentColors(block.accent);
            const padded_title = try std.fmt.allocPrint(allocator, "  {s}◆{s} {s}{s}{s}  ", .{ c(accent.bar), c(RESET), c(BOLD), block.title, c(RESET) });
            try out.append(allocator, try std.fmt.allocPrint(allocator, "\n{s}{s}\n", .{ padded_title, "" }));
            if (block.badge.len > 0) {
                try out.append(allocator, try std.fmt.allocPrint(allocator, "  {s}[{s}{s}{s}{s}]{s}\n", .{ c(TEXT_DIM), c(accent.fg), block.badge, c(TEXT_DIM), c(RESET), c(RESET) }));
            }
        },
        .badge => {}, // handled by title
        .accent => {}, // marker field — ignored
        .para => {
            const wrapped = try wrap(allocator, block.para, COL_WIDTH);
            for (wrapped) |line| {
                try out.append(allocator, try std.fmt.allocPrint(allocator, "  {s}{s}{s}\n", .{ c(TEXT), line, c(RESET) }));
            }
        },
        .cmd_sig => {
            const accent = accentColors(block.accent);
            try out.append(allocator, try std.fmt.allocPrint(allocator, "  {s}│{s}  {s}{s}{s}\n", .{ c(accent.fg), c(RESET), c(accent.fg), block.cmd_sig, c(RESET) }));
        },
        .cmd_block => {
            const wrapped = try wrap(allocator, block.cmd_block, COL_WIDTH);
            for (wrapped) |line| {
                try out.append(allocator, try std.fmt.allocPrint(allocator, "    {s}{s}{s}\n", .{ c(MINT), line, c(RESET) }));
            }
            try out.append(allocator, "\n");
        },
        .flags_row => {
            const accent = accentColors(.gold);
            try out.append(allocator, try std.fmt.allocPrint(allocator, "  {s}│{s}  {s}{s:<22}{s}  {s}{s}{s}\n", .{ c(accent.fg), c(RESET), c(accent.fg), block.flags_row.flag, c(RESET), c(TEXT), block.flags_row.desc, c(RESET) }));
        },
        .callout => {
            const accent = accentColors(block.callout.color);
            const wrapped = try wrap(allocator, block.callout.body, COL_WIDTH - 6);
            var first = true;
            for (wrapped) |line| {
                if (first) {
                    try out.append(allocator, try std.fmt.allocPrint(allocator, "  {s}┌─ {s}{s}  {s}{s}{s}\n", .{ c(accent.bar), c(accent.fg), output.mantra(), c(TEXT), line, c(RESET) }));
                    first = false;
                } else {
                    try out.append(allocator, try std.fmt.allocPrint(allocator, "  {s}│{s}   {s}{s}{s}\n", .{ c(accent.bar), c(RESET), c(TEXT), line, c(RESET) }));
                }
            }
            try out.append(allocator, try std.fmt.allocPrint(allocator, "  {s}└─{s}\n", .{ c(accent.bar), c(RESET) }));
        },
        .kaomoji_card => {
            const accent = accentColors(block.kaomoji_card.color);
            // Top: kaomoji in its accent color, name to the right
            try out.append(allocator, try std.fmt.allocPrint(allocator, "  {s}┌── {s}{s}  {s}{s}{s}\n", .{ c(accent.bar), c(accent.fg), output.mantra(), c(BOLD), block.kaomoji_card.name, c(RESET) }));
            const desc_lines = try wrap(allocator, block.kaomoji_card.desc, COL_WIDTH - 10);
            for (desc_lines) |line| {
                try out.append(allocator, try std.fmt.allocPrint(allocator, "  {s}│{s}   {s}{s}{s}\n", .{ c(accent.bar), c(RESET), c(TEXT), line, c(RESET) }));
            }
            try out.append(allocator, try std.fmt.allocPrint(allocator, "  {s}│{s}   {s}when:{s}  {s}{s}{s}\n", .{ c(accent.bar), c(RESET), c(TEXT_DIM), c(RESET), c(TEXT_DIM), block.kaomoji_card.when, c(RESET) }));
            try out.append(allocator, try std.fmt.allocPrint(allocator, "  {s}└──{s}\n", .{ c(accent.bar), c(RESET) }));
        },
        .blank => try out.append(allocator, "\n"),
    }
}

// Word-wrap to width, breaking at whitespace. Caller owns the returned slice.
fn wrap(allocator: std.mem.Allocator, text: []const u8, width: u16) ![]const []const u8 {
    var lines = std.ArrayList([]const u8).empty;
    errdefer lines.deinit(allocator);

    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |para| {
        if (para.len == 0) {
            try lines.append(allocator, "");
            continue;
        }
        var start: usize = 0;
        while (start < para.len) {
            var end = @min(start + @as(usize, width), para.len);
            if (end < para.len) {
                var back: usize = end;
                while (back > start and para[back - 1] != ' ') : (back -= 1) {}
                if (back > start) end = back;
            }
            try lines.append(allocator, std.mem.trim(u8, para[start..end], " \t"));
            start = end;
            while (start < para.len and para[start] == ' ') : (start += 1) {}
        }
    }
    return lines.toOwnedSlice(allocator);
}

// --- Screen rendering ---

fn drawHeader() void {
    // Three-row header: face line, title line, divider
    output.raw("\x1b[K");
    output.p("{s}{s} om  man  {s}the whole picture · press ? for keys · q to leave{s}\n", .{ c(BG_BAR), c(PINK), c(TEXT), c(RESET) });
    output.raw("\x1b[K");
    output.p("{s}    {s}{s}{s}  ready when you are{s}\n", .{ c(BG_HI), c(PINK), output.mantra(), c(RESET), c(RESET) });
    output.raw("\x1b[K");
    output.p("{s}{s}{s}\n", .{ c(TEXT_DIM), "─" ** 80, c(RESET) });
}

fn drawBody(lines: []const []const u8, top: usize, total: usize, titles: []const []const u8, cur_section: usize) void {
    _ = total;
    _ = titles;
    _ = cur_section;
    // Each iteration must advance the cursor exactly one row: \x1b[K wipes the
    // previous frame's leftovers on this row, then the line's own trailing
    // newline moves down. The old chapter-divider special case wrote nothing —
    // no newline — so a frame with a divider mid-viewport drew fewer rows than
    // the cursor had climbed, and stale rows bled through as ghosting.
    var i: usize = 0;
    while (i < PAGE_ROWS) : (i += 1) {
        output.raw("\x1b[K");
        const idx = top + i;
        if (idx < lines.len) {
            output.raw(lines[idx]);
        } else {
            output.raw("\n");
        }
    }
}

fn drawFooter(cur_section: usize, total_sections: usize, top: usize, total: usize) void {
    const pct: usize = if (total == 0) 0 else (top * 100) / total;
    output.raw("\x1b[K");
    var sec_buf: [16]u8 = undefined;
    const sec_str = std.fmt.bufPrint(&sec_buf, "{d}", .{cur_section + 1}) catch "?";
    var tot_buf: [16]u8 = undefined;
    const tot_str = std.fmt.bufPrint(&tot_buf, "{d}", .{total_sections}) catch "?";
    var pct_buf: [16]u8 = undefined;
    const pct_str = std.fmt.bufPrint(&pct_buf, "{d}", .{pct}) catch "?";
    output.p("{s}{s}───  {s}{s:>2}/{s}{s}  {s}{s:>3}%{s}  {s}·  ↑↓ scroll  ·  n/p next/prev section  ·  q quit{s}\n", .{
        c(TEXT_DIM), c(BG_HI),
        c(MINT),   sec_str, tot_str, c(RESET),
        c(GOLD),   pct_str, c(RESET),
        c(TEXT_DIM), c(RESET),
    });
}

fn showHelp() void {
    output.cursorUp(frameRows());
    for (0..frameRows()) |_| output.raw("\x1b[K\n");
    output.cursorUp(frameRows());
    drawHeader();
    drawHelpBody();
    drawFooter(0, MAN_PAGE.len, 0, 1);
    output.flush();

    // wait for any key
    var pfd = [_]std.posix.pollfd{.{ .fd = STDIN_FD, .events = std.posix.POLL.IN, .revents = 0 }};
    _ = std.posix.poll(&pfd, -1) catch {};
    var buf: [8]u8 = undefined;
    _ = std.posix.read(STDIN_FD, &buf) catch {};
}

fn drawHelpBody() void {
    const pairs = [_]struct { key: []const u8, desc: []const u8 }{
        .{ .key = "j  /  ↓", .desc = "scroll down one line" },
        .{ .key = "k  /  ↑", .desc = "scroll up one line" },
        .{ .key = "space", .desc = "page down" },
        .{ .key = "b  /  pgup", .desc = "page up" },
        .{ .key = "g  /  home", .desc = "jump to top" },
        .{ .key = "G  /  end", .desc = "jump to bottom" },
        .{ .key = "n  /  →", .desc = "next section" },
        .{ .key = "p  /  ←", .desc = "previous section" },
        .{ .key = "h", .desc = "back to top (table of contents)" },
        .{ .key = "?", .desc = "this help" },
        .{ .key = "q  /  esc", .desc = "leave the manpage" },
    };
    // Every iteration must emit exactly one row (one trailing "\n") — the
    // i == 0 arm used to print a title line plus a blank spacer line
    // ("\n\n") in a single iteration, so the help frame came out PAGE_ROWS+1
    // rows tall while every redraw's `cursorUp(PAGE_ROWS + FOOTER_ROWS)`
    // assumed exactly PAGE_ROWS, drifting the frame up a row on every help
    // dismiss/redraw (same ghosting-drift bug class as the v3.4.5 body fix,
    // NINA-015).
    var i: usize = 0;
    while (i < PAGE_ROWS) : (i += 1) {
        output.raw("\x1b[K");
        if (i == 0) {
            output.p("  {s}{s}om man · keys{s}\n", .{ c(BOLD), c(PINK), c(RESET) });
        } else if (i - 1 < pairs.len) {
            const p = pairs[i - 1];
            output.p("    {s}{s:<14}{s}  {s}{s}{s}\n", .{ c(GOLD), p.key, c(RESET), c(TEXT), p.desc, c(RESET) });
        } else {
            output.raw("\n");
        }
    }
}

// --- Ghosting-drift regression tests (v3.4.5 fixed the body; this extends
// coverage to the help screen, NINA-015) ---
//
// The redraw arithmetic in run()'s key loop (`cursorUp(PAGE_ROWS +
// FOOTER_ROWS)`) only stays correct if every screen-drawing function emits
// exactly the row count its name promises. These tests capture real output
// through output.zig (the same module the TUI writes through) and count
// newlines, so a regression that re-introduces an extra or missing row in
// either function fails loudly instead of drifting the frame on-screen.

fn newlineCount(bytes: []const u8) usize {
    return std.mem.count(u8, bytes, "\n");
}

test "drawHelpBody emits exactly PAGE_ROWS rows regardless of PAGE_ROWS' value" {
    const saved_page_rows = PAGE_ROWS;
    defer PAGE_ROWS = saved_page_rows;

    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    output.init(&writer.writer, std.testing.io, &env, false);

    for ([_]u16{ 5, 12, MIN_PAGE_ROWS }) |rows| {
        PAGE_ROWS = rows;
        writer.clearRetainingCapacity();
        drawHelpBody();
        try std.testing.expectEqual(@as(usize, rows), newlineCount(writer.written()));
    }
}

test "drawBody emits exactly PAGE_ROWS rows" {
    const saved_page_rows = PAGE_ROWS;
    defer PAGE_ROWS = saved_page_rows;
    PAGE_ROWS = 6;

    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    output.init(&writer.writer, std.testing.io, &env, false);

    const lines = [_][]const u8{ "one\n", "two\n", "three\n" };
    drawBody(&lines, 0, lines.len, &.{}, 0);

    try std.testing.expectEqual(@as(usize, PAGE_ROWS), newlineCount(writer.written()));
}

// NINA-017/019 drift guard: the man page and README are hand-maintained prose
// that mirror the actual config path, log path, and search widget keybindings.
// Past drift (fable audit 2026-07-02) left these pointing at a retired
// ~/.om.conf path, a retired ~/.local/share/om/om.log log path, and a
// pre-key-collision-fix i/s/t/c keymap that no longer exists in search.zig.
// This walks MAN_PAGE's own text plus README.md looking for those exact
// retired strings so the drift can't silently reappear. The config section's
// migration note is the one legitimate historical mention of ~/.om.conf
// left in MAN_PAGE (it explains the auto-migration), so that string is
// allowed at most once there, not zero.
fn collectManPageText(gpa: std.mem.Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    for (MAN_PAGE) |section| {
        try buf.appendSlice(gpa, section.title);
        try buf.append(gpa, '\n');
        for (section.blocks) |block| {
            switch (block) {
                .chapter, .title, .badge, .para, .cmd_sig, .cmd_block => |s| {
                    try buf.appendSlice(gpa, s);
                    try buf.append(gpa, '\n');
                },
                .flags_row => |r| {
                    try buf.appendSlice(gpa, r.flag);
                    try buf.append(gpa, '\n');
                    try buf.appendSlice(gpa, r.desc);
                    try buf.append(gpa, '\n');
                },
                .callout => |co| {
                    try buf.appendSlice(gpa, co.body);
                    try buf.append(gpa, '\n');
                },
                .kaomoji_card => |k| {
                    try buf.appendSlice(gpa, k.name);
                    try buf.append(gpa, '\n');
                    try buf.appendSlice(gpa, k.desc);
                    try buf.append(gpa, '\n');
                    try buf.appendSlice(gpa, k.when);
                    try buf.append(gpa, '\n');
                },
                .accent, .blank => {},
            }
        }
    }
    return buf.toOwnedSlice(gpa);
}

test "MAN_PAGE and README stay free of retired config/search-key/log-path strings" {
    const gpa = std.testing.allocator;
    const text = try collectManPageText(gpa);
    defer gpa.free(text);

    try std.testing.expect(std.mem.count(u8, text, "~/.om.conf") <= 1);
    try std.testing.expect(std.mem.count(u8, text, "c copy attr") == 0);
    try std.testing.expect(std.mem.count(u8, text, "~/.local/share/om/om.log") == 0);

    // README.md lives outside src/'s package boundary, so it's read at its
    // build-time-baked absolute path (build_options.readme_path) rather than
    // @embedFile'd, and it's read fresh here rather than cached, so editing
    // README.md is picked up without touching this file.
    const readme = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, build_options.readme_path, gpa, .unlimited);
    defer gpa.free(readme);
    try std.testing.expect(std.mem.count(u8, readme, "~/.om.conf") == 0);
    try std.testing.expect(std.mem.count(u8, readme, "c copy attr") == 0);
    try std.testing.expect(std.mem.count(u8, readme, "~/.local/share/om/om.log") == 0);
}
