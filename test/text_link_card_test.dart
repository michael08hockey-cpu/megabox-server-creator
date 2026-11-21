import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:megabox_server_creator/services/ssh_service.dart';
import 'package:megabox_server_creator/widgets/vless_link_card.dart';

String keyLink(int port) => SSHService.buildVlessLink(
  server: '192.0.2.1',
  port: port,
  uuid: 'owner',
  publicKey: 'pk',
  shortId: 'abcd',
  sni: 'example.com',
  remark: 'test',
);

void main() {
  testWidgets(
    'compact main and backup cards show text metadata and copy exact links',
    (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = call.arguments['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: [
                  VlessLinkCard(link: keyLink(443)),
                  VlessLinkCard(link: keyLink(8443)),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Порт: 443'), findsOneWidget);
      expect(find.text('Порт: 8443'), findsOneWidget);
      expect(find.text('SNI: example.com'), findsNWidgets(2));
      expect(find.text('uTLS: firefox'), findsNWidgets(2));
      expect(find.text('Flow: xtls-rprx-vision'), findsNWidgets(2));
      expect(find.byType(TabBar), findsNothing);
      await tester.tap(find.text('Копировать ключ'));
      await tester.pumpAndSettle();
      expect(copied, keyLink(443));
      await tester.ensureVisible(find.text('Копировать резервный ключ'));
      await tester.tap(find.text('Копировать резервный ключ'));
      await tester.pumpAndSettle();
      expect(copied, keyLink(8443));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('text-only card fits narrow layouts without a QR column', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: VlessLinkCard(link: keyLink(443))),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(keyLink(443)), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('all production Dart files and dependency manifest are free of QR code APIs', () {
    final root = Directory.current.path;
    final files = Directory('$root/lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'));
    for (final file in files) {
      final source = file.readAsStringSync();
      expect(source, isNot(contains('QrImageView')), reason: file.path);
      expect(source, isNot(contains('qr_flutter')), reason: file.path);
      expect(source, isNot(contains('QRDisplay')), reason: file.path);
      expect(source, isNot(contains('Icons.qr_code')), reason: file.path);
    }
    expect(
      File('$root/pubspec.yaml').readAsStringSync(),
      isNot(contains('qr_flutter')),
    );
    expect(File('$root/lib/widgets/qr_display.dart').existsSync(), isFalse);
  });
}
