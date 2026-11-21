import 'dart:convert';

/// Pure generators shared by SSH services. Data never becomes shell syntax.
class ShellScripts {
  static String quote(String value) {
    if (value.contains('\x00')) {
      throw ArgumentError('Shell arguments cannot contain NUL');
    }
    return "'${value.replaceAll("'", "'\\''")}'";
  }

  static String transport(String script, {String? sudoPassword}) {
    final encoded = base64Encode(utf8.encode(script));
    final invocation = sudoPassword == null
        ? 'bash "\$mbx_script"'
        : "printf '%s\\n' ${quote(sudoPassword)} | sudo -S -p '' bash \"\$mbx_script\"";
    return '''
umask 077
mbx_script=\$(mktemp /tmp/mbx_cmd.XXXXXXXXXX) || exit 1
trap 'rm -f "\$mbx_script"' EXIT HUP INT TERM
printf '%s' '$encoded' | base64 -d > "\$mbx_script" || exit 1
bash -n "\$mbx_script" || exit 2
$invocation
mbx_rc=\$?
exit "\$mbx_rc"
''';
  }

  static String sql(String sql, {String dbPath = '/etc/x-ui/x-ui.db'}) {
    final encoded = base64Encode(utf8.encode(sql));
    return '''
set -e
set -o pipefail
printf '%s' '$encoded' | base64 -d | /usr/bin/sqlite3 -bail ${quote(dbPath)}
''';
  }

  /// Waits for a running package manager, then forcibly clears stale locks.
  ///
  /// Forced recovery can interrupt a legitimate update and requires root.
  /// It is attempted only after bounded waiting. Lock files are removed only
  /// when no matching package process remains after SIGKILL; processes stuck
  /// in uninterruptible I/O cannot be recovered safely this way.
  static const aptUnlock = r'''
export DEBIAN_FRONTEND=noninteractive
export PATH=/usr/sbin:/usr/bin:/sbin:/bin:$PATH
mbx_apt_busy() {
  pgrep -x 'apt|apt-get|dpkg|unattended-upgr' >/dev/null 2>&1
}
mbx_apt_waited=0
while [ "$mbx_apt_waited" -lt 30 ]; do
  if mbx_apt_busy; then
    sleep 4
    mbx_apt_waited=$((mbx_apt_waited + 1))
  else
    break
  fi
done
if mbx_apt_busy; then
  echo 'Package manager still busy; forcing recovery' >&2
  systemctl stop apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service >/dev/null 2>&1 || true
  killall -9 apt apt-get dpkg unattended-upgr >/dev/null 2>&1 || true
  pkill -9 -x 'apt|apt-get|dpkg|unattended-upgr' >/dev/null 2>&1 || true
  sleep 2
fi
# If a process survived SIGKILL (e.g. uninterruptible I/O), keep its locks.
if ! mbx_apt_busy; then
  rm -f /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock
else
  echo 'Package process survived SIGKILL; leaving its lock files intact' >&2
fi
dpkg --force-confdef --force-confold --configure -a
''';

