import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:megabox_server_creator/models/server_config.dart';
import 'package:megabox_server_creator/models/deployment_log.dart';
import 'package:megabox_server_creator/services/shell_scripts.dart';
import 'package:megabox_server_creator/services/ssh_service.dart';

ServerConfig config({bool clean = true, String user = 'root', int port = 22}) =>
    ServerConfig(
      ipAddress: '192.0.2.1',
      sshPort: port,
      sshUser: user,
      sshPassword: 'password',
      location: ServerLocation.germany,
      vlessPort: 443,
      remark: 'test',
      options: DeploymentOptions(cleanReinstall: clean),
    );

void main() {
  test(
    'cleanup handles inactive panels and stops units before killing ports',
    () {
      final script = ShellScripts.generateCleanInstallScript();
      expect(script, isNot(contains('systemctl is-active x-ui')));
      expect(script, contains('systemctl stop x-ui xray 2>/dev/null || true'));
      expect(
        script,
        contains('systemctl disable x-ui xray 2>/dev/null || true'),
      );
      final kill = script.indexOf('fuser -k -KILL 443/tcp 8443/tcp 2053/tcp');
      expect(script.indexOf('systemctl stop x-ui'), lessThan(kill));
      expect(script.indexOf('systemctl disable x-ui'), lessThan(kill));
      expect(script, contains('killall -9 xray x-ui 2>/dev/null || true'));
      expect(script, contains('ss -tlnpH'));
      expect(script, contains(r'$4 ~ /:(443|8443|2053)$/'));
      expect(script, contains('rm -rf -- /etc/x-ui /usr/local/x-ui'));
      expect(script, contains('/etc/systemd/system/x-ui.service'));
      expect(script, contains('systemctl daemon-reload'));
    },
  );

  test('WARP reset supports modern/legacy CLI and purges state after stop', () {
    final script = ShellScripts.generateCleanInstallScript();
    expect(script, contains('if command -v warp-cli'));
    expect(script, contains('timeout 15 warp-cli --accept-tos disconnect'));
    expect(
      script,
      contains('timeout 15 warp-cli --accept-tos registration delete'),
    );
    expect(script, contains('timeout 15 warp-cli delete-registration'));
    expect(
      script.indexOf('systemctl stop warp-svc'),
      lessThan(script.indexOf('purge -y cloudflare-warp')),
    );
    expect(script, contains('DPkg::Lock::Timeout=120'));
    expect(script, contains('/etc/apt/sources.list.d/cloudflare*'));
    expect(
      script,
      contains('/usr/share/keyrings/cloudflare* /var/lib/cloudflare-warp'),
    );
    expect(script, isNot(contains('apt-get update')));
    expect(script, isNot(contains('apt-get install')));
  });

  test('watchdog cleanup preserves unrelated cron and swap', () {
    final script = ShellScripts.generateCleanInstallScript();
    expect(
      script.indexOf('crontab -l'),
      lessThan(script.indexOf('systemctl stop x-ui')),
    );
    expect(script, contains(r"sed '\|/usr/local/bin/mbx-watchdog.sh|d'"));
    expect(
      script,
      contains('/usr/local/bin/mbx-watchdog.sh /var/run/mbx-watchdog.lock'),
    );
    expect(script, contains('/etc/cron.d/mbx-watchdog'));
    expect(script, isNot(contains('crontab -r')));
    expect(script, isNot(contains('rm -rf /etc/cron')));
    expect(script, isNot(contains('/swapfile')));
    expect(script.trim(), endsWith('exit 0'));
    expect(script, isNot(contains('set -e')));
  });

  test(
    'temporary cleanup preserves transported script and shell variables',
    () {
      final script = ShellScripts.generateCleanInstallScript();
      expect(script, contains(r'mbx_cleanup_self=${BASH_SOURCE[0]}'));
      expect(
        script,
        contains('for mbx_old in /tmp/xui* /tmp/mbx* /tmp/xray*; do'),
      );
      expect(
        script,
        contains(r'[ "$mbx_old" = "$mbx_cleanup_self" ] && continue'),
      );
      expect(script, contains(r'rm -rf -- "$mbx_old"'));
      expect(script, isNot(contains(r'\$')));
      final transported = ShellScripts.transport(
        script,
        sudoPassword: 'password',
      );
      final encoded = RegExp("printf '%s' '([A-Za-z0-9+/=]+)'")
          .firstMatch(transported)!
          .group(1)!;
      expect(utf8.decode(base64Decode(encoded)), script);
    },
  );

  for (final user in ['root', 'ubuntu']) {
    test('cleanup runs once with correct root/sudo mode ($user)', () async {
      var calls = 0;
      final logs = <DeploymentLogType>[];
      await SSHService.runPreDeploymentCleanup(
        config: config(user: user),
        runCommand: (script, password, root) async {
          calls++;
          expect(script, ShellScripts.generateCleanInstallScript());
          expect(password, 'password');
          expect(root, user == 'root');
          return 'MBX_CLEANUP_DONE\r\n';
        },
        onLog: (_, type) => logs.add(type),
      );
      expect(calls, 1);
      expect(logs, [DeploymentLogType.info, DeploymentLogType.success]);
    });
  }

  test('disabled cleanup performs no commands or logs', () async {
    await SSHService.runPreDeploymentCleanup(
      config: config(clean: false),
      runCommand: (_, _, _) async => fail('unexpected command'),
      onLog: (_, _) => fail('unexpected log'),
    );
  });

  test(
    'conflicting SSH ports are rejected before destructive commands',
    () async {
      for (final port in [443, 8443, 2053]) {
        await expectLater(
          SSHService.runPreDeploymentCleanup(
            config: config(port: port),
            runCommand: (_, _, _) async => fail('SSH must be preserved'),
            onLog: (_, _) {},
          ),
          throwsStateError,
        );
      }
      expect(
        ShellScripts.generateCleanInstallScript(),
        contains(r'mbx_ssh_port=${SSH_CONNECTION##* }'),
      );
    },
  );

  test('warnings are logged but completed cleanup continues', () async {
    final logs = <DeploymentLogType>[];
    await SSHService.runPreDeploymentCleanup(
      config: config(),
      runCommand: (_, _, _) async =>
          'MBX_CLEANUP_WARNING: purge failed\nMBX_CLEANUP_DONE\n',
      onLog: (_, type) => logs.add(type),
    );
    expect(logs, [
      DeploymentLogType.info,
      DeploymentLogType.warning,
      DeploymentLogType.success,
    ]);
  });

  test(
    'failed transport or missing completion marker cannot report success',
    () async {
      for (final throws in [false, true]) {
        await expectLater(
          SSHService.runPreDeploymentCleanup(
            config: config(),
            runCommand: (_, _, _) async {
              if (throws) throw StateError('SSH failed');
              return 'not MBX_CLEANUP_DONE';
            },
            onLog: (_, type) => expect(type, isNot(DeploymentLogType.success)),
          ),
          throwsStateError,
        );
      }
    },
  );

  test('deployment cleanup precedes sqlite swap and panel installation', () {
    final source = File(
      '${Directory.current.path}/lib/services/ssh_service.dart',
    ).readAsStringSync();
    final deploy = source.substring(
      source.indexOf('Future<DeploymentResult> deployServer'),
      source.indexOf('Future<Map<String, dynamic>> _createFriendKeys'),
    );
    final cleanup = deploy.indexOf('await runPreDeploymentCleanup(');
    expect(cleanup, greaterThan(deploy.indexOf('await _connectSSH')));
    expect(cleanup, lessThan(deploy.indexOf('ShellScripts.installSqlite')));
    expect(cleanup, lessThan(deploy.indexOf('await _setupSwapIfNeeded')));
    expect(cleanup, lessThan(deploy.indexOf('await _installXui')));
    expect(source, isNot(contains('_removeOldXui')));
  });
}
