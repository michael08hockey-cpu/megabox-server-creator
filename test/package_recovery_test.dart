import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:megabox_server_creator/services/shell_scripts.dart';
import 'package:megabox_server_creator/services/warp_service.dart';

void main() {
  test('sqlite already-present branch exits before any package operations', () {
    final script = ShellScripts.installSqlite;
    final guard = script.indexOf('if command -v sqlite3 >/dev/null 2>&1; then');
    final success = script.indexOf('exit 0', guard);
    final guardEnd = script.indexOf('\nfi', success);
    final recovery = script.indexOf(ShellScripts.aptUnlock);
    expect(guard, greaterThanOrEqualTo(0));
    expect(success, greaterThan(guard));
    expect(guardEnd, lessThan(recovery));
    final fastPath = script.substring(0, guardEnd);
    for (final operation in [
      'pgrep',
      'killall',
      'systemctl',
      'rm -f',
      'dpkg --',
      'apt-get',
    ]) {
      expect(fastPath, isNot(contains(operation)));
    }
  });

  test('timeout forces recovery rather than explicitly exiting', () {
    final script = ShellScripts.aptUnlock;
    expect(script, contains(r'while [ "$mbx_apt_waited" -lt 30 ]'));
    expect(script, contains('sleep 4'));
    expect(script, contains('if mbx_apt_busy; then'));
    expect(script, isNot(contains('exit 1')));
    final stop = script.indexOf(
      'systemctl stop apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service',
    );
    final kill = script.indexOf('killall -9 apt apt-get dpkg unattended-upgr');
    final remove = script.indexOf('rm -f /var/lib/dpkg/lock');
    final repair = script.indexOf(
      'dpkg --force-confdef --force-confold --configure -a',
    );
    expect(stop, greaterThanOrEqualTo(0));
    expect(stop, lessThan(kill));
    expect(kill, lessThan(remove));
    expect(remove, lessThan(repair));
    expect(script, contains('/var/lib/dpkg/lock-frontend'));
    expect(script, contains('/var/lib/apt/lists/lock'));
    expect(script, contains('/var/cache/apt/archives/lock'));
    expect(script, contains("pkill -9 -x 'apt|apt-get|dpkg|unattended-upgr'"));
  });

  test('lock removal requires no surviving package processes', () {
    final script = ShellScripts.aptUnlock;
    final check = script.indexOf('if ! mbx_apt_busy; then');
    final remove = script.indexOf('rm -f /var/lib/dpkg/lock');
    final alternative = script.indexOf('\nelse', check);
    expect(check, lessThan(remove));
    expect(remove, lessThan(alternative));
    expect(script, contains('survived SIGKILL'));
  });

  test('bash variables and arithmetic are not overescaped', () {
    final script = ShellScripts.aptUnlock;
    expect(script, contains(r'mbx_apt_waited=$((mbx_apt_waited + 1))'));
    expect(script, isNot(contains(r'\$')));
    final install = ShellScripts.aptInstall(['curl', 'ca-certificates']);
    expect(install, contains(script));
    expect(install, isNot(contains(r'$aptUnlock')));
    expect(install, contains('-y install curl ca-certificates'));
    expect(
      () => ShellScripts.aptInstall(['curl; touch /tmp/injected']),
      throwsArgumentError,
    );
    expect(() => ShellScripts.aptInstall([]), throwsArgumentError);
  });

  test('WARP recovery is inside missing-client branch before apt', () {
    final script = WarpService.installScript;
    final guard = script.indexOf('if ! command -v warp-cli');
    final recovery = script.indexOf(ShellScripts.aptUnlock);
    final install = script.indexOf(
      'apt-get -o DPkg::Lock::Timeout=120 -y install curl',
    );
    expect(guard, lessThan(recovery));
    expect(recovery, lessThan(install));
  });

  test('3X-UI and Caddy generators both embed shared package recovery', () {
    final path = File(
      '${Directory.current.path}${Platform.pathSeparator}lib${Platform.pathSeparator}services${Platform.pathSeparator}ssh_service.dart',
    ).absolute;
    final source = path.readAsStringSync();
    final installer = source.substring(
      source.indexOf('Future<void> _installXui'),
      source.indexOf('Future<Map<String, String>> _generateRealityKeys'),
    );
    expect(installer, contains(r'${ShellScripts.aptUnlock}'));
    final caddy = source.substring(
      source.indexOf('final installCaddy'),
      source.indexOf('final caddyCheck'),
    );
    expect(
      caddy.indexOf('if ! command -v caddy'),
      lessThan(caddy.indexOf(r'${ShellScripts.aptUnlock}')),
    );
    expect(
      caddy.indexOf(r'${ShellScripts.aptUnlock}'),
      lessThan(caddy.indexOf('apt-get install')),
    );
  });
}
