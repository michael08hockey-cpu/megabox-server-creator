import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:megabox_server_creator/widgets/log_terminal.dart';
import 'package:megabox_server_creator/models/deployment_log.dart';
import 'package:megabox_server_creator/services/api_service.dart';

void main() {
  testWidgets('journal clears, accepts later events and cancels subscription', (
    tester,
  ) async {
    final stream = StreamController<DeploymentLog>.broadcast();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: LogTerminal(logStream: stream.stream)),
      ),
    );
    stream.add(
      DeploymentLog(
        type: DeploymentLogType.info,
        timestamp: DateTime.now(),
        message: 'first',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('first'), findsOneWidget);
    await tester.tap(find.byTooltip('Очистить журнал'));
    await tester.pumpAndSettle();
    expect(find.text('first'), findsNothing);
    stream.add(
      DeploymentLog(
        type: DeploymentLogType.info,
        timestamp: DateTime.now(),
        message: 'second',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('second'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    expect(stream.hasListener, isFalse);
    await stream.close();
  });
  test('SQLite command not found status fails immediately', () async {
    final api = ApiService(
      ipAddress: '127.0.0.1',
      panelPort: 2053,
      basePath: '',
      apiToken: '',
      runCommand: (_) async =>
          'sqlite3: command not found\nMBX_SQL_STATUS=127\n',
    );
    addTearDown(api.dispose);
    await expectLater(
      api.addClientToInbound(
        inboundId: 4,
        uuid: 'uuid',
        email: 'guest',
        limitIp: 0,
        totalGb: 0,
      ),
      throwsStateError,
    );
  });
  test(
    'replacement deletes traffic before inbound inside a transaction',
    () async {
      final sent = <String>[];
      final api = ApiService(
        ipAddress: '127.0.0.1',
        panelPort: 2053,
        basePath: '',
        apiToken: '',
        runCommand: (command) async {
          sent.add(command);
          return command.contains('SELECT max(id)')
              ? '9\nMBX_SQL_STATUS=0\n'
              : 'MBX_SQL_STATUS=0\n';
        },
      );
      addTearDown(api.dispose);
      final result = await api.addVlessRealityInbound(
        port: 443,
        publicKey: 'p',
        privateKey: 's',
        shortId: 'sid',
        uuid: 'uuid',
        sni: 'example.com',
        remark: 'name',
      );
      expect(result['obj']['id'], 9);
      final script = sent.firstWhere((s) => s.contains('INSERT INTO inbounds'));
      expect(
        script.indexOf('DELETE FROM client_traffics'),
        lessThan(script.indexOf('DELETE FROM inbounds')),
      );
      expect(
        script.indexOf('DELETE FROM inbounds'),
        lessThan(script.indexOf('INSERT INTO inbounds')),
      );
      expect(script, contains('BEGIN IMMEDIATE;'));
      expect(script, contains('COMMIT;'));
    },
  );
}
