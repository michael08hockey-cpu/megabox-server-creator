import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:megabox_server_creator/services/api_service.dart';
import 'package:megabox_server_creator/services/ssh_service.dart';

void main() {
  late List<String> sent;

  ApiService build({String schema = ''}) {
    sent = <String>[];
    return ApiService(
      ipAddress: '10.0.0.1',
      panelPort: 2053,
      basePath: 'admin-1',
      apiToken: '',
      runCommand: (String cmd) async {
        sent.add(cmd);
        if (cmd.contains('PRAGMA table_info(clients)')) return schema;
        if (cmd.contains('PRAGMA table_info(client_inbounds)')) {
          return schema.isEmpty
              ? ''
              : 'client_id\ninbound_id\nflow_override\ncreated_at\n';
        }
        if (cmd.contains('SELECT max(id)')) return '7\n';
        return '';
      },
    );
  }

  const modernSchema =
      'id\nemail\nuuid\nflow\nlimit_ip\ntotal_gb\n'
      'expiry_time\nenable\ntg_id\nsub_id\npassword\nauth\nsecurity\n'
      'reset\ncreated_at\nupdated_at\n';

  group('flow для VLESS-Reality', () {
    test(
      'SQLite-клиент получает flow xtls-rprx-vision в settings.clients',
      () async {
        final api = build();
        await api.addClientToInbound(
          inboundId: 1,
          uuid: 'uuid-1',
          email: 'user@example.com',
          limitIp: 0,
          totalGb: 0,
        );
        final insert = sent.firstWhere((String c) => c.contains('json_set'));
        expect(insert, contains('"flow":"xtls-rprx-vision"'));
      },
    );

    test('в нормализованной таблице clients flow прописан явно', () async {
      final api = build(schema: modernSchema);
      await api.addClientToInbound(
        inboundId: 1,
        uuid: 'uuid-1',
        email: 'user@example.com',
        limitIp: 3,
        totalGb: 1024,
        expiryTime: 99,
      );
      final sql = sent.join('\n');
      expect(sql, contains('INSERT INTO clients'));
      expect(sql, contains('INSERT INTO client_inbounds'));
      expect(sql, contains("'xtls-rprx-vision'"));
      expect(sql, contains('flow_override'));
      expect(sql, contains("WHERE email = 'user@example.com'"));
    });

    test(
      'старые версии 3X-UI без таблиц clients работают как раньше',
      () async {
        final api = build();
        await api.addClientToInbound(
          inboundId: 1,
          uuid: 'uuid-1',
          email: 'user@example.com',
          limitIp: 0,
          totalGb: 0,
        );
        final sql = sent.join('\n');
        expect(sql, isNot(contains('INSERT INTO clients')));
        expect(sql, isNot(contains('INSERT INTO client_inbounds')));
      },
    );
  });

  group('привязка клиента к обоим инбаундам', () {
    test('addClientToInbounds пишет клиента в 443 и 8443', () async {
      final api = build(schema: modernSchema);
      await api.addClientToInbounds(
        inboundIds: [1, 2],
        uuid: 'uuid-1',
        email: 'user@example.com',
        limitIp: 0,
        totalGb: 0,
      );
      final sql = sent.join('\n');
      expect(sql, contains('WHERE id = 1;'));
      expect(sql, contains('WHERE id = 2;'));
      expect(sql, contains('inbound_id = 1'));
      expect(sql, contains('inbound_id = 2'));
      expect(sql, contains("uuid = 'uuid-1'"));
    });

    test('email клиента различается на разных инбаундах', () async {
      final api = build(schema: modernSchema);
      await api.addClientToInbounds(
        inboundIds: [1, 2],
        uuid: 'uuid-1',
        email: 'user@example.com',
        limitIp: 0,
        totalGb: 0,
      );
      final sql = sent.join('\n');
      expect(sql, contains("'user@example.com'"));
      expect(sql, contains("'user@example.com-inbound-2'"));
    });

    test('пустой список инбаундов отклоняется', () async {
      final api = build();
      expect(
        () => api.addClientToInbounds(
          inboundIds: const [],
          uuid: 'uuid-1',
          email: 'user@example.com',
          limitIp: 0,
          totalGb: 0,
        ),
        throwsArgumentError,
      );
      expect(
        () => api.addClientToInbounds(
          inboundIds: const [0],
          uuid: 'uuid-1',
          email: 'user@example.com',
          limitIp: 0,
          totalGb: 0,
        ),
        throwsArgumentError,
      );
    });
  });

  group('ссылки на оба порта', () {
    test('основная и резервная ссылки различаются портом и содержат flow', () {
      String link(int port) => SSHService.buildVlessLink(
        server: '10.0.0.1',
        port: port,
        uuid: 'uuid',
        publicKey: 'PBK',
        shortId: 'sid',
        sni: 'example.com',
        fingerprint: 'chrome',
        remark: 'R',
      );
      final main = link(443);
      final backup = link(8443);
      expect(main, contains(':443?'));
      expect(backup, contains(':8443?'));
      for (final value in [main, backup]) {
        expect(value, contains('flow=xtls-rprx-vision'));
        expect(value, contains('sni=example.com'));
        expect(value, contains('security=reality'));
      }
      expect(Uri.parse(main).port, 443);
      expect(Uri.parse(backup).port, 8443);
    });

    test('JSON настроек инбаунда содержит flow для клиента', () {
      final settings = json.encode({
        'clients': [
          {'id': 'uuid-1', 'flow': 'xtls-rprx-vision', 'email': 'main-client'},
        ],
        'decryption': 'none',
      });
      final decoded = json.decode(settings) as Map<String, dynamic>;
      final clients = decoded['clients'] as List<dynamic>;
      expect(
        (clients.first as Map<String, dynamic>)['flow'],
        'xtls-rprx-vision',
      );
    });
  });
}
