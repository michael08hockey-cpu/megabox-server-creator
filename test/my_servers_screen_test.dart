import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:megabox_server_creator/widgets/vless_link_card.dart';
import 'package:megabox_server_creator/screens/server_management_screen.dart';
import 'package:megabox_server_creator/models/server_config.dart';
import 'package:megabox_server_creator/services/server_management_service.dart';
import 'package:megabox_server_creator/services/storage_service.dart';
import 'package:megabox_server_creator/widgets/client_policy_selector.dart';
import 'package:megabox_server_creator/widgets/result_cards.dart';

import 'server_history_test.dart' show savedServer;

class FakeManagement extends ServerManagementService {
  ServerConfig? config;
  ClientPolicy? policy;
  bool? root;
  @override
  Future<void> connectSSH(ServerConfig config) async {
    this.config = config;
  }

  @override
  Future<ServerLiveStats> getServerStats(String password, bool isRoot) async {
    root = isRoot;
    return ServerLiveStats(
      cpuUsage: 1,
      ramUsedMb: 100,
      ramTotalMb: 1000,
      ramPercent: 10,
      diskUsage: 5,
      uptime: '1 hour',
      xuiActive: true,
      activeConnections: 0,
    );
  }

  @override
  Future<List<String>> addFriendKeys(
    String password,
    bool isRoot,
    String ip,
    String name, {
    ClientPolicy policy = const ClientPolicy(),
  }) async {
    this.policy = policy;
    root = isRoot;
    return ['vless://guest@$ip:443', 'vless://guest@$ip:8443'];
  }
}

Future<void> openScreen(WidgetTester tester, {FakeManagement? service}) async {
  tester.view.physicalSize = const Size(1500, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: ServerManagementScreen(service: service)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('selection shows text/link and panel cards without SSH', (
    tester,
  ) async {
    final item = savedServer();
    await StorageService().addDeployment(item);
    final service = FakeManagement();
    await openScreen(tester, service: service);
    await tester.tap(find.text('Server one'));
    await tester.pumpAndSettle();
    expect(service.config, isNull);
    expect(find.byType(ResultCards), findsOneWidget);
    expect(find.text('Готовый VLESS REALITY ключ'), findsOneWidget);
    expect(find.text(item.shareLink), findsOneWidget);
    expect(find.text(item.backupShareLink!), findsOneWidget);
    expect(find.byType(VlessLinkCard), findsNWidgets(4));
    expect(find.text('Копировать ключ'), findsNWidgets(2));
    expect(find.text('Копировать резервный ключ'), findsNWidgets(2));
    expect(find.text('Доступ к веб-панели 3X-UI'), findsOneWidget);
    expect(find.text(item.panelUrl!), findsOneWidget);
    expect(find.text(item.panelUsername!), findsOneWidget);
    expect(find.text(item.panelPassword!), findsOneWidget);
    expect(find.text('Открыть в браузере'), findsOneWidget);
    expect(
      find.text('Скопировать все данные панели (URL + Логин + Пароль)'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'delete confirmation cancellation preserves server; confirm removes it',
    (tester) async {
      await StorageService().addDeployment(savedServer());
      await openScreen(tester);
      await tester.tap(find.byKey(const ValueKey('delete-server-one')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(await StorageService().loadHistory(), hasLength(1));
      await tester.tap(find.byKey(const ValueKey('delete-server-one')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Удалить из списка'));
      await tester.pumpAndSettle();
      expect(await StorageService().loadHistory(), isEmpty);
      expect(find.byKey(const ValueKey('delete-server-one')), findsNothing);
    },
  );

  testWidgets('history refreshes after new deployment and clear removes all', (
    tester,
  ) async {
    await openScreen(tester);
    await StorageService().addDeployment(savedServer());
    await tester.pumpAndSettle();
    expect(find.text('Server one'), findsOneWidget);
    await tester.tap(find.byTooltip('Очистить список серверов'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Очистить список'));
    await tester.pumpAndSettle();
    expect(await StorageService().loadHistory(), isEmpty);
    expect(find.text('Server one'), findsNothing);
  });

  testWidgets(
    'saved SSH identity supports sudo client creation with 30-day policy',
    (tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (_) async => null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await StorageService().addDeployment(savedServer());
      final service = FakeManagement();
      await openScreen(tester, service: service);
      await tester.tap(find.text('Server one'));
      await tester.pumpAndSettle();
      final connect = find.text('Подключиться по SSH');
      await tester.ensureVisible(connect);
      await tester.pumpAndSettle();
      await tester.tap(connect);
      await tester.pumpAndSettle();
      expect(service.config!.sshPort, 2222);
      expect(service.config!.sshUser, 'ubuntu');
      expect(service.config!.sshPassword, 'ssh-one');
      expect(service.root, isFalse);
      final create = find.text('Создать ключ клиента');
      await tester.ensureVisible(create);
      await tester.pumpAndSettle();
      await tester.tap(create);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'guest');
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.byType(ClientPolicySelector), findsOneWidget);
      await tester.tap(find.text('Навсегда / Бессрочно').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('На 30 дней').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Без лимита').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Заданный объём (ГБ)').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '25');
      await tester.tap(find.text('Создать'));
      await tester.pumpAndSettle();
      expect(service.policy!.hours, 720);
      expect(service.policy!.trafficGb, 25);
      expect(service.root, isFalse);
      expect(find.text('vless://guest@192.0.2.1:8443'), findsOneWidget);
    },
  );

  testWidgets(
    'panel copy-all includes actual secret URL username and password',
    (tester) async {
      final item = savedServer();
      String? clipboard;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = call.arguments['text'] as String;
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
      await StorageService().addDeployment(item);
      await openScreen(tester);
      await tester.tap(find.text('Server one'));
      await tester.pumpAndSettle();
      final copy = find.text(
        'Скопировать все данные панели (URL + Логин + Пароль)',
      );
      await tester.ensureVisible(copy);
      await tester.pumpAndSettle();
      await tester.tap(copy);
      await tester.pumpAndSettle();
      expect(clipboard, item.allPanelData);
    },
  );
}
