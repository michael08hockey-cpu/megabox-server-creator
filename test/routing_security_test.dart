import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:megabox_server_creator/services/shell_scripts.dart';
import 'package:megabox_server_creator/services/warp_service.dart';
import 'package:megabox_server_creator/services/xui_routing_helper.dart';
import 'package:megabox_server_creator/models/server_config.dart';

String decodeSql(String command) {
  final match = RegExp("printf '%s' '([A-Za-z0-9+/=]+)'").firstMatch(command)!;
  return utf8.decode(base64Decode(match.group(1)!));
}

void main() {
  test(
    'manual template readfile expands only the generated temporary path',
    () {
      final script = XuiRoutingHelper.generateRoutingScript(
        const DeploymentOptions(),
      );
      expect(script, contains('<<MBX_SQL_EOF'));
      expect(script, isNot(contains("<<'MBX_SQL_EOF'")));
      expect(script, contains(r"CAST(readfile('$MBX_TPL') AS TEXT)"));
      final match = RegExp("MBX_CONFIG='([A-Za-z0-9+/=]+)'")
          .firstMatch(script)!;
      final json = utf8.decode(base64Decode(match.group(1)!));
      final config = jsonDecode(json) as Map<String, dynamic>;
      expect(config['outbounds'], isA<List>());
      expect(config['routing'], isA<Map>());
    },
  );
  test('transport preserves hostile script contents through base64', () {
    const source = 'echo "outbounds"\nEOFSCRIPT\n\$(touch /tmp/injected)';
    final command = ShellScripts.transport(source, sudoPassword: "O'Brien");
    expect(decodeSql(command), source);
    expect(command, contains('mktemp /tmp/mbx_cmd.XXXXXXXXXX'));
    expect(command, contains('umask 077'));
    expect(command, contains('bash -n'));
    expect(command, contains("'O'\\''Brien'"));
    expect(command, isNot(contains('touch /tmp/injected')));
  });
  test('SQL codec preserves JSON, quotes, unicode and dollar signs', () {
    const sql =
        '''INSERT INTO settings VALUES ('key', '{"outboundTag":"warp","name":"O''Brien ☃ \$HOME"}');''';
    final command = ShellScripts.sql(sql);
    expect(decodeSql(command), sql);
    expect(command, contains('/usr/bin/sqlite3 -bail'));
    expect(command, contains('set -o pipefail'));
  });
  test('port probe has a compound condition, never a leading &&', () {
    final script = ShellScripts.portProbe(2053);
    expect(script, contains('MBX_PORT=2053'));
    expect(script, contains(r':$MBX_PORT '));
    expect(RegExp(r'^\s*&&', multiLine: true).hasMatch(script), isFalse);
    expect(() => ShellScripts.portProbe(0), throwsArgumentError);
    expect(() => ShellScripts.portProbe(65536), throwsArgumentError);
  });
  test('package repair precedes install and recovers after busy timeout', () {
    final script = ShellScripts.installSqlite;
    expect(
      script.indexOf('--configure -a'),
      lessThan(script.indexOf('-y install sqlite3')),
    );
    expect(script, contains('killall -9 apt apt-get dpkg unattended-upgr'));
    expect(script, contains('rm -f /var/lib/dpkg/lock'));
    expect(script, contains('DPkg::Lock::Timeout=120'));
    expect(script, isNot(contains('refusing to remove active locks')));
  });
  test(
    'WARP uses supported client, localhost SOCKS and no fake registration API',
    () {
      expect(WarpService.installScript, contains('registration new'));
      expect(WarpService.installScript, contains('mode proxy'));
      expect(WarpService.installScript, isNot(contains('/warp_reg')));
      expect(WarpService.installScript, isNot(contains('yes |')));
      expect(WarpService.outbound()['protocol'], 'socks');
    },
  );
  test('WARP failure is not silently accepted', () async {
    await expectLater(
      WarpService.configure(
        sshPassword: '',
        isRoot: true,
        runCommand: (_, _, _) async => 'HTTP 404',
      ),
      throwsStateError,
    );
  });
  for (final warp in [false, true]) {
    test('routing write, exact readback and restart (WARP=$warp)', () async {
      final sent = <String>[];
      String? stored;
      await XuiRoutingHelper.applyRoutingRules(
        sshPassword: 'secret',
        isRoot: false,
        options: DeploymentOptions(cloudflareWarp: warp, antiTorrent: true),
        runCommand: (command, password, root) async {
          expect(password, 'secret');
          expect(root, isFalse);
          sent.add(command);
          if (command == WarpService.installScript) return 'MBX_WARP_READY\n';
          if (command.contains('base64 -d')) {
            final sql = decodeSql(command);
            if (sql.contains('INSERT INTO settings')) {
              expect(
                sql,
                contains(
                  "DELETE FROM settings WHERE key = 'xrayTemplateConfig';",
                ),
              );
              final match = RegExp("VALUES \\('xrayTemplateConfig', '(.*)'\\);")
                  .firstMatch(sql)!;
              stored = match.group(1)!.replaceAll("''", "'");
              final config = jsonDecode(stored!) as Map<String, dynamic>;
              final outbound = config['outbounds'] as List;
              expect(outbound.any((o) => o['tag'] == 'warp'), warp);
              expect(stored, isNot(contains('__WARP_SECRET_KEY__')));
              return '';
            }
            return '$stored\n';
          }
          return '';
        },
      );
      expect(sent.last, 'systemctl restart x-ui');
      if (warp) expect(sent.first, WarpService.installScript);
    });
  }
  test(
    'corrupt full readback prevents restart even with valid prefix',
    () async {
      var restarted = false;
      await expectLater(
        XuiRoutingHelper.applyRoutingRules(
          sshPassword: '',
          isRoot: true,
          options: DeploymentOptions(),
          runCommand: (command, _, _) async {
            if (command == 'systemctl restart x-ui') restarted = true;
            if (command.contains('base64 -d') &&
                decodeSql(command).startsWith('SELECT')) {
              return '{"outbounds": [broken';
            }
            return '';
          },
        ),
        throwsException,
      );
      expect(restarted, isFalse);
    },
  );
  test(
    'manual script interpolates Dart flags and never stores a WARP placeholder',
    () {
      final script = XuiRoutingHelper.generateRoutingScript(
        DeploymentOptions(cloudflareWarp: true),
      );
      expect(script, isNot(contains(r'${options.')));
      expect(script, isNot(contains('__WARP_SECRET_KEY__')));
      expect(script, contains('set -e'));
      expect(script, contains('/usr/bin/sqlite3 -bail'));
    },
  );
}
