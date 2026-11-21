import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:megabox_server_creator/models/server_config.dart';
import 'package:megabox_server_creator/services/warp_service.dart';
import 'package:megabox_server_creator/services/xui_routing_helper.dart';

const expectedAiDomains = [
  'geosite:google',
  'domain:gemini.google.com',
  'domain:bard.google.com',
  'domain:proactivebackend-pa.googleapis.com',
  'domain:alkalimakersuite-pa.googleapis.com',
  'domain:ai.google.dev',
  'domain:generativelanguage.googleapis.com',
  'geosite:openai',
];

void verifyTemplate(Map<String, dynamic> template, {required bool warp}) {
  expect(template['dns'], {
    'servers': ['8.8.8.8', '1.1.1.1'],
    'queryStrategy': 'UseIPv4',
  });
  final rules = template['routing']['rules'] as List;
  expect(rules.first['domain'], expectedAiDomains);
  expect(rules.first['outboundTag'], warp ? 'warp' : 'direct');
  final outbounds = template['outbounds'] as List;
  expect(outbounds.first['tag'], 'direct');
  expect(outbounds.first['settings']['domainStrategy'], 'UseIPv4');
  final tags = outbounds.map((o) => o['tag']).toSet();
  for (final rule in rules) {
    expect(tags, contains(rule['outboundTag']));
  }
  expect(tags.contains('warp'), warp);
  if (warp) {
    expect(outbounds.singleWhere((o) => o['tag'] == 'warp'), {
      'tag': 'warp',
      'protocol': 'socks',
      'settings': {
        'servers': [
          {'address': '127.0.0.1', 'port': 40000},
        ],
      },
    });
  }
}

void main() {
  for (final state in ['disabled', 'ready', 'failed']) {
    test('persisted AI/DNS template with WARP $state', () async {
      String? stored;
      var warpCalled = false;
      final warnings = <String>[];
      await XuiRoutingHelper.applyRoutingRules(
        sshPassword: '',
        isRoot: true,
        options: DeploymentOptions(
          cloudflareWarp: state != 'disabled',
          antiTorrent: true,
          adBlock: true,
          bypassRuDomains: true,
        ),
        onWarning: warnings.add,
        runCommand: (command, _, _) async {
          if (command == WarpService.installScript) {
            warpCalled = true;
            if (state == 'failed') throw StateError('registration rejected');
            return 'MBX_WARP_READY\n';
          }
          if (command.contains('base64 -d')) {
            final encoded = RegExp("printf '%s' '([A-Za-z0-9+/=]+)'")
                .firstMatch(command)!
                .group(1)!;
            final sql = utf8.decode(base64Decode(encoded));
            if (sql.startsWith('SELECT')) return stored!;
            stored = RegExp("VALUES \\('xrayTemplateConfig', '(.*)'\\);")
                .firstMatch(sql)!
                .group(1)!
                .replaceAll("''", "'");
          }
          return '';
        },
      );
      verifyTemplate(
        jsonDecode(stored!) as Map<String, dynamic>,
        warp: state == 'ready',
      );
      expect(warpCalled, state != 'disabled');
      expect(
        warnings,
        state == 'failed' ? [WarpService.failureWarning] : isEmpty,
      );
    });
  }

  test('manual success/fallback and disabled templates include identical clean DNS', () {
    for (final enabled in [false, true]) {
      final script = XuiRoutingHelper.generateRoutingScript(
        DeploymentOptions(cloudflareWarp: enabled),
      );
      final matches = RegExp("MBX_CONFIG='([A-Za-z0-9+/=]+)'")
          .allMatches(script)
          .toList();
      expect(matches, hasLength(enabled ? 2 : 1));
      for (var index = 0; index < matches.length; index++) {
        verifyTemplate(
          jsonDecode(utf8.decode(base64Decode(matches[index].group(1)!)))
              as Map<String, dynamic>,
          warp: enabled && index == 0,
        );
      }
    }
  });

  test(
    'WARP readiness is verified through configured SOCKS proxy not direct curl',
    () {
      final script = WarpService.installScript;
      expect(script, contains('warp-cli --accept-tos mode proxy'));
      expect(script, contains('warp-cli --accept-tos proxy port 40000'));
      expect(script, contains('warp-cli --accept-tos connect'));
      expect(script, contains('--proxy socks5h://127.0.0.1:40000'));
      expect(script, contains("grep -q '^warp=on\$'"));
      expect(
        script.indexOf('--proxy socks5h://127.0.0.1:40000'),
        lessThan(script.indexOf('echo MBX_WARP_READY')),
      );
    },
  );
}
