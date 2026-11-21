import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:megabox_server_creator/services/server_management_service.dart';
import 'package:megabox_server_creator/widgets/live_stats_panel.dart';

void main() {
  group('ServerLiveStats.parse', () {
    test('разбирает метрики и клиентов', () {
      const out = '''
cpu=125
ram_used=361
ram_total=1000
disk=29
disk_used_kb=1048576
disk_total_kb=10485760
load=0.12 0.08 0.05
cores=2
uptime=up 3 hours, 5 minutes
xui=active
conns=7
rx=1000
tx=2000
client|alice|100|200|0|0|1
client|bob|5|6|1073741824|1700000000000|0
''';
      final s = ServerLiveStats.parse(out);
      expect(s.cpuUsage, closeTo(12.5, 0.001));
      expect(s.ramPercent, closeTo(36.1, 0.001));
      expect(s.diskUsage, 29);
      expect(s.diskUsedGb, closeTo(1, 0.001));
      expect(s.diskTotalGb, closeTo(10, 0.001));
      expect(s.loadAverage, '0.12 0.08 0.05');
      expect(s.cpuCores, 2);
      expect(s.uptime, '3 hours, 5 minutes');
      expect(s.xuiActive, isTrue);
      expect(s.activeConnections, 7);
      expect(s.rxBytes, 1000);
      expect(s.txBytes, 2000);
      expect(s.clients, hasLength(2));
      expect(s.clients[0].email, 'alice');
      expect(s.clients[0].used, 300);
      expect(s.clients[0].enabled, isTrue);
      expect(s.clients[1].total, 1073741824);
      expect(s.clients[1].enabled, isFalse);
    });

    test('пустой или битый вывод не роняет разбор', () {
      final s = ServerLiveStats.parse('garbage\nclient|broken\n');
      expect(s.cpuUsage, 0);
      expect(s.ramTotalMb, 1);
      expect(s.xuiActive, isFalse);
      expect(s.rxBytes, isNull);
      expect(s.clients, isEmpty);
    });
  });

  /// Достаёт SQL из base64-обёртки ShellScripts.sql.
  String decodeSql(String script) {
    final m = RegExp(r"printf '%s' '([A-Za-z0-9+/=]+)'").firstMatch(script);
    expect(m, isNotNull, reason: 'SQL не найден в скрипте');
    return utf8.decode(base64Decode(m!.group(1)!));
  }

  group('управление клиентами', () {
    late List<String> sent;
    late ServerManagementService service;

    setUp(() {
      sent = <String>[];
      service = ServerManagementService(
        commandRunner: (cmd, _, _) async {
          sent.add(cmd);
          return '';
        },
      );
    });

    tearDown(() => service.dispose());

    test('сброс трафика обнуляет счётчики и перезапускает x-ui', () async {
      await service.resetClientTraffic('pw', true, 'alice');
      expect(sent, hasLength(2));
      expect(
        decodeSql(sent.first),
        "UPDATE client_traffics SET up = 0, down = 0 WHERE email = 'alice';",
      );
      expect(sent.last, 'systemctl restart x-ui');
    });

    test('отключение клиента меняет оба места хранения флага', () async {
      await service.setClientEnabled('pw', true, "o'neil", false);
      expect(sent, hasLength(2));
      final sql = decodeSql(sent.first);
      expect(sql, contains("UPDATE client_traffics SET enable = 0 WHERE email = 'o''neil';"));
      expect(sql, contains("json('false')"));
      expect(sql, contains(r"'$.clients[' || j.key || '].enable'"));
      expect(sql.trim(), startsWith('BEGIN;'));
      expect(sql.trim(), endsWith('COMMIT;'));
      expect(sent.last, 'systemctl restart x-ui');
    });
  });

  test('formatBytes', () {
    expect(formatBytes(0), '0 Б');
    expect(formatBytes(1536), '1.5 КБ');
    expect(formatBytes(1024 * 1024 * 250), '250 МБ');
    expect(formatBytes(1024.0 * 1024 * 1024 * 3.2), '3.2 ГБ');
  });
}
