import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:megabox_server_creator/widgets/client_policy_selector.dart';
import 'package:megabox_server_creator/services/server_management_service.dart';
import 'package:megabox_server_creator/services/api_service.dart';
import 'package:megabox_server_creator/models/server_config.dart';
import 'package:megabox_server_creator/services/ssh_service.dart';

String sqlFromBase64(String command) => utf8.decode(
  base64Decode(
    RegExp("printf '%s' '([A-Za-z0-9+/=]+)'").firstMatch(command)!.group(1)!,
  ),
);

void main() {
  test('default client links use Firefox on both ports', () {
    for (final port in [443, 8443]) {
      final link = SSHService.buildVlessLink(
        server: '127.0.0.1',
        port: port,
        uuid: 'uuid',
        publicKey: 'pk',
        shortId: 'ab',
        sni: 'example.com',
        remark: 'test',
      );
      expect(Uri.parse(link).queryParameters['fp'], 'firefox');
      expect(Uri.parse(link).queryParameters['flow'], 'xtls-rprx-vision');
    }
  });
  test(
    'modern client records and traffic persist policy on both IDs',
    () async {
      final writes = <String>[];
      final api = ApiService(
        ipAddress: '127.0.0.1',
        panelPort: 2053,
        basePath: '',
        apiToken: '',
        runCommand: (cmd) async {
          if (cmd.contains('PRAGMA table_info(clients)')) {
            return 'id\nemail\nuuid\nflow\ntotal_gb\nexpiry_time\nenable\n';
          }
          if (cmd.contains('PRAGMA table_info(client_inbounds)')) {
            return 'client_id\ninbound_id\nflow_override\n';
          }
          writes.add(cmd);
          return '';
        },
      );
      addTearDown(api.dispose);
      const policy = ClientPolicy(hours: 720, trafficGb: 25);
      final expiry = policy.expiryAt(DateTime.utc(2026));
      await api.addClientToInbounds(
        inboundIds: [7, 12],
        uuid: 'uuid',
        email: 'guest',
        limitIp: 0,
        totalGb: policy.totalBytes,
        expiryTime: expiry,
      );
      expect(writes.length, 2);
      for (final sql in writes) {
        expect(sql, contains('INSERT INTO clients'));
        expect(sql, contains('INSERT INTO client_inbounds'));
        expect(sql, contains('total_gb = ${policy.totalBytes}'));
        expect(sql, contains('expiry_time = $expiry'));
        expect(sql, contains('INSERT INTO client_traffics'));
        expect(sql, contains('"totalGB":${policy.totalBytes}'));
        expect(sql, contains('"expiryTime":$expiry'));
      }
    },
  );

  test(
    'unlimited policy writes zero; 30 days and GB use milliseconds and bytes',
    () {
      final now = DateTime.utc(2026, 1, 1);
      expect(const ClientPolicy().expiryAt(now), 0);
      expect(const ClientPolicy().totalBytes, 0);
      const limited = ClientPolicy(hours: 720, trafficGb: 30);
      expect(limited.expiryAt(now), now.millisecondsSinceEpoch + 30 * 86400000);
      expect(limited.totalBytes, 30 * 1073741824);
      expect(
        () => const ClientPolicy(trafficGb: -1).totalBytes,
        throwsArgumentError,
      );
    },
  );

  test('all default locations and SQLite inbounds use Firefox', () async {
    expect(
      ServerLocation.all.every((location) => location.fingerprint == 'firefox'),
      isTrue,
    );
    final sent = <String>[];
    final api = ApiService(
      ipAddress: '127.0.0.1',
      panelPort: 2053,
      basePath: '',
      apiToken: '',
      runCommand: (command) async {
        sent.add(command);
        return command.contains('SELECT max(id)') ? '5\n' : '';
      },
    );
    addTearDown(api.dispose);
    for (final port in [443, 8443]) {
      await api.addVlessRealityInbound(
        port: port,
        publicKey: 'pk',
        privateKey: 'sk',
        shortId: 'ab',
        uuid: 'uuid',
        sni: 'example.com',
        remark: 'test-$port',
      );
    }
    final inserts = sent
        .where((command) => command.contains('INSERT INTO inbounds'))
        .toList();
    expect(inserts.length, 2);
    for (final insert in inserts) {
      expect(insert, contains('"fingerprint":"firefox"'));
      expect(insert, contains('"flow":"xtls-rprx-vision"'));
    }
  });

  for (final policy in [
    const ClientPolicy(),
    const ClientPolicy(hours: 720, trafficGb: 25),
  ]) {
    test(
      'management saves policy and same UUID on actual IDs for both ports (${policy.trafficGb})',
      () async {
        final writes = <String>[];
        final rows = [
          for (final port in [443, 8443])
            jsonEncode({
              'id': port == 443 ? 7 : 12,
              'port': port,
              'settings': jsonEncode({
                'clients': [
                  {'id': 'old', 'email': 'old', 'enable': true},
                ],
              }),
              'stream': jsonEncode({
                'network': 'tcp',
                'security': 'reality',
                'realitySettings': {
                  'settings': {'publicKey': 'public-$port'},
                  'serverNames': ['sni-$port.example.com'],
                  'shortIds': ['abcd'],
                },
              }),
            }),
        ].join('\n');
        final service = ServerManagementService(
          commandRunner: (command, password, root) async {
            expect(password, 'password');
            expect(root, isFalse);
            if (command.contains('base64 -d')) {
              final sql = sqlFromBase64(command);
              if (sql.startsWith('SELECT json_object')) return rows;
            }
            if (command.contains('UPDATE inbounds')) writes.add(command);
            return '';
          },
        );
        addTearDown(service.dispose);
        final before = DateTime.now();
        final links = await service.addFriendKeys(
          'password',
          false,
          '127.0.0.1',
          'guest',
          policy: policy,
        );
        expect(links.map((link) => Uri.parse(link).port), [443, 8443]);
        expect(Uri.parse(links.first).userInfo, Uri.parse(links.last).userInfo);
        for (final link in links) {
          final uri = Uri.parse(link);
          expect(uri.queryParameters['fp'], 'firefox');
          expect(uri.queryParameters['flow'], 'xtls-rprx-vision');
          expect(uri.queryParameters['sni'], 'sni-${uri.port}.example.com');
          expect(uri.queryParameters['pbk'], 'public-${uri.port}');
        }
        expect(writes.length, 2);
        for (final command in writes) {
          final json = RegExp(r"json\('(.*)'\)")
              .firstMatch(command)!
              .group(1)!
              .replaceAll("''", "'");
          final client = jsonDecode(json) as Map<String, dynamic>;
          expect(client['totalGB'], policy.totalBytes);
          if (policy.hours == null) {
            expect(client['expiryTime'], 0);
          } else {
            expect(
              client['expiryTime'],
              greaterThanOrEqualTo(policy.expiryAt(before)),
            );
            expect(
              client['expiryTime'],
              lessThanOrEqualTo(policy.expiryAt(DateTime.now())),
            );
          }
          expect(command, contains('INSERT INTO client_traffics'));
        }
        final readLinks = await service.getServerLinks(
          'password',
          false,
          '127.0.0.1',
        );
        expect(readLinks.map((link) => Uri.parse(link).port), [443, 8443]);
      },
    );
  }

  testWidgets(
    'policy form selects 30 days/custom volume and rejects invalid input',
    (tester) async {
      final formKey = GlobalKey<FormState>();
      var policy = const ClientPolicy();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Form(
              key: formKey,
              child: StatefulBuilder(
                builder: (context, update) => ClientPolicySelector(
                  value: policy,
                  onChanged: (value) => update(() => policy = value),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Навсегда / Бессрочно').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('На 30 дней').last);
      await tester.pumpAndSettle();
      expect(policy.hours, 720);
      await tester.tap(find.text('Без лимита').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Заданный объём (ГБ)').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '25');
      expect(policy.totalBytes, 25 * 1073741824);
      await tester.enterText(find.byType(TextFormField), '-1');
      expect(formKey.currentState!.validate(), isFalse);
      await tester.pump();
      expect(find.text('Введите от 1 до 1000000 ГБ'), findsOneWidget);
    },
  );
}
