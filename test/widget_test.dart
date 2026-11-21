import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:megabox_server_creator/main.dart';

void main() {
  // Приложение рассчитано на окно не меньше 1040x720 (см. main.dart),
  // поэтому тестовую поверхность задаём такого же размера.
  const Size surface = Size(1040, 720);

  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = surface;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MegaBoxApp());
    await tester.pumpAndSettle();
  }

  testWidgets('MegaBox app renders the server configuration form', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester);

    expect(find.text('Настройка сервера'), findsOneWidget);
    expect(find.text('Развернуть сервер'), findsOneWidget);
    expect(find.text('IP-адрес VPS'), findsOneWidget);
  });

  testWidgets('AppShell exposes both navigation tabs', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester);

    expect(find.text('Развёртывание'), findsOneWidget);
    expect(find.text('Мои серверы'), findsWidgets);
  });

  testWidgets('phone layout uses bottom navigation and opens diagnostics', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MegaBoxApp());
    await tester.pumpAndSettle();

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('Настройка сервера'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Проверка'));
    await tester.pumpAndSettle();
    expect(find.text('Диагностика сервера'), findsWidgets);
    expect(find.text('Запустить проверку'), findsOneWidget);

    await tester.tap(find.text('Мои серверы').last);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Развёртывание').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Журнал'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Очистить журнал'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop layout shows the diagnostics tab in the sidebar', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester);
    expect(find.text('Проверка'), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
  });
}