  /// Installs Debian packages, clearing package manager locks first.
  ///
  /// Package names are validated so they can never become shell syntax.
  static String aptInstall(List<String> packages, {bool update = true}) {
    if (packages.isEmpty) throw ArgumentError.value(packages, 'packages');
    final names = packages.map((package) {
      if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9+._-]*$').hasMatch(package)) {
        throw ArgumentError.value(package, 'packages', 'Invalid package name');
      }
      return package;
    }).toList();
    final updateStep = update
        ? 'apt-get update -qq || apt-get update || true\n'
        : '';
    return '''
set -e
$aptUnlock
$updateStep
apt-get -o DPkg::Lock::Timeout=120 -y install ${names.join(' ')}
''';
  }

  /// Installs the sqlite3 CLI required to read and write the 3X-UI database.
  ///
  /// If the binary is already present the step succeeds immediately without
  /// touching apt, dpkg or any lock file. Only a missing package goes through
  /// the package manager, and a busy package manager is recovered from rather
  /// than aborting the deployment.
  static String get installSqlite {
    return r'''
set -e
export DEBIAN_FRONTEND=noninteractive
export PATH=/usr/sbin:/usr/bin:/sbin:/bin:$PATH
if command -v sqlite3 >/dev/null 2>&1; then
  echo 'MBX_SQLITE_ALREADY_PRESENT'
  exit 0
fi
''' +
        aptUnlock +
        r'''
apt-get -o DPkg::Lock::Timeout=120 -f install -y >/dev/null 2>&1 || true
apt-get update -qq || apt-get update || true
apt-get -o DPkg::Lock::Timeout=120 -y install sqlite3
sqlite3 --version
''';
  }

  /// Destructive, best-effort cleanup for an explicitly requested reinstall.
  /// Must run as root, before dependencies or panel installation.
  static String generateCleanInstallScript() => r'''
export PATH=/usr/sbin:/usr/bin:/sbin:/bin:$PATH
if [ "$(id -u)" -ne 0 ]; then
  echo 'Clean installation requires root privileges' >&2
  exit 1
fi
# Reject a conflicting SSH listener even when invoked outside the Dart service.
if [ -n "${SSH_CONNECTION:-}" ]; then
  mbx_ssh_port=${SSH_CONNECTION##* }
  case "$mbx_ssh_port" in
    443|8443|2053) echo 'Refusing to kill the active SSH listener' >&2; exit 1 ;;
  esac
fi
mbx_cleanup_warning() {
  echo "MBX_CLEANUP_WARNING: $*" >&2
}
# Remove only MegaBox watchdog cron entries, preserving unrelated jobs.
if command -v crontab >/dev/null 2>&1; then
  mbx_cron=$(crontab -l 2>/dev/null) && {
    mbx_filtered=$(printf '%s\n' "$mbx_cron" | sed '\|/usr/local/bin/mbx-watchdog.sh|d')
    printf '%s\n' "$mbx_filtered" | crontab - || mbx_cleanup_warning 'Unable to update watchdog crontab'
  }
fi
pkill -9 -f '^(/bin/|/usr/bin/)?bash /usr/local/bin/mbx-watchdog\.sh($| )' 2>/dev/null || true
rm -f -- /usr/local/bin/mbx-watchdog.sh /var/run/mbx-watchdog.lock /etc/cron.d/mbx-watchdog || mbx_cleanup_warning 'Unable to remove watchdog files'
# Stop systemd units before killing listeners, so they cannot restart them.
systemctl stop x-ui xray 2>/dev/null || true
systemctl disable x-ui xray 2>/dev/null || true
if command -v fuser >/dev/null 2>&1; then
  fuser -k -KILL 443/tcp 8443/tcp 2053/tcp 2>/dev/null || true
elif command -v ss >/dev/null 2>&1; then
  # fuser is often absent on a fresh VPS. Extract only listening TCP PIDs.
  mbx_pids=$(ss -tlnpH 2>/dev/null | awk '$4 ~ /:(443|8443|2053)$/ {print}' | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u)
  for mbx_pid in $mbx_pids; do
    kill -9 "$mbx_pid" 2>/dev/null || true
  done
fi
# Also terminate stray panel/core processes even if no socket was open yet.
killall -9 xray x-ui 2>/dev/null || true
pkill -9 -x 'xray-linux.*' 2>/dev/null || true
rm -rf -- /etc/x-ui /usr/local/x-ui || mbx_cleanup_warning 'Unable to remove panel directories'
rm -f -- /etc/systemd/system/x-ui.service /etc/systemd/system/xray.service || mbx_cleanup_warning 'Unable to remove service files'
systemctl daemon-reload 2>/dev/null || true

if command -v warp-cli >/dev/null 2>&1; then
  timeout 15 warp-cli --accept-tos disconnect 2>/dev/null || timeout 15 warp-cli disconnect 2>/dev/null || true
  timeout 15 warp-cli --accept-tos registration delete 2>/dev/null || timeout 15 warp-cli delete-registration 2>/dev/null || true
fi
systemctl stop warp-svc 2>/dev/null || true
systemctl disable warp-svc 2>/dev/null || true
if command -v apt-get >/dev/null 2>&1; then
  DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 purge -y cloudflare-warp || mbx_cleanup_warning 'Unable to purge cloudflare-warp; continuing cleanup'
fi
rm -rf -- /etc/apt/sources.list.d/cloudflare* /usr/share/keyrings/cloudflare* /var/lib/cloudflare-warp || mbx_cleanup_warning 'Unable to remove WARP state'

# The SSH transport executes this very script from /tmp/mbx_cmd.*.
# Keep it until the transport's EXIT trap removes it.
mbx_cleanup_self=${BASH_SOURCE[0]}
for mbx_old in /tmp/xui* /tmp/mbx* /tmp/xray*; do
  [ "$mbx_old" = "$mbx_cleanup_self" ] && continue
  [ -e "$mbx_old" ] || [ -L "$mbx_old" ] || continue
  rm -rf -- "$mbx_old" || mbx_cleanup_warning "Unable to remove $mbx_old"
done
echo MBX_CLEANUP_DONE
exit 0
''';

  /// Persist IPv4-only networking across reboots without rewriting sysctl.conf.
  /// Apply only our file to avoid unrelated distribution sysctl errors.
  static const disableIpv6 = r'''
set -e
export PATH=/usr/sbin:/usr/bin:/sbin:/bin:$PATH
mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/99-disable-ipv6.conf <<'MBX_IPV6_EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
MBX_IPV6_EOF
chmod 644 /etc/sysctl.d/99-disable-ipv6.conf
sysctl -p /etc/sysctl.d/99-disable-ipv6.conf
''';

  /// Idempotent swap setup: never format an active swap file.
  static const setupSwap = r'''
set -e
mbx_swap_active() {
  mbx_swap_names=$(swapon --show=NAME --noheadings) || {
    echo 'Cannot check active swap; refusing to format /swapfile' >&2
    exit 1
  }
  printf '%s\n' "$mbx_swap_names" | grep -Fxq '/swapfile'
}
if mbx_swap_active; then
  echo MBX_SWAP_ALREADY_ACTIVE
  exit 0
fi
if [ ! -f /swapfile ]; then
  fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
fi
# Recheck after allocation, before touching an existing file.
if mbx_swap_active; then
  echo MBX_SWAP_ALREADY_ACTIVE
  exit 0
fi
chmod 600 /swapfile
mkswap /swapfile >/dev/null
swapon /swapfile
grep -Eq '^[[:space:]]*/swapfile[[:space:]]' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
echo MBX_SWAP_READY
''';

  /// Wait for Xray itself (not Caddy or another listener) on all actual ports.
  static String waitForXrayPorts(List<int> ports) {
    if (ports.isEmpty || ports.any((p) => p < 1 || p > 65535)) {
      throw ArgumentError.value(ports, 'ports');
    }
    return r'''
set -e
mbx_xray_attempt=1
while [ "$mbx_xray_attempt" -le 10 ]; do
  mbx_listeners=$(ss -tlnpH) || exit 1
  mbx_all_ready=1
  for mbx_port in MBX_PORTS; do
    if printf '%s\n' "$mbx_listeners" | awk -v port="$mbx_port" '
      $4 ~ (":" port "$") && tolower($0) ~ /users:\(\("xray[^"]*"/ {found=1}
      END {exit !found}'; then
      :
    else
      mbx_all_ready=0
    fi
  done
  if [ "$mbx_all_ready" -eq 1 ]; then
    break
  fi
  if [ "$mbx_xray_attempt" -lt 10 ]; then sleep 1; fi
  mbx_xray_attempt=$((mbx_xray_attempt + 1))
done
# Report each port from the final snapshot, including partial readiness.
for mbx_port in MBX_PORTS; do
  if printf '%s\n' "$mbx_listeners" | awk -v port="$mbx_port" '
    $4 ~ (":" port "$") && tolower($0) ~ /users:\(\("xray[^"]*"/ {found=1}
    END {exit !found}'; then
    echo "MBX_XRAY_LISTENING:$mbx_port"
  fi
done
'''
        .replaceAll('MBX_PORTS', ports.toSet().join(' '));
  }

  static String portProbe(int port) {
    if (port < 1 || port > 65535) throw ArgumentError.value(port, 'port');
    return '''
if (
  MBX_PORT=$port
  if command -v ss >/dev/null 2>&1; then
    ss -tln | grep -q ":\$MBX_PORT "
  elif command -v netstat >/dev/null 2>&1; then
    netstat -tln | grep -q ":\$MBX_PORT "
  else
    curl -s -o /dev/null -m 2 "http://127.0.0.1:\$MBX_PORT/"
  fi
); then
  echo MBX_PORT_OPEN
else
  echo MBX_PORT_CLOSED
fi
''';
  }
}
