import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:megabox_server_creator/main.dart';
import 'package:megabox_server_creator/widgets/result_cards.dart';
import 'package:megabox_server_creator/widgets/vless_link_card.dart';
import 'package:megabox_server_creator/services/ssh_service.dart';
import 'package:megabox_server_creator/models/deployment_result.dart';

void main() {
  testWidgets('both log and live terminal expose clear controls', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MegaBoxApp());
    await tester.pumpAndSettle();
    expect(find.byTooltip('Очистить журнал'), findsOneWidget);
    await tester.tap(find.text('Живой терминал').first);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Очистить'), findsOneWidget);
    await tester.tap(find.byTooltip('Очистить'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets('result displays backup and friend links', (tester) async {
    String link(int port) => SSHService.buildVlessLink(
      server: '127.0.0.1',
      port: port,
      uuid: 'same-uuid',
      publicKey: 'pbk',
      shortId: 'abcd',
      sni: 'example.com',
      fingerprint: 'chrome',
      remark: 'test',
    );
    final result = DeploymentResult(
      vlessLink: link(443),
      backupVlessLink: link(8443),
      panelUrl: 'http://127.0.0.1:2053',
      panelUsername: 'admin',
      panelPassword: 'secret',
      locationFlag: 'US',
      locationName: 'USA',
      selectedSni: 'example.com',
      sniPing: 1,
      trafficVerified: false,
      httpCode: 0,
      portReachable: false,
      friendLinks: {'Alice': 'vless://friend'},
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: ResultCards(result: result)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(link(443)), findsOneWidget);
    expect(find.text(link(8443)), findsOneWidget);
    expect(find.text('Основной ключ — порт 443'), findsOneWidget);
    expect(find.text('Резервный ключ — порт 8443'), findsOneWidget);
    expect(find.text('vless://friend'), findsOneWidget);
    expect(find.text('Alice'), findsOneWidget);
    expect(find.byType(VlessLinkCard), findsNWidgets(3));
  });
}
