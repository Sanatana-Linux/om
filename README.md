# om

**NixOS Operations Manager** — a fork of [nina](https://kepr.uk/nina) by [Asha Software](https://asha.software).

om wraps the full NixOS workflow in plain, memorable verbs — packages, rebuilds, generations, flakes, services, remote machines. Written in Zig. Zero dependencies. One binary.

```
$ om search ripgrep
$ om apply
$ om back
$ om status --all
```

---

## install

**nix profile** (recommended — instant, per-user, no `sudo`):

```sh
nix profile add 'https://kepr.uk/nina/archive/HEAD.tar.gz#nina'
```

Remove any time with `om goodbye`.

**koh** (build from source via koh):

```sh
koh steal kepr.uk/nina
cd nina && zig build -Doptimize=ReleaseFast
sudo cp zig-out/bin/om /usr/local/bin/om
```

**source archive** (download and build manually):

Download the source archive from [kepr.uk/nina/releases](https://kepr.uk/nina/releases), then:

```sh
tar xf nina-*.tar.gz && cd nina-*/
zig build -Doptimize=ReleaseFast
sudo cp zig-out/bin/om /usr/local/bin/om
```

**linux · nixos 24.05+** — requires `nix-command` and `flakes` experimental features.  
Run `om setup` on first use to enable them automatically.

---

## the commands you'll actually use

```
om apply           rebuild and switch to the new configuration
om apply --dry     preview what would change without switching
om back            roll back to the previous generation
om go <n>          jump to any generation by number
om history         list all generations
om clean           remove old generations and free store space
om sync            commit and push config submodules
om optimize        deduplicate the nix store
om repair          verify and repair the nix store

om search <q>      search nixpkgs inline — browse, install, or try
om option <q>      search NixOS options inline
om options <q>     search NixOS + home-manager options
om install <p>     add a package — profile (instant) or system config
om remove <p>      remove a package from profile or system config
om try <p>         run a package without installing it
om list            show installed packages
om cache <pkg>     check store cache status of a package

om home apply      apply home-manager config
om home back       roll back one home-manager generation
om home history    list home-manager generations
om home edit       open home.nix
om home check      validate home config without switching
om home diff       compare the latest two home generations
om home packages   list packages managed by home-manager

om status          machine health at a glance
om status --all    health across every configured machine
om doctor          diagnose common issues
om diff            what changed between generations
om log             operation history

om service list    list systemd services and their state
om service logs <s> journal logs for a service
om service start/stop/restart <s>

om flake show      inspect flake outputs
om flake update    update lock files
om pin <in> <rev>  pin a flake input to a commit
om unpin <in>      release a pinned flake input
om develop         enter a dev shell
om build           build a flake output
om run <p>         run a package without installing
om tree <pkg>      show what depends on a package
om weight [name]   system closure size in GB

om edit            open configuration.nix in your editor
om edit --dir      open the config directory in your editor
om check           validate config without switching
om fmt             format nix files
om info            nixos version, kernel, uptime
om boot            boot entries

om help            all commands
om --version       version info
```

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

Example: stop `om apply` when your config has uncommitted changes.

```sh
#!/usr/bin/env sh
# ~/.config/om/hooks/pre-apply
if git -C ~/nixos-config status --porcelain | grep -q .; then
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
om apply --on azula
om service logs ollama -f --on azula
om status --all
```

```
:: status

   kyoshi   gen 348   3m ago    42 GB
   azula    gen 192   14m ago   18 GB
```

---

## search that stays at the prompt

`om search` opens an inline widget — no fullscreen takeover. Browse results, see versions and licenses, then press enter to install the highlighted package (choosing profile, system, or try afterward).

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

## install that actually works

`om install` uses `nix search nixpkgs` directly — no external API, no network dependency after your first channel update, no silent failures. Works offline.

Two install paths, your choice:

- **profile** — instant. package available immediately. no rebuild.
- **system** — opens your editor at the right line in `configuration.nix`, then offers to apply.

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
   -> try: om search firefox
```

Pink `::` marks om's voice. Green for success. Red for errors. Yellow for warnings. Color auto-disables when stdout is not a TTY. Respects `NO_COLOR`.

---

## built by

**om** is a fork of [nina](https://kepr.uk/nina) by [Asha Software](https://asha.software) — hope in every line of code.

Original: **[nina.asha.software](https://nina.asha.software)** · [source](https://kepr.uk/nina) · [docs](https://nina.asha.software/docs)
