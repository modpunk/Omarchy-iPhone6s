# Omarchy on the phone (optional `omarchy-core` stage)

[Omarchy](https://github.com/basecamp/omarchy) is the Arch + Hyprland desktop the laptop runs
(4.0.2 there, as the `omarchy` package in `/usr/share/omarchy`). This stage adds the parts of it that
make sense on the iPhone 6s RAM userland, next to the Omarchy Phone shell: Omarchy's 22 themes and its
theme switching, the terminal theme, Omarchy's menu (as a phone version) on Omarchy's keys, and the
helper scripts behind those. It costs **7.3 MiB of tmpfs** (so about 7 MiB of the phone's RAM; about
1.8 MiB more in `rootfs.tar.xz`).

Omarchy is MIT licensed, copyright David Heinemeier Hansson. The stage installs its licence as
`/usr/share/licenses/omarchy/LICENSE` and `/usr/share/omarchy/LICENSE` (copied from
`tools/userland/omarchy-core/LICENSE.omarchy`, the upstream `LICENSE` verbatim). Omarchy's files are
installed unchanged under `/usr/share/omarchy`. Phone replacements live apart, in
`/usr/share/omarchy-core`, and each one says what it replaces. The one adapted upstream script
(`omarchy-theme-set-gnome`) carries the attribution.

## Running it

The stage is a separate script, so it isn't part of the default build. It works on a tree that
`build-rootfs.sh` has installed and configured:

```sh
STAGES="install config" tools/userland/build-rootfs.sh
tools/userland/omarchy-core.sh                 # install + check
STAGES="strip check pack" tools/userland/build-rootfs.sh
```

`omarchy-core.sh` enters the same user namespace as `build-rootfs.sh` and chroots through
qemu-aarch64 to run Omarchy's own `omarchy-theme-set` as the phone user. You can run it more than
once. Run it again after any later `config` stage, because `config` copies `/etc/skel` over the
user's `~/.config`. Settings:

| env | default | |
|---|---|---|
| `ROOT` | `$OUT/root` | the tree to change. Point it at a copy to try the stage out (below) |
| `OMARCHY_SRC` | `/usr/share/omarchy` | the Omarchy tree to copy from. It is only read, never changed |
| `OMARCHY_VERSION` | `pacman -Q omarchy` | recorded in `/usr/share/omarchy-core/OMARCHY_VERSION` and `/etc/omarchy-phone-release`. `$OMARCHY_SRC/version` says `4.0.0.alpha` even on 4.0.2, so the stage records the pacman version instead |
| `THEME` | `tokyo-night` | the first theme (also the phone shell's built-in palette) |
| `CORE_STAGES` | `install check` | `check` alone re-runs the checks |

The packages come from the Arch Linux ARM mirror. If the mirror is down, the stage falls back to the
build's package databases in `$OUT/dbroot` and the package cache.

**Trying it on a copy** (`$OUT` is on btrfs, so the reflink copy is instant):

```sh
OUT=~/Work/hoolock-iphone5s/build/userland
unshare --user --map-auto --map-root-user cp -a --reflink=always $OUT/root $OUT/root-try
ROOT=$OUT/root-try tools/userland/omarchy-core.sh
unshare --user --map-auto --map-root-user rm -rf $OUT/root-try
```

The stage was validated this way on the 2026-09-29 image (the Omarchy Phone build, 1100 MiB). It ran
twice (the second run changed nothing: +0.0 MiB, one hook line), and all 19 checks passed. The
checks: `bash -n` on the 31 shell scripts (the Python menu is parsed separately); theme state written (`colors.toml`, `foot.ini`, `hyprland.lua`,
`shell.toml`, `btop.theme`, `theme.name`); `colors.toml` has every key the phone shell's `Theme.qml`
reads; `omarchy-theme-list` (22), `omarchy-theme-current`, and `omarchy theme list` through the
dispatcher; `omarchy-version`; a switch to Catppuccin Latte (light) and back; `foot --check-config`
with the user `foot.ini` and the theme include; the phone menu parsed (root: Style, Setup, Update,
Trigger, Learn, About, System); and fzf and jq running under qemu. The new ELF files (`fzf`, `jq`,
`libjq`, `libonig`) all have 64 KiB `PT_LOAD` alignment, which is fine for 16K pages. The laptop's
Hyprland 0.56.2 `--verify-config` accepts `omarchy-core.lua`, and it also accepts the image's whole
`hyprland.lua` with the hook appended. None of this has run on the phone yet.

## What it installs

| where | what |
|---|---|
| packages | `fzf` 0.74 (5.6 MiB, the picker), `jq` 1.8 + `oniguruma` (1.1 MiB, used by Omarchy scripts) |
| `/usr/share/omarchy/bin` | 21 Omarchy scripts, unchanged (`omarchy-core/bin-upstream.txt`): the `omarchy` dispatcher, `omarchy-theme-set` and its template/colour/foot/tmux helpers, `theme-list/current/dir`, `font-list/current/set`, `menu-timezone`, `notification-send`, `hook`, `cmd-present/missing`, `restart-terminal/btop` |
| `/usr/share/omarchy/themes` | all 22 themes, colour files only: `colors.toml`, plus `btop.theme`, `hyprland.lua`, `chromium.theme`, `icons.theme`, `keyboard.rgb`, `shell.lock.toml` where a theme has them. No wallpapers, previews, Plymouth unlock images, or Neovim/VS Code descriptors (those are 118 of the 119 MB) |
| `/usr/share/omarchy/default` | `themed/*.tpl` (the 17 templates `omarchy-theme-set` renders) and `omarchy/omarchy-menu.jsonc` (the menu definition) |
| `/usr/share/omarchy-core/bin` | the phone replacements (next section) |
| `/usr/share/omarchy-core` | `omarchy-menu.phone.jsonc` (which menu rows the phone shows), `keybindings.txt`, `hypr/omarchy-core.lua`, `OMARCHY_VERSION` |
| `/usr/local/bin` | symlinks to all of the above, plus 11 Omarchy helper names that point at `omarchy-core-noop` (`bin-noop.txt`) |
| `/etc/profile.d/omarchy.sh` | `OMARCHY_PATH`, `OMARCHY_CORE`, `OMARCHY_THEME_SKIP_BACKGROUND=1` for SSH and getty shells |
| `/usr/share/applications/omarchy-menu.desktop` | "Omarchy" on the phone's home grid (a touch way into the menu) |
| `~/.config` (`/etc/skel` and the user) | `foot/foot.ini` (see below), `omarchy/{themes,extensions}`, `omarchy/hooks/theme-set.d/10-omarchy-phone-shell` |
| `~/.config/hypr/hyprland.lua` | **one appended line** (`pcall(dofile, "/usr/share/omarchy-core/hypr/omarchy-core.lua")`, with a marker comment). This is the only point where the stage meets the Omarchy Phone session config. It is appended at build time, not in git |
| `~/.local/state/omarchy/current` | the first theme, rendered by `omarchy-theme-set` in the rootfs (also in `/etc/skel`) |

### Phone replacements

Omarchy 4 routes its menus, pickers, OSDs and theme refreshes through `omarchy-shell`, its desktop
QuickShell. The phone runs the Omarchy Phone shell instead, so these stand in:

| command | on the phone |
|---|---|
| `omarchy-menu [toggle\|summon\|close] [route]` | reads Omarchy's `omarchy-menu.jsonc`, keeps the rows listed in `omarchy-menu.phone.jsonc` (with overrides and a few phone rows), then applies the user's `~/.config/omarchy/extensions/omarchy-menu.jsonc` in Omarchy's format. It shows the menu with fzf in a floating foot window (`app-id` `omarchy-menu`). It honours `when`, `checked`, `target` and aliases; Esc goes back. Python (already in the image for the Phone app) |
| `omarchy-menu-select` | same arguments and output as Omarchy's, but uses fzf. It opens a foot window when no terminal is attached. Upstream needs perl (63 MiB in ALARM) and the shell's menu plugin |
| `omarchy-shell` | answers with success and does nothing, so `set -e` scripts like `omarchy-menu-timezone` finish after they have done their work |
| `omarchy-restart-shell` | restarts the Omarchy Phone shell (QuickShell) with the old process's environment. It refuses while the phone is locked |
| `omarchy-system-lock` | `ophone-ctl lock` |
| `omarchy-version` | prints the recorded Omarchy version (the phone has no `omarchy` package) |
| `omarchy-theme-set-gnome` | sets light/dark for GTK/libadwaita (the Phone app). It leaves the icon theme alone: Omarchy's themes name Yaru, which ALARM doesn't package |
| `omarchy-menu-keybindings` | the phone's key list (`keybindings.txt`) |
| `omarchy-core-about`, `omarchy-core-screenshot` | the About screen and a full-screen `grim` shot |
| `omarchy-core-noop` | answers for `restart-hyprctl/opencode/helix`, `theme-set-pi/claude/browser/vscode/obsidian/keyboard`, `theme-switcher`, `theme-bg-cache` (desktop apps and caches that `omarchy-theme-set` refreshes) |

### Menu and keys

Omarchy 4's keys (`default/hypr/bindings/utilities.lua`), in `omarchy-core.lua`:

| key | opens |
|---|---|
| SUPER + SPACE | the menu (root) |
| SUPER + ESCAPE | System (Lock) |
| SUPER + SHIFT + CTRL + SPACE | the theme picker |
| SUPER + CTRL + C | Capture (Screenshot) |
| SUPER + CTRL + O | Toggle (Silent mode) |

Pressing a key again while the menu is open closes it. Omarchy's SUPER + K (keybindings) is not
bound, because the phone uses it for the on-screen keyboard; the key list is under Learn >
Keybindings instead.

The phone menu has these rows: **Style** (Theme, Font), **Setup** (Bluetooth via `bluetoothctl`),
**Update** (Timezone via Omarchy's `omarchy-menu-timezone`, Process > Phone shell, Password > User),
**Trigger** (Capture > Screenshot, Toggle > Silent mode), **Learn** (Keybindings), **About**, and
**System** (Lock). It has no Suspend, Reboot or Shutdown, because the rootfs lives in RAM: coming
back from any of those means a DFU boot and a new push from the laptop.

### Colours

- **Phone shell.** `Theme.qml` in the Omarchy Phone shell already reads
  `~/.local/state/omarchy/current/theme/colors.toml` (background, lighter_background, selection,
  foreground or bright_foreground, dark_foreground, accent, green, red, yellow). Omarchy 4's
  `colors.toml` has all of these keys. The stage writes that file at build time, so the first boot is
  themed.
- **Terminals.** `~/.config/foot/foot.ini` includes `/etc/xdg/foot/foot.ini` (the image's settings),
  sets Omarchy's font (JetBrainsMono Nerd Font, size 8 for the phone), then includes the theme's
  `foot.ini`. Omarchy's `omarchy-theme-set-foot` recolours foot windows that are already open.
- **GTK apps** switch between light and dark.

**Limitation: the phone shell doesn't follow a theme change live.** `omarchy-theme-set` replaces the
whole `current/theme` directory (it does `rm -rf`, then `mv next-theme theme`). QuickShell's
`FileView` watch doesn't survive that. This was reproduced with QuickShell 0.3.1 (the phone's
version) and the same swap: the first load fired, the later swaps didn't. The stage works around it
with an Omarchy `theme-set` hook that runs `omarchy-restart-shell`. So a theme change restarts the
phone shell, which takes a few seconds on llvmpipe and hasn't been timed on the phone. The proper fix
belongs in Omarchy Phone's `Theme.qml`: watch `current/theme.name`, which is rewritten in place in a
directory that stays, and re-read `colors.toml` when it changes. Once that is in, the hook can go.

## Inventory

Sizes are "installed size" from the Arch Linux ARM (aarch64) repos the image uses (2026-09-29).
"Already in image" means the image pays for it anyway. RAM is tmpfs: every installed MiB lives in
RAM (zram can compress the parts nobody touches).

| Omarchy component | aarch64 (ALARM) | RAM cost | on the phone? | decision |
|---|---|---|---|---|
| `bin/` scripts (428, bash, 1.7 MB) | plain scripts | tiny | about 30 are useful. Most drive `omarchy-shell`, pacman/AUR, x86 hardware (`hw-*`), or desktop apps | **21 installed unchanged**, 8 replaced, 3 phone helpers, 11 no-op names |
| themes (22) | plain files | 0.25 MB without wallpapers (119 MB with) | yes | **installed, colours only** |
| theme switching (`omarchy-theme-set`, 17 templates) | plain scripts | tiny | yes | **installed**, runs unchanged (tested headless in the rootfs) |
| `omarchy-shell` (QuickShell desktop shell: bar, menu, notifications, OSD, lock, wallpaper) | `quickshell` 0.3.1 is already in the image; the shell is 2 MB of QML | a second QuickShell process: tens of MB of RSS on the software scene graph (not measured), with about 250 MB free | duplicates the Omarchy Phone shell | **no** |
| menu (`omarchy-menu` = the shell's menu plugin; `omarchy-menu.jsonc`) | the definition is JSONC | fzf 5.6 MiB | yes | **phone version** over Omarchy's definition |
| waybar | 3.0 MiB | | Omarchy 4 no longer ships it (its bar is part of `omarchy-shell`); the phone has a status bar | no |
| walker / elephant (launcher) | not in ALARM | | dropped in Omarchy 4; the phone shell has the app grid | no |
| mako (notifications) | 0.2 MiB | | dropped in Omarchy 4; the phone shell is the notification server. `omarchy-notification-send` (busctl) reaches it | no (not needed) |
| Hyprland config (`default/hypr/*.lua`) | Lua for 0.56, like the phone | | desktop tiling, gaps, uwsm autostart; conflicts with the phone layout | only the **menu keys** carried over |
| keybindings | | | the menu keys, yes. SUPER + K clashes with the phone keyboard | **5 keys** (table above) |
| terminal: foot config + theme include | foot 1.28 is already in the image | none | yes | **adopted** (user `foot.ini`) |
| terminal: alacritty / ghostty / kitty | alacritty 7.8 MiB; ghostty not in ALARM | | GL terminals on llvmpipe; foot is the cheap one | no |
| fonts: JetBrainsMono Nerd Font | `ttf-jetbrains-mono-nerd` 232 MiB (Omarchy's `-basic` build is only in Omarchy's own repo) | | the image already carries a 10 MB subset (Regular/Bold) | reuse the subset; `font-list/set` installed |
| Wi-Fi: NetworkManager (Omarchy 4) | 19.9 MiB + deps | | no Wi-Fi hardware yet | no (the image keeps iwd, dormant) |
| Wi-Fi: iwd + impala (Omarchy 3) | iwd is already in the image; impala 4.7 MiB | | no Wi-Fi hardware yet | no; **impala is the candidate** once Wi-Fi works |
| Bluetooth: bluetui (Omarchy 3) / shell panel (Omarchy 4) | bluetui 3.2 MiB | | yes | menu row runs `bluetoothctl` (already in the image) |
| audio: wiremix, pamixer | 3.3 / 0.3 MiB | | the kernel has no ALSA (`CONFIG_SND` off) | no |
| timezone (`omarchy-menu-timezone`, timedatectl) | tzdata is already in the image | none | yes | **installed**, works through the fzf picker and the `omarchy-shell` stand-in |
| time (`omarchy-update-time`, tzupdate) | tzupdate not in ALARM | | needs `systemd-timesyncd`, which the image doesn't enable; `push-rootfs.sh` sets the clock | no |
| lock / idle: hyprlock, hypridle | 1.1 / 0.4 MiB | | the phone shell owns the lock screen | no; `omarchy-system-lock` → `ophone-ctl lock` |
| nightlight: hyprsunset | 0.3 MiB | | needs a colour transform; simpledrm and software rendering | no |
| screenshots: grim, slurp, satty | grim is already in the image; satty 5.2 MiB | | a full-screen shot is enough | **grim row** in Capture |
| screen recording: gpu-screen-recorder | 0.7 MiB | | no GPU | no |
| boot/login: plymouth, limine, snapper, sddm, uwsm | 3.0 / 5.3 / - / 6.1 / 0.3 MiB | | the phone boots through checkm8 → pongoOS → m1n1, and the session is a systemd user unit | no |
| `omarchy-settings` (`/etc/skel`, migrations, system drop-ins) | `any` package (Omarchy repo) | | the migrations and drop-ins assume the desktop install | no |
| updates (`omarchy-update`, pkgs.omarchy.org) | Omarchy's repo is x86_64 | | the image is rebuilt on the laptop instead | no |
| gum (TUI prompts) | 14.2 MiB | | only the desktop scripts need it; fzf covers picking | no |
| perl (upstream `omarchy-menu-select`) | 62.9 MiB | | replaced | no |
| jq | 0.6 MiB + oniguruma 0.7 MiB | | the dispatcher and `notification-send` use it | **installed** |
| CLI set: btop, fastfetch, bat, eza, zoxide, starship, tmux, lazygit, neovim | 1.7, 2.1, 4.7, 1.6, 1.0, 10.3, 1.4, 20.4, 30.5 MiB | | nice to have over SSH | not installed. btop/fastfetch/tmux are cheap candidates (btop and tmux are themed by the installed scripts) |
| desktop apps: chromium, nautilus, mpv, obsidian, libreoffice, ... | chromium alone is 439 MiB | | far over the RAM budget | no |

### Size

Measured on the image, not counting docs and man pages (strip removes those):

| part | tmpfs |
|---|---|
| fzf | 5.6 MiB |
| jq + libjq + oniguruma | 1.2 MiB |
| `/usr/share/omarchy` (21 scripts, 22 themes, templates, menu) | 0.25 MB |
| `/usr/share/omarchy-core` + links + env | 0.02 MB |
| rendered theme (user + `/etc/skel`) | 0.18 MB |
| **total** | **+7.3 MiB** (1100 → 1108 MiB); about 1.8 MiB more in `rootfs.tar.xz` |

At runtime, the menu costs a foot window and fzf only while it is open. The theme hook restarts the
phone shell but doesn't add a process.

## Not done yet

- **Nothing has run on the phone.** Still to try there: the keys from the Bluetooth keyboard, the
  floating menu window on the scrolling layout, taps in fzf inside foot, `omarchy-restart-shell`
  bringing the shell back with its environment, and `gsettings`/dconf for the Phone app.
- Live theme follow needs the `Theme.qml` change described under Colours (in the Omarchy Phone repo).
- `build-rootfs.sh` doesn't call this stage. Run it by hand between `config` and `strip`, or add it
  to the default `STAGES` once it has proven itself.
- The Omarchy files come from the laptop's install (`OMARCHY_SRC`). For a build that doesn't depend
  on the host, fetch the `any` package from `pkgs.omarchy.org` (or a pinned git tag) and point
  `OMARCHY_SRC` at the unpacked tree.
- Wi-Fi (impala over iwd) once there is a Wi-Fi driver. Cheap extras if wanted: btop, fastfetch,
  tmux.
