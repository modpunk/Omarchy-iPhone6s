#!/usr/bin/env bash
# Optional image stage: the parts of Omarchy (basecamp/omarchy, MIT) that make
# sense on the Omarchy Phone. Omarchy's themes, theme switching and templates,
# its menu definition behind a phone menu (fzf in foot), its menu keys, and
# the helper scripts those need. See docs/omarchy-core.md for what is left
# out and why.
#
# Runs on a rootfs tree that build-rootfs.sh has installed and configured,
# before strip/check/pack:
#   STAGES="install config" tools/userland/build-rootfs.sh
#   tools/userland/omarchy-core.sh
#   STAGES="strip check pack" tools/userland/build-rootfs.sh
# Re-running is safe; rerun it after any later `config` stage (config copies
# /etc/skel over the user's ~/.config again).
#
# Env: OUT (default ~/Work/hoolock-iphone5s/build/userland), ROOT (default
#      $OUT/root; point it at a copy to try the stage), USERNAME (omarchy),
#      OMARCHY_SRC (an Omarchy tree; default /usr/share/omarchy, read only),
#      OMARCHY_VERSION (default: `pacman -Q omarchy` on this host),
#      THEME (first theme; default tokyo-night), CORE_STAGES ("install check").
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DATA="$HERE/omarchy-core"
OUT="${OUT:-$HOME/Work/hoolock-iphone5s/build/userland}"
ROOT="${ROOT:-$OUT/root}"
CONF="$HERE/pacman-alarm.conf"
USERNAME="${USERNAME:-omarchy}"
OMARCHY_SRC="${OMARCHY_SRC:-/usr/share/omarchy}"
THEME="${THEME:-tokyo-night}"
CORE_STAGES="${CORE_STAGES:-install check}"
QEMU=/usr/bin/qemu-aarch64-static
MARK="-- omarchy-core (tools/userland/omarchy-core.sh)"

log() { printf '\033[1m[omarchy-core]\033[0m %s\n' "$*"; }
die() { printf '[omarchy-core] ERROR: %s\n' "$*" >&2; exit 1; }
list() { sed 's/#.*//' "$1" | awk 'NF {print $1}'; }

if [ "$(id -u)" != 0 ]; then
	[ -x "$QEMU" ] || die "need $QEMU (pacman -S qemu-user-static qemu-user-static-binfmt)"
	[ -d "$ROOT/usr/lib" ] && [ -d "$ROOT/home/$USERNAME" ] || die "no configured rootfs at $ROOT (run build-rootfs.sh install config first)"
	[ -d "$OMARCHY_SRC/themes" ] && [ -d "$OMARCHY_SRC/bin" ] || die "no Omarchy tree at $OMARCHY_SRC (set OMARCHY_SRC)"
	if [ -z "${OMARCHY_VERSION:-}" ]; then
		OMARCHY_VERSION="$(pacman -Q omarchy 2>/dev/null | awk '{print $2}')"
		OMARCHY_VERSION="${OMARCHY_VERSION:-$(cat "$OMARCHY_SRC/version" 2>/dev/null || echo unknown)}"
	fi
	export OMARCHY_VERSION
	exec unshare --user --map-auto --map-root-user --mount --pid --fork --kill-child \
		env HOME="$HOME" OUT="$OUT" ROOT="$ROOT" USERNAME="$USERNAME" OMARCHY_SRC="$OMARCHY_SRC" \
		OMARCHY_VERSION="$OMARCHY_VERSION" THEME="$THEME" CORE_STAGES="$CORE_STAGES" "$0" "$@"
fi

