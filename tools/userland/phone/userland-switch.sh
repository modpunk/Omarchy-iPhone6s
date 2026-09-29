# Sourced by the patched HoolockLinux /init (PID 1, busybox sh) once
# /run/userland-go exists (stage2.sh go creates it). Not executable on purpose.
# On any failed precondition it logs and returns, and init keeps idling, so a
# bad rootfs never kills PID 1 (that would panic the phone).
rm -f /run/userland-go
_nr="$(cat /run/userland-newroot 2>/dev/null)"; _nr="${_nr:-/newroot}"
_ni=/usr/lib/systemd/systemd
if [ "$$" != 1 ]; then
	echo "[userland] not PID 1, refusing" > /dev/kmsg
elif ! mountpoint -q "$_nr" || [ ! -x "$_nr$_ni" ] || [ ! -e "$_nr/etc/omarchy-phone-release" ]; then
	echo "[userland] $_nr is not a complete userland, not switching" > /dev/kmsg
else
	echo "[userland] switch_root to $_nr ($(cat "$_nr/etc/omarchy-phone-release"))" > /dev/kmsg
	# Leave the tee/logger pipeline from setup_log before killing it.
	# (exec is a special builtin: a failed redirect would exit PID 1, so check first.)
	[ -e /dev/console ] && exec </dev/console >/dev/console 2>&1
	echo ratelimit > /proc/sys/kernel/printk_devkmsg
	[ -e /proc/sys/kernel/hotplug ] && echo > /proc/sys/kernel/hotplug  # no mdev in the new root
	kill -TERM -1 2>/dev/null; sleep 2; kill -KILL -1 2>/dev/null; sleep 1
	# The gadget stays bound in the kernel; systemd remounts configfs itself.
	umount /config 2>/dev/null
	for _d in dev proc sys run; do
		mkdir -p "$_nr/$_d"
		mount --move "/$_d" "$_nr/$_d" 2>/dev/null || mount -o move "/$_d" "$_nr/$_d"
	done
	exec switch_root "$_nr" "$_ni"
fi
