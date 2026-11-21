import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:megabox_server_creator/models/deployment_history.dart';
import 'package:megabox_server_creator/models/server_config.dart';
import 'package:megabox_server_creator/services/storage_service.dart';

DeploymentHistory savedServer({
  String ip = '192.0.2.1',
  String id = 'one',
  int day = 1,
}) => DeploymentHistory(
  id: id,
  timestamp: DateTime.utc(2026, 1, day),
  ipAddress: ip,
  vlessPort: 443,
  remark: 'Server $id',
  shareLink: 'vless://owner@$ip:443?security=reality',
  backupShareLink: 'vless://owner@$ip:8443?security=reality',
  sni: 'example.com',
  panelUrl: 'http://$ip:2053/secret-path/',
  panelUsername: 'admin-$id',
  panelPassword: 'panel-$id',
  sshPort: 2222,
  sshUser: 'ubuntu',
  sshPassword: 'ssh-$id',
  locationCode: 'DE',
  locationFlag: '🇩🇪',
  locationName: 'Германия',
  friendLinks: {'Alice': 'vless://friend@$ip:443'},
  friendBackupLinks: {'Alice': 'vless://friend@$ip:8443'},
  subUrl: 'https://example.com/sub',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'full deployment capture and JSON/storage roundtrip preserve every secret',
    () async {
      final config = ServerConfig(
        ipAddress: '192.0.2.1',
        sshPort: 2222,
        sshUser: 'ubuntu',
        sshPassword: 'ssh-secret',
        location: ServerLocation.germany,
        vlessPort: 443,
        remark: 'test',
      );
      final result = savedServer().toDeploymentResult();
      final captured = DeploymentHistory.fromDeployment(config, result);
      final storage = StorageService();
      await storage.addDeployment(captured);
      final loaded = (await StorageService().loadHistory()).single;
      expect(loaded.toJson(), captured.toJson());
      expect(loaded.shareLink, result.vlessLink);
      expect(loaded.backupShareLink, result.backupVlessLink);
      expect(loaded.panelUrl, endsWith('/secret-path/'));
      expect(loaded.panelUsername, result.panelUsername);
      expect(loaded.panelPassword, result.panelPassword);
      expect(loaded.allPanelData, result.allPanelData);
      final reconnect = loaded.toServerConfig();
      expect(reconnect.sshPort, 2222);
      expect(reconnect.sshUser, 'ubuntu');
      expect(reconnect.sshPassword, 'ssh-secret');
      expect(reconnect.location.code, 'DE');
      expect(
        loaded.toDeploymentResult().friendBackupLinks,
        result.friendBackupLinks,
      );
      expect(loaded.subUrl, result.subUrl);
    },
  );

  test('legacy JSON stays readable without fabricated panel or backup', () {
    final json = savedServer().toJson();
    for (final key in [
      'backupShareLink',
      'panelUrl',
      'panelUsername',
      'panelPassword',
      'sshPort',
      'sshUser',
      'sshPassword',
      'locationCode',
      'locationFlag',
      'locationName',
    ]) {
      json.remove(key);
    }
    final legacy = DeploymentHistory.fromJson(json);
    expect(legacy.sshPort, 22);
    expect(legacy.sshUser, 'root');
    expect(legacy.hasSavedSshPassword, isFalse);
    expect(legacy.isLegacy, isTrue);
    expect(legacy.panelUrl, isNull);
    expect(legacy.backupShareLink, isNull);
  });

  test(
    'redeploy removes all old IP duplicates and promotes fresh credentials',
    () async {
      final old = savedServer(id: 'old');
      final other = savedServer(ip: '192.0.2.2', id: 'other', day: 2);
      SharedPreferences.setMockInitialValues({
        'deployment_history': jsonEncode([
          old.toJson(),
          old.copyWith(id: 'duplicate').toJson(),
          other.toJson(),
        ]),
      });
      final storage = StorageService();
      await storage.addDeployment(savedServer(id: 'new', day: 3));
      final history = await storage.loadHistory();
      expect(history.map((e) => e.id), ['new', 'other']);
      expect(history.first.panelPassword, 'panel-new');
      expect(history.first.sshPassword, 'ssh-new');
      final prefs = await SharedPreferences.getInstance();
      expect(
        jsonDecode(prefs.getString('deployment_history')!) as List,
        hasLength(2),
      );
    },
  );

  test(
    'delete one server then clear all persists across service instances',
    () async {
      final storage = StorageService();
      await storage.addDeployment(savedServer());
      await storage.addDeployment(
        savedServer(ip: '192.0.2.2', id: 'two', day: 2),
      );
      await storage.removeDeployment('one');
      expect((await StorageService().loadHistory()).single.id, 'two');
      await storage.clearHistory();
      expect(await StorageService().loadHistory(), isEmpty);
    },
  );

  test('concurrent read-modify-writes do not lose servers', () async {
    await Future.wait(
      List.generate(
        8,
        (i) => StorageService().addDeployment(
          savedServer(ip: '192.0.2.${i + 1}', id: '$i', day: i + 1),
        ),
      ),
    );
    expect(await StorageService().loadHistory(), hasLength(8));
  });

  test('malformed records do not hide valid records', () async {
    SharedPreferences.setMockInitialValues({
      'deployment_history': jsonEncode([
        {'id': 'broken'},
        savedServer().toJson(),
      ]),
    });
    expect((await StorageService().loadHistory()).single.id, 'one');
  });
}
