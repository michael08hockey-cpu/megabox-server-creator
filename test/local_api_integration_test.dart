import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:megabox_server_creator/services/api_service.dart';
import 'package:megabox_server_creator/services/storage_service.dart';
import 'package:megabox_server_creator/models/deployment_history.dart';

void main() {
  test(
    'API sends valid Reality JSON and bearer token to a real local HTTP server',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final handled = server.first.then((request) async {
        expect(request.uri.path, '/admin/panel/api/inbounds/add');
        expect(request.headers.value('Authorization'), 'Bearer test-token');
        final payload = jsonDecode(
          await utf8.decoder.bind(request).join(),
        ) as Map<String, dynamic>;
        expect(payload['port'], 443);
        final stream = jsonDecode(payload['streamSettings'] as String);
        expect(stream['realitySettings']['privateKey'], 'private');
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'success': true,
            'obj': {'id': 17},
          }),
        );
        await request.response.close();
      });
      final api = ApiService(
        ipAddress: '127.0.0.1',
        panelPort: server.port,
        basePath: '/admin/',
        apiToken: 'test-token',
      );
      try {
        final result = await api.addVlessRealityInbound(
          port: 443,
          publicKey: 'public',
          privateKey: 'private',
          shortId: '1234',
          uuid: 'uuid',
          sni: 'example.com',
          remark: "O'Brien",
        );
        expect(result['obj']['id'], 17);
        await handled;
      } finally {
        api.dispose();
        await server.close(force: true);
      }
    },
  );
  test('history roundtrip retains newest 50 entries', () async {
    SharedPreferences.setMockInitialValues({});
    final storage = StorageService();
    for (var i = 0; i < 52; i++) {
      await storage.addDeployment(
        DeploymentHistory(
          id: '$i',
          timestamp: DateTime.utc(2026).add(Duration(seconds: i)),
          ipAddress: '192.0.2.${i + 1}',
          vlessPort: 443,
          remark: 'test',
          shareLink: 'vless://test',
          sni: 'example.com',
        ),
      );
    }
    final history = await storage.loadHistory();
    expect(history.length, 50);
    expect(history.first.id, '51');
    expect(history.last.id, '2');
  });
  test('API URI supports IPv6 without malformed host syntax', () {
    final api = ApiService(
      ipAddress: '::1',
      panelPort: 2053,
      basePath: '/admin/',
      apiToken: 'token',
    );
    addTearDown(api.dispose);
    expect(Uri.parse(api.baseUrl).host, '::1');
    expect(Uri.parse(api.baseUrl).path, '/admin');
  });
}
