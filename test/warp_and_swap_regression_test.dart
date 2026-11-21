import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:megabox_server_creator/models/server_config.dart';
import 'package:megabox_server_creator/services/shell_scripts.dart';
import 'package:megabox_server_creator/services/warp_service.dart';
import 'package:megabox_server_creator/services/xui_routing_helper.dart';

String sqlFrom(String command) => utf8.decode(
  base64Decode(
    RegExp("printf '%s' '([A-Za-z0-9+/=]+)'").firstMatch(command)!.group(1)!,
  ),
);

void main() {
  test('WARP cleans sources before prerequisites and replaces key', () {
    final script = WarpService.installScript;
    final steps = [
      'rm -f /etc/apt/sources.list.d/cloudflare*.list',
      'apt-get -o DPkg::Lock::Timeout=120 update',
      '-y install curl gnupg ca-certificates',
      'mkdir -p /usr/share/keyrings',
      'gpg --yes --dearmor -o',
      'chmod 644 /usr/share/keyrings/',
      "printf 'deb [arch=%s signed-by=",
    ].map(script.indexOf).toList();
    expect(steps.first, greaterThan(0));
    for (var i = 1; i < steps.length; i++) {
      expect(steps[i], greaterThan(steps[i - 1]));
    }
    expect(script, contains('curl -fsSL --connect-timeout 15 --max-time 60'));
    expect(script, contains(r'$(dpkg --print-architecture)'));
    expect(script, isNot(contains('--allow-unauthenticated')));
    expect(script, isNot(contains('trusted=yes')));
  });

  test('repository fallback is ordered and guarded from errexit', () {
    final script = WarpService.installScript;
    expect(
      script,
      contains(
        r'for mbx_codename in "${VERSION_CODENAME:-}" jammy bookworm; do',
      ),
    );
    expect(script, contains(r'case "$mbx_warp_tried" in'));
    expect(script, contains('if apt-get -o DPkg::Lock::Timeout=120 update &&'));
    expect(script, contains('-y install cloudflare-warp; then'));
    expect(script, contains('mbx_warp_installed=1\n      break'));
    expect(script, contains(r'if [ "$mbx_warp_installed" -ne 1 ]; then'));
    expect(script, isNot(contains('apt-get update || true')));
  });

  test('WARP ready marker must be an entire output line', () async {
    await WarpService.configure(
      sshPassword: 'password',
      isRoot: false,
      runCommand: (script, password, root) async {
        expect(script, WarpService.installScript);
        expect(password, 'password');
        expect(root, isFalse);
        return 'registration succeeded\nMBX_WARP_READY\r\n';
      },
    );
    await expectLater(
      WarpService.configure(
        sshPassword: '',
        isRoot: true,
        runCommand: (_, _, _) async => 'not MBX_WARP_READY',
      ),
      throwsStateError,
    );
  });

  for (final failure in ['apt exit 100', 'registration blocked', 'not ready']) {
    test('routing falls back to direct after $failure and restarts', () async {
      final warnings = <String>[];
      final commands = <String>[];
      String? stored;
      await XuiRoutingHelper.applyRoutingRules(
        sshPassword: 'secret',
        isRoot: false,
        options: const DeploymentOptions(
          cloudflareWarp: true,
          antiTorrent: true,
          adBlock: true,
          bypassRuDomains: true,
        ),
        onWarning: warnings.add,
        runCommand: (command, password, root) async {
          expect(password, 'secret');
          expect(root, isFalse);
          commands.add(command);
          if (command == WarpService.installScript) {
            if (failure == 'not ready') return 'WARP local proxy is not ready';
            throw StateError(failure);
          }
          if (command.contains('base64 -d')) {
            final sql = sqlFrom(command);
            if (sql.startsWith('SELECT')) return stored!;
            stored = RegExp("VALUES \\('xrayTemplateConfig', '(.*)'\\);")
                .firstMatch(sql)!
                .group(1)!
                .replaceAll("''", "'");
          }
          return '';
        },
      );
      expect(warnings, [WarpService.failureWarning]);
      expect(commands.last, 'systemctl restart x-ui');
      final config = jsonDecode(stored!) as Map<String, dynamic>;
      expect((config['outbounds'] as List).map((o) => o['tag']), [
        'direct',
        'blocked',
      ]);
      expect((config['outbounds'] as List).first['protocol'], 'freedom');
      final rules = config['routing']['rules'] as List;
      expect(rules, hasLength(4));
      expect(rules.any((r) => r['outboundTag'] == 'warp'), isFalse);
      expect(
        rules.any((r) => r['protocol']?.contains('bittorrent') == true),
        isTrue,
      );
      expect(
        rules.any(
          (r) => r['domain']?.contains('geosite:category-ads-all') == true,
        ),
        isTrue,
      );
    });
  }

  test('direct fallback does not swallow database failures', () async {
    final warnings = <String>[];
    var restarted = false;
    await expectLater(
      XuiRoutingHelper.applyRoutingRules(
        sshPassword: '',
        isRoot: true,
        options: const DeploymentOptions(cloudflareWarp: true),
        onWarning: warnings.add,
        runCommand: (command, _, _) async {
          if (command == WarpService.installScript) {
            throw StateError('WARP unavailable');
          }
          if (command == 'systemctl restart x-ui') restarted = true;
          throw StateError('database inaccessible');
        },
      ),
      throwsStateError,
    );
    expect(warnings, [WarpService.failureWarning]);
    expect(restarted, isFalse);
  });

  test('manual routing selects success and direct templates', () {
    final script = XuiRoutingHelper.generateRoutingScript(
      const DeploymentOptions(cloudflareWarp: true, antiTorrent: true),
    );
    final templates = RegExp("MBX_CONFIG='([A-Za-z0-9+/=]+)'")
        .allMatches(script)
        .map(
          (m) =>
              jsonDecode(utf8.decode(base64Decode(m.group(1)!)))
                  as Map<String, dynamic>,
        )
        .toList();
    expect(templates, hasLength(2));
    expect(
      (templates[0]['outbounds'] as List).any((o) => o['tag'] == 'warp'),
      isTrue,
    );
    expect(
      (templates[1]['outbounds'] as List).any((o) => o['tag'] == 'warp'),
      isFalse,
    );
    expect(script, contains('if bash -c '));
    expect(script, contains(WarpService.failureWarning));
    expect(script, contains(r'''printf '%s' "$MBX_CONFIG" | base64 -d'''));
    expect(script, contains('umask 077'));
  });

  test(
    'IPv6 disable script persists through sysctl.d and applies settings',
    () {
      final script = ShellScripts.disableIpv6;
      expect(script, contains('/etc/sysctl.d/99-disable-ipv6.conf'));
      expect(script, contains('net.ipv6.conf.all.disable_ipv6 = 1'));
      expect(script, contains('net.ipv6.conf.default.disable_ipv6 = 1'));
      expect(script, contains('net.ipv6.conf.lo.disable_ipv6 = 1'));
      expect(script, contains('sysctl -p /etc/sysctl.d/99-disable-ipv6.conf'));
      // Настройка должна переживать перезагрузку и cloud-init.
      expect(script, isNot(contains('/etc/sysctl.conf')));
      expect(script, isNot(contains('sysctl --system')));
    },
  );

  test('swap guards precede allocation and destructive operations', () {
    final script = ShellScripts.setupSwap;
    final guards = RegExp('if mbx_swap_active; then')
        .allMatches(script)
        .toList();
    expect(guards, hasLength(2));
    expect(
      script,
      contains(r'mbx_swap_names=$(swapon --show=NAME --noheadings) || {'),
    );
    expect(script, contains('refusing to format /swapfile'));
    expect(
      script,
      contains(
        r'''printf '%s\n' "$mbx_swap_names" | grep -Fxq '/swapfile' '''.trim(),
      ),
    );
    expect(guards.first.start, lessThan(script.indexOf('fallocate')));
    for (final guard in guards) {
      final end = script.indexOf('\nfi', guard.start);
      expect(script.substring(guard.start, end), contains('exit 0'));
      expect(end, lessThan(script.indexOf('chmod 600 /swapfile')));
    }
    expect(script.indexOf('chmod 600'), lessThan(script.indexOf('mkswap')));
    expect(
      script.indexOf('mkswap'),
      lessThan(script.indexOf('swapon /swapfile')),
    );
    expect(script, isNot(contains('swapon /swapfile || true')));
    expect(script, contains("grep -Eq '^[[:space:]]*/swapfile[[:space:]]'"));
  });

  test('deployment uses swap generator and warning-level WARP logging', () {
    final source = File(
      '${Directory.current.path}/lib/services/ssh_service.dart',
    ).readAsStringSync();
    expect(source, contains('ShellScripts.setupSwap'));
    expect(source, contains('ShellScripts.disableIpv6'));
    expect(source, isNot(contains('mkswap /swapfile')));
    final routing = source.substring(
      source.indexOf('await XuiRoutingHelper.applyRoutingRules('),
    );
    expect(
      routing.substring(0, routing.indexOf(');') + 2),
      contains('DeploymentLogType.warning'),
    );
  });
}
