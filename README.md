# om

**NixOS Operations Manager** — a fork of [nina](https://kepr.uk/nina) by [Asha Software](https://asha.software).

om is the central interface for interacting with Nix on NixOS. It wraps the full NixOS workflow — rebuilds, generations, flakes, packages, services, store management — into a single, memorable command vocabulary. Written in Zig. Zero dependencies. One binary.

The goal is simple: stop needing to remember the sprawling nix ecosystem command set. Instead of juggling `nixos-rebuild`, `nix profile`, `nix store`, `nix flake`, `nix search`, `nix why-depends`, `nix-tree`, `nix-collect-garbage`, and a dozen more — you just use `om`.

```
$ om pkg search ripgrep
$ om flake apply
$ om gen back
$ om check status
```

---

## install

om is primarily intended for use with [nixos-config](https://github.com/Sanatana-Linux/nixos-config). Add it as a flake input:

```nix
# flake.nix
{
  inputs.om.url = "github:Sanatana-Linux/om";

  outputs = { self, nixpkgs, om, ... }: {
    nixosConfigurations.your-host = nixpkgs.lib.nixosSystem {
      modules = [
        om.nixosModules.om
        # ...
      ];
    };
  };
}
```

This installs `om` system-wide via `environment.systemPackages`.

**Build from source** (standalone):

```sh
git clone https://github.com/Sanatana-Linux/om
cd om
nix build
sudo cp result/bin/om /usr/local/bin/om
```

Requires `nix-command` and `flakes` experimental features.

---

## command structure

Commands are organized into subcommand groups. Each group collects related functionality under a single top-level verb.

### system checks — `om check`

| Subcommand   | Description                              |
| ------------ | ---------------------------------------- |
| `doctor`     | diagnose common issues                   |
| `fmt`        | format nix files                         |
| `info`       | nixos version, kernel, uptime            |
| `local`      | validate config without switching        |
| `log`        | operation history                        |
| `mood`       | plain-language health summary            |
| `status`     | machine health at a glance               |

### flake management — `om flake`

| Subcommand              | Description                              |
| ----------------------- | ---------------------------------------- |
| `apply`                 | rebuild and switch to the new config     |
| `check`                 | validate the flake                       |
| `clone <url>`           | clone a flake repository                 |
| `init`                  | create a new flake.nix                   |
| `lock`                  | regenerate flake.lock                    |
| `pin <input> <rev>`     | pin a flake input to a commit            |
| `show`                  | inspect flake outputs                    |
| `unpin <input>`         | release a pinned flake input              |
| `update`                | update flake inputs                      |
| `update <in>`           | update a specific input                  |
| `upgrade`               | update flake inputs and rebuild          |

### generation management — `om gen`

| Subcommand      | Description                              |
| --------------- | ---------------------------------------- |
| `back`          | roll back to the previous generation     |
| `current`       | show current generation number           |
| `delete <n>`    | delete generation n                      |
| `delete old`    | delete all old generations               |
| `diff`          | compare generations                      |
| `go <n>`        | switch to generation n                   |
| `history`       | list all generations                     |
| `list`          | list generations                         |

### package tools — `om pkg`

| Subcommand        | Description                              |
| ----------------- | ---------------------------------------- |
| `build`           | build a package                          |
| `cache <pkg>`     | check store cache status of a package    |
| `closure <pkg>`   | full closure                             |
| `deps <pkg>`      | direct dependencies                      |
| `develop`         | enter dev shell                          |
| `info`            | list installed packages                  |
| `options <q>`     | search nixos + home-manager options      |
| `path <pkg>`      | store path                               |
| `repl`            | nix repl with nixpkgs                    |
| `run <pkg>`       | run a package without installing         |
| `search <q>`      | find packages                            |
| `size <pkg>`      | closure size                             |
| `tree <pkg>`      | show what depends on a package           |
| `try <pkg>`       | run a package in an interactive shell    |
| `why <pkg>`       | what pulled a package in                 |

### profile management — `om profile`

| Subcommand          | Description                              |
| ------------------- | ---------------------------------------- |
| `info`              | list profile packages                    |
| `install <attr>`    | install a package into your profile      |
| `remove <attr>`     | remove a package from your profile       |
| `upgrade`           | upgrade all profile packages             |

### store tools — `om store`

| Subcommand        | Description                              |
| ----------------- | ---------------------------------------- |
| `clean`           | collect garbage and free store space     |
| `fetch`           | fetch and hash a url                     |
| `hash`            | compute nix hash                         |
| `optimise`        | deduplicate store paths with hard links  |
| `path <attr>`     | store path of a package                  |
| `repair`          | repair corrupted paths                   |
| `verify`          | verify store integrity                   |
| `weight`          | store size and counts                    |

### services — `om service`

| Subcommand        | Description                              |
| ----------------- | ---------------------------------------- |
| `disable <svc>`   | disable at boot                          |
| `enable <svc>`    | enable at boot                           |
| `list`            | list running services                    |
| `logs <svc>`      | show service logs                        |
| `restart <svc>`   | restart a service                        |
| `start <svc>`     | start a service                          |
| `status <svc>`    | service status                           |
| `stop <svc>`      | stop a service                           |

### home manager — `om home`

| Subcommand        | Description                              |
| ----------------- | ---------------------------------------- |
| `apply`           | apply home-manager configuration         |
| `apply --dry`     | preview changes without activating       |
| `back`            | roll back one generation                 |
| `check`           | validate without applying                |
| `diff`            | compare the latest two generations       |
| `edit`            | open home.nix                            |
| `history`         | list all generations                     |
| `init`            | set up home manager for the first time   |
| `init --switch`   | set up and activate immediately          |
| `packages`        | list managed packages                    |

### other top-level commands

| Command              | Description                              |
| -------------------- | ---------------------------------------- |
| `boot`               | boot entries                             |
| `help`               | this message                             |
| `man [topic]`        | open the built-in manual pager           |
| `sync`               | commit and push config submodules        |

---

## hooks

om runs optional executable hook scripts before and after state-changing commands.
Create them in `~/.config/om/hooks/`:

```
pre-apply     post-apply
pre-back      post-back
pre-home      post-home
pre-upgrade   post-upgrade
```

Missing hooks are ignored. Hook files must be executable (`chmod +x`) to run.
If a pre-hook exits non-zero, om shows the last five output lines and asks
whether to continue, defaulting to no. If a post-hook exits non-zero, om shows
a warning after the command's success line.

Example: stop `om flake apply` when your config has uncommitted changes.

```sh
#!/usr/bin/env sh
# ~/.config/om/hooks/pre-apply
if git -C /etc/nixos status --porcelain | grep -q .; then
    echo "uncommitted changes - commit before applying"
    exit 1
fi
```

---

## multi-machine

Any command runs on a remote machine with `--on <name>`. Configure machines in `~/.config/om/config`:

```ini
[machine]
name    = kyoshi
config  = /etc/nixos
local   = true
default = true

[machine]
name    = azula
host    = azula
user    = june
ssh_key = ~/.ssh/id_ed25519
```

```
om flake apply --on azula
om service logs ollama -f --on azula
om check status --all
```

---

## search that stays at the prompt

`om pkg search` opens an inline widget — no fullscreen takeover. Browse results, see versions and licenses, then press enter to install the highlighted package (choosing profile, system, or try afterward).

```
:: search nixpkgs  ripgrep                          12 results

   > ripgrep        14.1.1   free    fast line-oriented search
     ripgrep-all    0.9.6    free    search across file formats
     ugrep          6.0.0    free    grep compatible ripgrep alt

   ripgrep  14.1.1  free
   recursively search directories for a regex pattern
   attr   pkgs.ripgrep

   enter install  tab info  [up/down] nav  esc cancel
```

---

## config

`~/.config/om/config` — plain text, no surprises:

```ini
editor      = hx
generations = 5
confirm     = true
teach       = false
color       = true

[machine]
name    = my-machine
config  = /etc/nixos
local   = true
default = true
```

`teach = true` prints the underlying nix command after each operation so you learn while you work.

---

## what om outputs

```
:: rebuilding kyoshi...

   -> [build output]

:: generation 14  [42.3s]
```

```
:: error: 'firefocks' not found in nixpkgs
   -> try: om pkg search firefox
```

Pink `::` marks om's voice. Green for success. Red for errors. Yellow for warnings. Color auto-disables when stdout is not a TTY. Respects `NO_COLOR`.

---

## how om talks to nix

om is a pure Zig binary with **no internal Nix API, no HTTP, no libnix/FFI
bindings.** It shells out to the `nix`, `nixos-rebuild`, and `ssh` executables
already on PATH — Nix is present by definition on any machine om runs on. Every
Nix interaction is "spawn the CLI and parse its output."

### process spawning

Everything routes through two helpers in `exec.zig`:

- `capture()` — `std.process.run(...)`, captures stdout+stderr, returns the exit
  code. Used for read-only queries like search and eval.
- `stream()` — `std.process.spawn(...)` with inherited stdio, used for
  interactive or long-running commands (rebuilds, dropping into `nix shell`).

### remote machines

For a configured remote host, the same Nix commands run *remotely* over SSH. om
wraps the command in `ssh -o BatchMode=yes [-i key] user@host <cmd>`, shell-quoting
every argument so the remote shell receives exactly the original argv. Search and
eval are local-only; remote execution is used for the state-changing commands.

### the nix commands om runs

| om feature                | nix command spawned                                                    |
| ------------------------- | ---------------------------------------------------------------------- |
| search index build        | `nix search nixpkgs .* --json --no-update-lock-file [--impure]`          |
| live search fallback      | `nix search nixpkgs <query> --json --no-update-lock-file --impure`       |
| index cache keying        | `nix flake metadata nixpkgs --json`                                      |
| package meta (tab detail) | `nix eval --json nixpkgs#<attr>.meta`                                    |
| options search            | `nix eval --json --impure --expr '<nixosSystem eval expr>'`              |
| profile install           | `nix profile install nixpkgs#<attr>`                                     |
| try a package             | `nix shell nixpkgs#<attr>`                                               |
| rebuild / apply           | `nixos-rebuild switch/build --flake ...`                                 |
| rollback / generations    | `nix-env --switch-generation <n>`                                        |
| flake ops                 | `nix flake update/lock --override-input`, `nix build`, `nix develop`, `nix repl` |
| home manager              | `nix run home-manager/<branch> -- init`                                  |
| store management          | `nix store diff-closures`, `nix store gc`                                |
| registry pinning          | `nix registry pin nixpkgs`                                               |

The `--json` outputs are parsed by hand in `api.zig` — there is no JSON library,
just substring scans (e.g. `"rev":"`).

### the search cache

Because `nix search` re-evaluates the entire nixpkgs attrset (~seconds) on every
keystroke, om builds the **full package index once** (`nix search nixpkgs .* --json`),
caches it to `~/.cache/om/packages-<rev>.json` (plus a compact `.bin` form), keyed by
the nixpkgs flake revision. On subsequent runs it reads the cache from disk and serves
searches by in-memory substring matching — invoking Nix again only when the cache is
missing or stale. The nixpkgs revision marker (`~/.cache/om/rev`) is read first so the
fast path doesn't even call `nix`.

---

## built by

**om** is a fork of [nina](https://kepr.uk/nina) by [Asha Software](https://asha.software) — hope in every line of code.

Original: **[nina.asha.software](https://nina.asha.software)** · [source](https://kepr.uk/nina) · [docs](https://nina.asha.software/docs)
