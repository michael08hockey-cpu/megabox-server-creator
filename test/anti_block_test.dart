import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:megabox_server_creator/models/server_config.dart';
import 'package:megabox_server_creator/services/api_service.dart';
import 'package:megabox_server_creator/services/server_management_service.dart';
import 'package:megabox_server_creator/services/ssh_service.dart';

String sqlFromBase64(String script) {
  final m = RegExp(r"printf '%s' '([A-Za-z0-9+/=]+)'").firstMatch(script);
  return m == null ? '' : utf8.decode(base64Decode(m.group(1)!));
}

void main() {
  group('XHTTP-ссылки', () {
    test('xhttp: type, path, mode и без flow Vision', () {
      final link = SSHService.buildVlessLink(
        server: '1.2.3.4',
        port: 443,
        uuid: 'u',
        publicKey: 'PBK',
        shortId: 'sid',
        sni: 'www.samsung.com',
        remark: 'R',
        transport: 'xhttp',
        xhttpPath: '/abc123',
      );
      final q = Uri.parse(link).queryParameters;
      expect(q['type'], 'xhttp');
      expect(q['path'], '/abc123');
      expect(q['mode'], 'auto');
      expect(q.containsKey('flow'), isFalse);
      expect(q['security'], 'reality');
      expect(q['sni'], 'www.samsung.com');
    });

    test('tcp по умолчанию сохраняет Vision (совместимость)', () {
      final q = Uri.parse(
        SSHService.buildVlessLink(
          server: '1.2.3.4',
          port: 443,
          uuid: 'u',
          publicKey: 'PBK',
          shortId: 'sid',
          sni: 's.com',
          remark: 'R',
        ),
      ).queryParameters;
      expect(q['type'], 'tcp');
      expect(q['flow'], 'xtls-rprx-vision');
      expect(q.containsKey('path'), isFalse);
    });
  });

  group('streamSettings Inbound', () {
    test('xhttp: xhttpSettings с путём, без tcpSettings', () {
      final s = ApiService.realityStream(
        transport: 'xhttp',
        sni: 'www.samsung.com',
        privateKey: 'priv',
        publicKey: 'pub',
        shortId: 'abcd',
        xhttpPath: '/p1',
      );
      expect(s['network'], 'xhttp');
      expect(s['xhttpSettings'], {'path': '/p1', 'host': '', 'mode': 'auto'});
      expect(s.containsKey('tcpSettings'), isFalse);
      final reality = s['realitySettings'] as Map<String, dynamic>;
      expect(reality['target'], 'www.samsung.com:443');
      expect(reality['dest'], 'www.samsung.com:443');
      expect(reality['serverNames'], ['www.samsung.com']);
    });

    test('self-steal: target указывает на локальный nginx', () {
      final s = ApiService.realityStream(
        transport: 'xhttp',
        sni: 'notes.example.org',
        privateKey: 'priv',
        publicKey: 'pub',
        shortId: 'abcd',
        target: '127.0.0.1:${SSHService.selfStealLocalPort}',
      );
      final reality = s['realitySettings'] as Map<String, dynamic>;
      expect(reality['target'], '127.0.0.1:9443');
      expect(reality['serverNames'], ['notes.example.org']);
    });

    test('flow клиента зависит от транспорта', () {
      expect(ApiService.flowFor('tcp'), 'xtls-rprx-vision');
      expect(ApiService.flowFor('xhttp'), '');
    });

    test('по умолчанию XHTTP и скрытая панель', () {
      const o = DeploymentOptions();
      expect(o.transport, 'xhttp');
      expect(o.hidePanel, isTrue);
      expect(o.backupInbound, isFalse);
      expect(o.antiTorrent, isTrue);
      expect(o.xhttpObfs, isTrue);
      expect(o.updateXrayCore, isTrue);
      expect(o.useSelfSteal, isFalse);
      expect(
        const DeploymentOptions(selfStealDomain: ' a.site ').useSelfSteal,
        isTrue,
      );
    });
  });

  group('маска SNI', () {
    test('в списках нет выжженных доменов', () {
      for (final loc in ServerLocation.all) {
        for (final d in loc.sniCandidates) {
          expect(isBurnedSni(d), isFalse, reason: '${loc.code}: $d');
        }
      }
      for (final d in globalSniFallbacks) {
        expect(isBurnedSni(d), isFalse, reason: d);
      }
      expect(isBurnedSni('www.microsoft.com'), isTrue);
      expect(isBurnedSni('dl.google.com'), isTrue);
    });

    test('разбор: сортировка, дубли, фильтры', () {
      const out = '''
noise
MBXSNI slow.example 0.090
MBXSNI fast.example 0.012
MBXSNI fast.example 0.020
MBXSNI www.microsoft.com 0.001
MBXSNI bad;domain 0.001
MBXSNI zero.example 0
MBXSNI broken
''';
      final r = SSHService.parseSniProbe(out);
      expect(r.map((e) => e.key), ['fast.example', 'slow.example']);
      expect(r.first.value, closeTo(0.012, 1e-9));
    });

    test('скрипт проверки не пропускает инъекции в домене', () {
      final script = SSHService.sniProbeScript([
        'www.samsung.com',
        'evil.com;rm -rf /',
        r'$(reboot).com',
      ]);
      expect(script, contains('for d in www.samsung.com; do'));
      expect(script, isNot(contains('rm -rf')));
      expect(script, isNot(contains('reboot')));
      expect(script, contains('--tlsv1.3 --http2'));
      expect(script.trimRight(), endsWith('true'));
    });

    test('сканер соседей: только IPv4, сверка DNS с IP соседа', () {
      final script = SSHService.neighborSniScanScript('203.0.113.10');
      expect(script, startsWith("IP='203.0.113.10'"));
      expect(script, contains('getent ahostsv4'));
      expect(script, contains('xargs -P 48'));
      expect(
        () => SSHService.neighborSniScanScript('1.2.3.4; reboot'),
        throwsArgumentError,
      );
    });
  });

  group('self-steal', () {
    test('проверка домена', () {
      expect(SSHService.isValidSelfStealDomain('notes-anna.site'), isTrue);
      expect(SSHService.isValidSelfStealDomain('blog.example.org'), isTrue);
      expect(SSHService.isValidSelfStealDomain('bad domain.com'), isFalse);
      expect(SSHService.isValidSelfStealDomain('x;reboot.com'), isFalse);
      expect(SSHService.isValidSelfStealDomain('1.2.3.4'), isFalse);
      expect(SSHService.domainLooksLikeVpn('myvpn.site'), isTrue);
      expect(SSHService.domainLooksLikeVpn('notes-anna.site'), isFalse);
    });

    test('скрипт: A-запись, certbot, nginx на 127.0.0.1:9443', () {
      final script = SSHService.selfStealScript('notes.example.org', '1.2.3.4');
      expect(script, startsWith("DOMAIN='notes.example.org'\nIP='1.2.3.4'"));
      expect(script, contains('LOCAL_PORT=9443'));
      expect(script, contains('MBX_DNS_MISMATCH'));
      expect(script, contains('certbot certonly --webroot'));
      expect(script, contains(r'listen 127.0.0.1:$LOCAL_PORT ssl http2;'));
      expect(script, contains('MBX_SELFSTEAL_OK'));
      expect(script, isNot(contains('__APT_UNLOCK__')));
      expect(
        () => SSHService.selfStealScript('bad;domain', '1.2.3.4'),
        throwsArgumentError,
      );
    });

    test('SQL скрытия панели', () {
      expect(SSHService.hidePanelSql, contains("key = 'webListen'"));
      expect(SSHService.hidePanelSql, contains("'127.0.0.1'"));
    });
  });

  group('управление XHTTP-серверами', () {
    String row(int id, int port, String network) => jsonEncode({
      'id': id,
      'port': port,
      'settings': jsonEncode({
        'clients': [
          {'id': 'uuid-$port', 'email': 'c$port', 'enable': true},
        ],
      }),
      'stream': jsonEncode({
        'network': network,
        'security': 'reality',
        'realitySettings': {
          'settings': {'publicKey': 'pub', 'fingerprint': 'firefox'},
          'serverNames': ['www.samsung.com'],
          'shortIds': ['ab'],
        },
        if (network == 'xhttp') 'xhttpSettings': {'path': '/xp', 'mode': 'auto'},
      }),
    });

    test('ссылки читаются и для XHTTP', () async {
      final service = ServerManagementService(
        commandRunner: (cmd, _, _) async {
          final sql = sqlFromBase64(cmd);
          if (sql.startsWith('SELECT json_object')) return row(3, 443, 'xhttp');
          return '';
        },
      );
      addTearDown(service.dispose);
      final links = await service.getServerLinks('pw', true, '1.2.3.4');
      expect(links, hasLength(1));
      final q = Uri.parse(links.single).queryParameters;
      expect(q['type'], 'xhttp');
      expect(q['path'], '/xp');
      expect(q.containsKey('flow'), isFalse);
    });

    test('новый ключ: flow по транспорту каждого Inbound', () async {
      final writes = <String>[];
      final service = ServerManagementService(
        commandRunner: (cmd, _, _) async {
          final sql = sqlFromBase64(cmd);
          if (sql.startsWith('SELECT json_object')) {
            return '${row(3, 443, 'xhttp')}\n${row(4, 8443, 'tcp')}';
          }
          if (cmd.contains('UPDATE inbounds')) writes.add(cmd);
          return '';
        },
      );
      addTearDown(service.dispose);
      final links = await service.addFriendKeys('pw', true, '1.2.3.4', 'guest');
      expect(links.map((l) => Uri.parse(l).queryParameters['type']), [
        'xhttp',
        'tcp',
      ]);
      expect(writes, hasLength(2));
      final flows = writes
          .map((c) => RegExp(r'"flow":"([^"]*)"').firstMatch(c)?.group(1))
          .toList();
      expect(flows, containsAll(<String>['', 'xtls-rprx-vision']));
    });
  });

  group('маскировка паддинга XHTTP', () {
    test('случайные ключ и диапазон, tokenish в Referer', () {
      final p = SSHService.randomXhttpPadding(Random(1));
      expect(p['xPaddingObfsMode'], isTrue);
      expect(p['xPaddingHeader'], 'Referer');
      expect(p['xPaddingPlacement'], 'queryInHeader');
      expect(p['xPaddingMethod'], 'tokenish');
      expect(p['xPaddingKey'], isNot('x_padding'));
      final range = (p['xPaddingBytes'] as String).split('-').map(int.parse).toList();
      expect(range[0], inInclusiveRange(64, 223));
      expect(range[1], inInclusiveRange(900, 1399));
      final keys = {
        for (var i = 0; i < 40; i++) SSHService.randomXhttpPadding(Random(i))['xPaddingKey'],
      };
      expect(keys.length, greaterThan(1), reason: 'ключ должен меняться');
    });

    test('extra только при включённой маскировке', () {
      expect(SSHService.xhttpExtraFromSettings({'path': '/a', 'mode': 'auto'}), isNull);
      final extra = SSHService.xhttpExtraFromSettings({
        'path': '/a',
        'mode': 'auto',
        ...SSHService.randomXhttpPadding(Random(2)),
      })!;
      expect(extra['mode'], 'auto');
      expect(extra['xPaddingObfsMode'], isTrue);
      expect(extra.containsKey('path'), isFalse);
      expect(extra['xPaddingKey'], isNotEmpty);
    });

    test('сервер и ссылка получают одинаковые настройки', () {
      final padding = SSHService.randomXhttpPadding(Random(3));
      final stream = ApiService.realityStream(
        transport: 'xhttp',
        sni: 's.example',
        privateKey: 'priv',
        publicKey: 'pub',
        shortId: 'ab',
        xhttpPath: '/p',
        xhttpPadding: padding,
      );
      final xhttp = stream['xhttpSettings'] as Map<String, dynamic>;
      expect(xhttp['xPaddingObfsMode'], isTrue);
      expect(xhttp['path'], '/p');
      final link = SSHService.buildVlessLink(
        server: '1.2.3.4',
        port: 443,
        uuid: 'u',
        publicKey: 'pub',
        shortId: 'ab',
        sni: 's.example',
        remark: 'R',
        transport: 'xhttp',
        xhttpPath: '/p',
        xhttpExtra: SSHService.xhttpExtraFromSettings(xhttp),
      );
      final q = Uri.parse(link).queryParameters;
      final extra = jsonDecode(q['extra']!) as Map<String, dynamic>;
      expect(extra['xPaddingKey'], padding['xPaddingKey']);
      expect(extra['xPaddingBytes'], padding['xPaddingBytes']);
      expect(q['x_padding_bytes'], padding['xPaddingBytes']);
      // TCP-ссылка extra не получает
      final tcp = SSHService.buildVlessLink(
        server: '1.2.3.4',
        port: 443,
        uuid: 'u',
        publicKey: 'pub',
        shortId: 'ab',
        sni: 's.example',
        remark: 'R',
        xhttpExtra: {'xPaddingObfsMode': true},
      );
      expect(Uri.parse(tcp).queryParameters.containsKey('extra'), isFalse);
    });

    test('управление читает маскировку из Inbound', () async {
      final padding = SSHService.randomXhttpPadding(Random(4));
      final row = jsonEncode({
        'id': 1,
        'port': 443,
        'settings': jsonEncode({
          'clients': [
            {'id': 'uuid-1', 'email': 'c1', 'enable': true},
          ],
        }),
        'stream': jsonEncode({
          'network': 'xhttp',
          'security': 'reality',
          'realitySettings': {
            'settings': {'publicKey': 'pub'},
            'serverNames': ['s.example'],
            'shortIds': ['ab'],
          },
          'xhttpSettings': {'path': '/x', 'mode': 'auto', ...padding},
        }),
      });
      final service = ServerManagementService(
        commandRunner: (cmd, _, _) async =>
            sqlFromBase64(cmd).startsWith('SELECT json_object') ? row : '',
      );
      addTearDown(service.dispose);
      final links = await service.getServerLinks('pw', true, '1.2.3.4');
      final extra = jsonDecode(Uri.parse(links.single).queryParameters['extra']!);
      expect(extra['xPaddingKey'], padding['xPaddingKey']);
    });

    test('поиск JSON-объекта в сырых данных базы', () {
      const raw = r'garbage {"stream":"x","xhttpSettings":{"path":"/a}b","headers":{"h":"v"},"xPaddingObfsMode":true}} tail';
      final obj = ServerManagementService.extractJsonObject(raw, 'xhttpSettings')!;
      expect(obj['path'], '/a}b');
      expect(obj['headers'], {'h': 'v'});
      expect(ServerManagementService.extractJsonObject(raw, 'nope'), isNull);
    });
  });

  test('скрипт обновления Xray: порт, откат, MPTCP', () {
    final script = SSHService.xrayUpdateScript(443);
    expect(script, startsWith('PORT=443\n'));
    expect(script, contains('net.mptcp.enabled=0'));
    expect(script, contains('releases/latest'));
    expect(script, contains('MBX_XRAY_ROLLBACK'));
    expect(script, contains(r'$BIN.mbx-bak'));
    expect(script.trimRight(), endsWith('true'));
  });
}