# ---- inside the namespace: uid 0 maps to the calling user -----------------
# Same chroot setup as build-rootfs.sh (kept separate so the two scripts can
# change independently).
mount_chroot() {
	mkdir -p "$ROOT"/{dev,proc,run,tmp}
	if ! mountpoint -q "$ROOT/dev"; then
		mount -t tmpfs -o mode=755 dev "$ROOT/dev"
		for n in null zero full random urandom tty; do
			touch "$ROOT/dev/$n"; mount --bind "/dev/$n" "$ROOT/dev/$n"
		done
		ln -s /proc/self/fd "$ROOT/dev/fd"; mkdir "$ROOT/dev/shm" "$ROOT/dev/pts"
	fi
	mountpoint -q "$ROOT/proc" || mount -t proc proc "$ROOT/proc"
	mountpoint -q "$ROOT/run" || mount -t tmpfs run "$ROOT/run"
	cp "$QEMU" "$ROOT/usr/bin/qemu-aarch64-static"
}
umount_chroot() {
	for m in run proc dev; do
		mountpoint -q "$ROOT/$m" && { umount -R "$ROOT/$m" 2>/dev/null || umount -l "$ROOT/$m"; }
	done
	rm -f "$ROOT/usr/bin/qemu-aarch64-static"
}
trap umount_chroot EXIT
uid="$(awk -F: -v u="$USERNAME" '$1==u {print $3}' "$ROOT/etc/passwd")"
gid="$(awk -F: -v u="$USERNAME" '$1==u {print $4}' "$ROOT/etc/passwd")"
[ -n "$uid" ] || die "no user $USERNAME in $ROOT/etc/passwd"
# Run as the phone user inside the rootfs, with the session's environment.
as_user() {
	chroot --userspec="$uid:$gid" "$ROOT" /usr/bin/env -i HOME="/home/$USERNAME" USER="$USERNAME" \
		PATH=/usr/local/bin:/usr/bin LANG=C.UTF-8 TERM=dumb OMARCHY_PATH=/usr/share/omarchy \
		OMARCHY_CORE=/usr/share/omarchy-core "$@"
}

rootsize() {
	du -sb --exclude="$ROOT/usr/share/doc" --exclude="$ROOT/usr/share/man" --exclude="$ROOT/var/lib/pacman/sync" \
		--exclude="$ROOT/usr/share/info" "$ROOT" | cut -f1
}

