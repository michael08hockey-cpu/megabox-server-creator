import 'dart:async';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

/// Проверка ключа SSH-сервера по схеме TOFU (trust on first use).
///
/// При первом подключении к host:port отпечаток ключа запоминается.
/// Если при следующем подключении ключ другой — соединение отклоняется:
/// это либо переустановка ОС на VPS, либо перехват (MITM), и пароль
/// root в таком случае отправлять нельзя.
///
/// После законной переустановки VPS вызовите [forget] для этого сервера.
class HostKeyStore {
  static const _prefix = 'mbx_hostkey_';

  /// Последняя ошибка несовпадения — чтобы показать понятное сообщение.
  static String? lastMismatch;

  static String _key(String host, int port) => '$_prefix$host:$port';

  static String _hex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(':');

  /// Обработчик для `SSHClient(onVerifyHostKey: ...)`.
  static FutureOr<bool> Function(String type, Uint8List fingerprint) verifier(
    String host,
    int port,
  ) {
    return (String type, Uint8List fingerprint) async {
      final value = '$type ${_hex(fingerprint)}';
      final prefs = await SharedPreferences.getInstance();
      final key = _key(host, port);
      final saved = prefs.getString(key);

      if (saved == null) {
        await prefs.setString(key, value);
        return true;
      }
      if (saved == value) return true;

      lastMismatch =
          'Ключ SSH-сервера $host:$port изменился!\n'
          'Было: $saved\nСейчас: $value\n'
          'Если ты переустанавливал ОС на VPS — удали сервер из «Мои серверы» '
          'или сбрось сохранённый ключ и подключись снова. '
          'Если нет — возможен перехват соединения, не подключайся.';
      return false;
    };
  }

  /// Забыть ключ сервера (после переустановки ОС на VPS).
  static Future<void> forget(String host, int port) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key(host, port));
  }

  /// Забыть ключи сервера на всех портах (при удалении из «Мои серверы»).
  static Future<void> forgetHost(String host) async {
    final prefs = await SharedPreferences.getInstance();
    final p = '$_prefix${host.trim()}:';
    for (final k in prefs.getKeys().where((k) => k.startsWith(p)).toList()) {
      await prefs.remove(k);
    }
  }
}
