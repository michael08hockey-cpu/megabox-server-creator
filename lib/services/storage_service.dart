import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/deployment_history.dart';
import 'host_key_store.dart';

class StorageService {
  static const _historyKey = 'deployment_history';
  static final ValueNotifier<int> historyRevision = ValueNotifier(0);
  static Future<void>? _pendingWrite;
  static Object? _writeToken;

  Future<void> _serialize(Future<void> Function() action) {
    final previous = _pendingWrite;
    final token = Object();
    _writeToken = token;
    Future<void> run() async {
      if (previous != null) {
        try {
          await previous;
        } catch (_) {
          /* Keep the queue usable. */
        }
      }
      try {
        await action();
      } finally {
        if (identical(_writeToken, token)) {
          _pendingWrite = null;
          _writeToken = null;
        }
      }
    }

    return _pendingWrite = run();
  }

  Future<List<DeploymentHistory>> loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final String? historyJson = prefs.getString(_historyKey);
    if (historyJson == null) return [];

    try {
      final decoded = json.decode(historyJson);
      if (decoded is! List) return [];
      final history = <DeploymentHistory>[];
      for (final item in decoded) {
        try {
          history.add(DeploymentHistory.fromJson(item as Map<String, dynamic>));
        } catch (_) {
          // A broken record must not hide the remaining valid servers.
        }
      }
      history.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      final ips = <String>{};
      return history
          .where((item) => ips.add(item.ipAddress.trim().toLowerCase()))
          .toList();
    } catch (_) {
      // Повреждённое хранилище не должно ломать запуск приложения.
      return [];
    }
  }

  Future<void> saveHistory(List<DeploymentHistory> history) =>
      _serialize(() => _writeHistory(history));

  Future<void> _writeHistory(List<DeploymentHistory> history) async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = json.encode(history.map((h) => h.toJson()).toList());
    if (!await prefs.setString(_historyKey, encoded)) {
      throw StateError('Не удалось сохранить данные серверов');
    }
    historyRevision.value++;
  }

  /// Сохраняет развёртывание, обновляя существующую запись с тем же IP.
  ///
  /// Повторный деплой на тот же VPS не должен оставлять дубликаты со
  /// старыми паролями: запись по IP заменяется свежей и переносится вверх.
  Future<void> addDeployment(DeploymentHistory deployment) =>
      _serialize(() async {
        final history = await loadHistory();

        history.removeWhere(
          (item) =>
              item.ipAddress.trim().toLowerCase() ==
              deployment.ipAddress.trim().toLowerCase(),
        );
        history.insert(0, deployment);

        // Keep only last 50 deployments
        if (history.length > 50) {
          history.removeRange(50, history.length);
        }

        await _writeHistory(history);
      });

  /// Удаляет запись сервера по её идентификатору.
  Future<void> removeDeployment(String id) => _serialize(() async {
    final history = await loadHistory();
    history.removeWhere((item) => item.id == id);
    await _writeHistory(history);
  });

  /// Удаляет выбранный сервер по IP-адресу.
  Future<void> removeDeploymentByIp(String ipAddress) => _serialize(() async {
    final history = await loadHistory();
    history.removeWhere(
      (item) =>
          item.ipAddress.trim().toLowerCase() == ipAddress.trim().toLowerCase(),
    );
    await _writeHistory(history);
    // После переустановки ОС ключ сервера меняется — даём подключиться заново.
    await HostKeyStore.forgetHost(ipAddress);
  });

  /// Полностью очищает список серверов.
  Future<void> clearHistory() => _serialize(() async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.remove(_historyKey)) {
      throw StateError('Не удалось очистить список серверов');
    }
    historyRevision.value++;
  });
}