stage_install() {
	# Sizes leave out what the strip stage deletes anyway (docs, man pages).
	local before; before="$(rootsize)"
	mount_chroot

	log "packages: $(list "$DATA/packages.txt" | tr '\n' ' ')"
	# shellcheck disable=SC2046
	if ! pacman --root "$ROOT" -Q $(list "$DATA/packages.txt") >/dev/null 2>&1; then
		local pm=(pacman --root "$ROOT" --config "$CONF" --gpgdir "$OUT/gnupg" --cachedir "$OUT/cache" --noconfirm --needed)
		# shellcheck disable=SC2046
		if ! "${pm[@]}" -Sy $(list "$DATA/packages.txt"); then
			# Mirror down: the build's own package DBs + package cache.
			log "mirror sync failed; using the package DBs in $OUT/dbroot and the cache"
			cp "$OUT"/dbroot/var/lib/pacman/sync/*.db "$ROOT/var/lib/pacman/sync/" || die "no $OUT/dbroot DBs"
			"${pm[@]}" -S $(list "$DATA/packages.txt") || die "pacman could not install $(list "$DATA/packages.txt" | tr '\n' ' ')"
		fi
		rm -rf "$ROOT"/var/lib/pacman/sync/*   # as the strip stage does
	fi

	log "Omarchy $OMARCHY_VERSION from $OMARCHY_SRC"
	local o="$ROOT/usr/share/omarchy" c="$ROOT/usr/share/omarchy-core" f t
	rm -rf "$o" "$c"
	mkdir -p "$o/bin" "$o/themes" "$o/default/omarchy" "$c"
	for f in $(list "$DATA/bin-upstream.txt"); do
		[ -f "$OMARCHY_SRC/bin/$f" ] || die "$OMARCHY_SRC/bin/$f missing (Omarchy renamed it?)"
		install -m 755 "$OMARCHY_SRC/bin/$f" "$o/bin/$f"
	done
	# Themes: colours and colour files only. Wallpapers, previews, the Plymouth
	# unlock image and the Neovim/VS Code descriptors are 118 of 119 MB.
	for t in "$OMARCHY_SRC"/themes/*/; do
		t="$(basename "$t")"; mkdir -p "$o/themes/$t"
		find "$OMARCHY_SRC/themes/$t" -maxdepth 1 -type f \
			! -iname '*.png' ! -iname '*.jpg' ! -name neovim.lua ! -name vscode.json \
			-exec cp {} "$o/themes/$t/" \;
		[ -s "$o/themes/$t/colors.toml" ] || die "theme $t has no colors.toml"
	done
	cp -a "$OMARCHY_SRC/default/themed" "$o/default/"
	cp "$OMARCHY_SRC/default/omarchy/omarchy-menu.jsonc" "$o/default/omarchy/"
	cp "$OMARCHY_SRC/logo.txt" "$OMARCHY_SRC/version" "$o/"
	install -D -m 644 "$DATA/LICENSE.omarchy" "$o/LICENSE"
	install -D -m 644 "$DATA/LICENSE.omarchy" "$ROOT/usr/share/licenses/omarchy/LICENSE"

	log "phone pieces -> /usr/share/omarchy-core, /usr/local/bin"
	mkdir -p "$c/bin" "$c/hypr"
	install -m 755 "$DATA"/bin/* "$c/bin/"
	install -m 644 "$DATA/omarchy-menu.phone.jsonc" "$DATA/keybindings.txt" "$c/"
	install -m 644 "$DATA/hypr/omarchy-core.lua" "$c/hypr/"
	echo "$OMARCHY_VERSION" > "$c/OMARCHY_VERSION"
	# /usr/local/bin is on every PATH (SSH, getty, the Hyprland session). The
	# omarchy dispatcher scans the directory it runs from, so it lists these.
	find "$ROOT/usr/local/bin" -maxdepth 1 \( -lname '/usr/share/omarchy/bin/*' -o -lname '/usr/share/omarchy-core/bin/*' \) -delete
	for f in $(list "$DATA/bin-upstream.txt"); do ln -sfn "/usr/share/omarchy/bin/$f" "$ROOT/usr/local/bin/$f"; done
	for f in "$DATA"/bin/*; do ln -sfn "/usr/share/omarchy-core/bin/${f##*/}" "$ROOT/usr/local/bin/${f##*/}"; done
	for f in $(list "$DATA/bin-noop.txt"); do ln -sfn /usr/share/omarchy-core/bin/omarchy-core-noop "$ROOT/usr/local/bin/$f"; done
	# The same three variables for every way in: login shells (profile.d), the
	# systemd user manager and so the phone session (environment.d), and SSH
	# commands without a login shell (pam_env reads /etc/environment).
	install -D -m 644 "$DATA/profile.d/omarchy.sh" "$ROOT/etc/profile.d/omarchy.sh"
	mkdir -p "$ROOT/etc/environment.d"
	sed -n 's/^export //p' "$DATA/profile.d/omarchy.sh" > "$ROOT/etc/environment.d/50-omarchy.conf"
	touch "$ROOT/etc/environment"
	sed -i '/^OMARCHY_\(PATH\|CORE\|THEME_SKIP_BACKGROUND\)=/d' "$ROOT/etc/environment"
	cat "$ROOT/etc/environment.d/50-omarchy.conf" >> "$ROOT/etc/environment"
	install -D -m 644 "$DATA/applications/omarchy-menu.desktop" "$ROOT/usr/share/applications/omarchy-menu.desktop"
	chown -R 0:0 "$o" "$c" "$ROOT/usr/share/licenses/omarchy"

	log "user setup (/etc/skel and /home/$USERNAME)"
	local h
	for h in "$ROOT/etc/skel" "$ROOT/home/$USERNAME"; do
		mkdir -p "$h/.config/foot" "$h/.config/omarchy/themes" "$h/.config/omarchy/extensions" \
			"$h/.config/omarchy/hooks/theme-set.d" "$h/.local/state/omarchy/current"
		[ -e "$h/.config/foot/foot.ini" ] || install -m 644 "$DATA/foot/foot.ini" "$h/.config/foot/foot.ini"
		install -m 644 "$DATA/hooks/10-omarchy-phone-shell" "$h/.config/omarchy/hooks/theme-set.d/"
		# The one hook into the phone session's Hyprland config: a guarded
		# dofile, so a missing or broken omarchy-core.lua can't stop the session.
		f="$h/.config/hypr/hyprland.lua"
		[ -f "$f" ] || die "$f missing (build-rootfs.sh config stage not run?)"
		grep -qF -- "$MARK" "$f" || printf '\n%s\npcall(dofile, "/usr/share/omarchy-core/hypr/omarchy-core.lua")\n' "$MARK" >> "$f"
	done
	chown -R 0:0 "$ROOT/etc/skel"
	chown -R "$uid:$gid" "$ROOT/home/$USERNAME/.config" "$ROOT/home/$USERNAME/.local"

	log "first theme: $THEME (omarchy-theme-set, headless, as $USERNAME)"
	as_user OMARCHY_THEME_HEADLESS=1 /usr/local/bin/omarchy-theme-set "$THEME" \
		|| die "omarchy-theme-set $THEME failed in the rootfs"
	# New users get the same starting theme.
	rm -rf "$ROOT/etc/skel/.local/state/omarchy/current"
	cp -a "$ROOT/home/$USERNAME/.local/state/omarchy/current" "$ROOT/etc/skel/.local/state/omarchy/"
	chown -R 0:0 "$ROOT/etc/skel/.local"
	find "$ROOT/tmp" -mindepth 1 -delete   # omarchy-theme-set's lock file

	if [ -f "$ROOT/etc/omarchy-phone-release" ]; then
		sed -i '/^omarchy-core /d' "$ROOT/etc/omarchy-phone-release"
		echo "omarchy-core omarchy $OMARCHY_VERSION" >> "$ROOT/etc/omarchy-phone-release"
	fi
	umount_chroot
	local after; after="$(rootsize)"
	awk -v a="$after" -v b="$before" 'BEGIN {printf "omarchy-core: +%.1f MiB unpacked (%.0f -> %.0f MiB)\n", (a-b)/1048576, b/1048576, a/1048576}' \
		| tee "$OUT/omarchy-core.size.txt"
}

stage_check() {
	log "checks"
	mount_chroot
	local fail=0 f s="/home/$USERNAME/.local/state/omarchy/current/theme"
	ok() { printf '  ok    %s\n' "$*"; }
	bad() { printf '  FAIL  %s\n' "$*"; fail=1; }
	for f in "$ROOT"/usr/share/omarchy/bin/* "$ROOT"/usr/share/omarchy-core/bin/*; do
		head -1 "$f" | grep -q python && continue
		chroot "$ROOT" /usr/bin/bash -n "${f#"$ROOT"}" 2>/dev/null || bad "bash -n ${f#"$ROOT"}"
	done
	ok "bash -n on $(grep -L python "$ROOT"/usr/share/omarchy/bin/* "$ROOT"/usr/share/omarchy-core/bin/* | wc -l) scripts"
	chroot "$ROOT" /usr/bin/python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' \
		/usr/share/omarchy-core/bin/omarchy-menu && ok "omarchy-menu parses (python3)" || bad "omarchy-menu syntax"
	for f in colors.toml foot.ini hyprland.lua shell.toml btop.theme; do
		[ -s "$ROOT$s/$f" ] && ok "theme state $f" || bad "no $s/$f"
	done
	[ "$(cat "$ROOT/home/$USERNAME/.local/state/omarchy/current/theme.name" 2>/dev/null)" = "$THEME" ] \
		&& ok "theme.name = $THEME" || bad "theme.name"
	# The keys the phone shell's Theme.qml reads from colors.toml.
	for f in background lighter_background selection foreground bright_foreground dark_foreground accent green red yellow; do
		grep -q "^$f = \"#" "$ROOT$s/colors.toml" || bad "colors.toml has no $f"
	done
	ok "colors.toml has the keys Theme.qml reads"
	n="$(as_user omarchy-theme-list | wc -l)"
	[ "$n" -ge 20 ] && ok "omarchy-theme-list: $n themes" || bad "omarchy-theme-list: $n themes"
	# Without the variables as_user sets: a login shell gets them from profile.d.
	n="$(chroot --userspec="$uid:$gid" "$ROOT" /usr/bin/env -i HOME="/home/$USERNAME" PATH=/usr/local/bin:/usr/bin \
		bash -lc omarchy-theme-list 2>/dev/null | wc -l)"
	[ "$n" -ge 20 ] && ok "login shell env (profile.d): omarchy-theme-list works" || bad "login shell env: $n themes"
	for f in environment environment.d/50-omarchy.conf; do
		grep -q '^OMARCHY_PATH=/usr/share/omarchy$' "$ROOT/etc/$f" && ok "/etc/$f sets OMARCHY_PATH" || bad "/etc/$f"
	done
	[ "$(as_user omarchy-theme-current)" != Unknown ] && ok "omarchy-theme-current: $(as_user omarchy-theme-current)" || bad "omarchy-theme-current"
	as_user omarchy theme list >/dev/null 2>&1 && ok "dispatcher: omarchy theme list" || bad "dispatcher: omarchy theme list"
	as_user omarchy-version >/dev/null && ok "omarchy-version: $(as_user omarchy-version)" || bad "omarchy-version"
	# A second theme switch, light this time (as on the phone, minus the shell).
	if as_user OMARCHY_THEME_HEADLESS=1 omarchy-theme-set "Catppuccin Latte" >/dev/null 2>&1 \
		&& grep -q '^mode = "light"' "$ROOT$s/colors.toml"; then ok "theme switch to Catppuccin Latte"; else bad "theme switch"; fi
	as_user OMARCHY_THEME_HEADLESS=1 omarchy-theme-set "$THEME" >/dev/null 2>&1 || bad "theme switch back to $THEME"
	out="$(as_user foot --check-config 2>&1)" && ok "foot --check-config (user foot.ini + theme include)" || bad "foot --check-config: $out"
	# The phone menu: Omarchy's menu file + the phone overlay -> root rows.
	rows="$(as_user python3 -c '
import importlib.machinery, importlib.util, sys
l = importlib.machinery.SourceFileLoader("m", "/usr/share/omarchy-core/bin/omarchy-menu")
s = importlib.util.spec_from_loader("m", l); m = importlib.util.module_from_spec(s); l.exec_module(m)
items = m.load()
missing = [k for k in items if "label" not in items[k]]
if missing: sys.exit("rows without a label (not in Omarchy menu?): " + " ".join(missing))
print(" ".join(v["label"] for k, v in m.children(items, "")))
print(" ".join(v["label"] for k, v in m.children(items, "style")))' 2>&1)" \
		&& ok "menu root: $(echo "$rows" | head -1); style: $(echo "$rows" | tail -1)" || bad "menu: $rows"
	as_user fzf --version >/dev/null && ok "fzf $(as_user fzf --version | cut -d' ' -f1)" || bad "fzf does not run"
	as_user jq --version >/dev/null && ok "$(as_user jq --version)" || bad "jq does not run"
	find "$ROOT/tmp" -mindepth 1 -delete
	grep -qF -- "$MARK" "$ROOT/home/$USERNAME/.config/hypr/hyprland.lua" && ok "hyprland.lua loads omarchy-core.lua" || bad "hyprland.lua hook"
	umount_chroot
	[ "$fail" = 0 ] || die "checks failed"
	log "checks passed"
}

for s in $CORE_STAGES; do "stage_$s"; done
