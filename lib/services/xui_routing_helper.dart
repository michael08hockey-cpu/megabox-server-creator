import 'dart:convert';

import '../models/server_config.dart';
import 'shell_scripts.dart';
import 'warp_service.dart';

/// Хелпер для настройки правил маршрутизации Xray в 3X-UI.
/// Управляет обходом .RU доменов, анти-Торрент, AdBlock, Cloudflare WARP
/// (локальный SOCKS outbound) и Telegram-ботом панели (авто-бэкапы).
class XuiRoutingHelper {
  /// Применение правил маршрутизации на сервере.
  static Future<void> applyRoutingRules({
    required String sshPassword,
    required bool isRoot,
    required Future<String> Function(String, String, bool) runCommand,
    required DeploymentOptions options,
    void Function(String message)? onWarning,
  }) async {
    var warpEnabled = false;
    if (options.cloudflareWarp) {
      try {
        await WarpService.configure(
          sshPassword: sshPassword,
          isRoot: isRoot,
          runCommand: runCommand,
        );
        warpEnabled = true;
      } catch (_) {
        onWarning?.call(WarpService.failureWarning);
      }
    }
    final rules = _buildRoutingRules(options, warpEnabled: warpEnabled);

    await _updateXuiDatabase(
      rules: rules,
      warpEnabled: warpEnabled,
      sshPassword: sshPassword,
      isRoot: isRoot,
      runCommand: runCommand,
      options: options,
    );
  }

  /// Priority AI routes use WARP only after successful registration/readiness.
  static const aiDomains = <String>[
    'geosite:google',
    'domain:gemini.google.com',
    'domain:bard.google.com',
    'domain:proactivebackend-pa.googleapis.com',
    'domain:alkalimakersuite-pa.googleapis.com',
    'domain:ai.google.dev',
    'domain:generativelanguage.googleapis.com',
    'geosite:openai',
  ];

  static Map<String, dynamic> _dnsConfig() => {
    'servers': ['8.8.8.8', '1.1.1.1'],
    'queryStrategy': 'UseIPv4',
  };

  /// Домены, которые направляются через Cloudflare WARP.
  static const List<String> warpDomains = [
    'openai.com',
    'chatgpt.com',
    'chat.openai.com',
    'api.openai.com',
    'oaistatic.com',
    'oaiusercontent.com',
    'claude.ai',
    'anthropic.com',
    'netflix.com',
    'nfcdn.net',
  ];

  /// остроение правил маршрутизации.
  static List<Map<String, dynamic>> _buildRoutingRules(
    DeploymentOptions options, {
    bool? warpEnabled,
  }) {
    final rules = <Map<String, dynamic>>[
      {
        'type': 'field',
        'domain': aiDomains,
        'outboundTag': (warpEnabled ?? options.cloudflareWarp)
            ? 'warp'
            : 'direct',
      },
    ];

    // 1. бход .RU сайтов (если включен)
    if (options.bypassRuDomains) {
      rules.add({
        'type': 'field',
        'outboundTag': 'direct',
        'domain': ['domain:ru', 'domain:su', 'domain:xn--p1ai'],
      });
    }

    // 2. нти-Торрент (если включен)
    if (options.antiTorrent) {
      rules.add({
        'type': 'field',
        'protocol': ['bittorrent'],
        'outboundTag': 'blocked',
      });
    }

    // 3. AdBlock (если включен)
    if (options.adBlock) {
      rules.add({
        'type': 'field',
        'domain': ['geosite:category-ads-all'],
        'outboundTag': 'blocked',
      });
    }

    // 4. Cloudflare WARP (если включен) — только целевые домены,
    //    весь остальной трафик остаётся на "direct".
    if (warpEnabled ?? options.cloudflareWarp) {
      rules.add({
        'type': 'field',
        'domain': warpDomains,
        'outboundTag': 'warp',
      });
    }

    return rules;
  }

  /// Обновление базы данных x-ui.db с правилами маршрутизации.
  static Future<void> _updateXuiDatabase({
    required List<Map<String, dynamic>> rules,
    required bool warpEnabled,
    required String sshPassword,
    required bool isRoot,
    required Future<String> Function(String, String, bool) runCommand,
    required DeploymentOptions options,
  }) async {
    const dbPath = '/etc/x-ui/x-ui.db';

    // Полная конфигурация Xray: outbounds + routing.
    final xrayConfig = <String, dynamic>{
      'dns': _dnsConfig(),
      'outbounds': _buildOutbounds(options, warpEnabled: warpEnabled),
      'routing': {'domainStrategy': 'AsIs', 'rules': rules},
    };

    // JSON строится только через jsonEncode: все ключи и строки гарантированно
    // в двойных кавычках. Обратный разбор отсекает повреждённый результат
    // до того, как он попадёт в базу.
    final xrayJson = jsonEncode(xrayConfig);
    _validateTemplate(xrayJson);

    // Записываем в xrayTemplateConfig (3X-UI использует этот ключ).
    // SQL целиком уходит в base64, поэтому bash не может срезать двойные
    // кавычки вокруг ключей JSON ("outbounds", "outboundTag").
    await _runSqlViaBase64(
      sql: _templateUpsertSql(xrayJson),
      dbPath: dbPath,
      sshPassword: sshPassword,
      isRoot: isRoot,
      runCommand: runCommand,
    );

    // Проверяем сохранённое значение как JSON, а не как строку: только так
    // видно потерю кавычек ("outbounds" без кавычек ломает Xray).
    var persisted = await _readTemplate(
      dbPath: dbPath,
      sshPassword: sshPassword,
      isRoot: isRoot,
      runCommand: runCommand,
    );
    if (!_templateMatches(persisted, xrayJson)) {
      // Повторная запись: JSON кладём в отдельный файл и читаем его через
      // readfile(), так что он вообще не проходит через SQL-литерал.
      await _writeTemplateViaFile(
        json: xrayJson,
        dbPath: dbPath,
        sshPassword: sshPassword,
        isRoot: isRoot,
        runCommand: runCommand,
      );
      persisted = await _readTemplate(
        dbPath: dbPath,
        sshPassword: sshPassword,
        isRoot: isRoot,
        runCommand: runCommand,
      );
    }
    if (!_templateMatches(persisted, xrayJson)) {
      throw Exception(
        'xrayTemplateConfig не записан в $dbPath корректным JSON. '
        'Ответ sqlite3: ${persisted.trim().isEmpty ? '(пусто)' : persisted.trim()}',
      );
    }

    // Telegram-бот панели: токен, чат, авто-бэкап.
    if (options.tgBotToken != null && options.tgBotChatId != null) {
      await _configureTelegramBot(
        token: options.tgBotToken!,
        chatId: options.tgBotChatId!,
        sshPassword: sshPassword,
        isRoot: isRoot,
        runCommand: runCommand,
      );
    }

    await runCommand('systemctl restart x-ui', sshPassword, isRoot);
  }

  /// Проверяет, что шаблон Xray — валидный JSON с нужными разделами.
  static void _validateTemplate(String json) {
    final decoded = jsonDecode(json);
    if (decoded is! Map<String, dynamic> ||
        !decoded.containsKey('outbounds') ||
        !decoded.containsKey('routing')) {
      throw Exception('xrayTemplateConfig: сформирован некорректный JSON');
    }
  }

  /// SQL-запись шаблона. JSON попадает в базу как литерал с удвоенными
  /// одинарными кавычками, а весь скрипт передаётся в base64, поэтому bash
  /// не трогает ни двойные кавычки, ни переводы строк внутри JSON.
  static String _templateUpsertSql(String json) {
    final sqlJson = json.replaceAll("'", "''");
    return 'BEGIN;\n'
        "DELETE FROM settings WHERE key = 'xrayTemplateConfig';\n"
        "INSERT INTO settings (key, value) VALUES "
        "('xrayTemplateConfig', '$sqlJson');\n"
        'COMMIT;';
  }

  /// Читает сохранённый шаблон из базы.
  static Future<String> _readTemplate({
    required String dbPath,
    required String sshPassword,
    required bool isRoot,
    required Future<String> Function(String, String, bool) runCommand,
  }) {
    return _runSqlViaBase64(
      sql: "SELECT value FROM settings WHERE key = 'xrayTemplateConfig';",
      dbPath: dbPath,
      sshPassword: sshPassword,
      isRoot: isRoot,
      runCommand: runCommand,
    );
  }

  /// Writes JSON to a unique private file; only its generated path is expanded.
  static Future<void> _writeTemplateViaFile({
    required String json,
    required String dbPath,
    required String sshPassword,
    required bool isRoot,
    required Future<String> Function(String, String, bool) runCommand,
  }) async {
    final encoded = base64Encode(utf8.encode(json));
    await runCommand(
      '''
set -e
set -o pipefail
umask 077
MBX_TPL=\$(mktemp /tmp/mbx_tpl.XXXXXXXXXX) || exit 1
trap 'rm -f "\$MBX_TPL"' EXIT HUP INT TERM
printf '%s' '$encoded' | base64 -d > "\$MBX_TPL" || exit 1
/usr/bin/sqlite3 -bail ${ShellScripts.quote(dbPath)} <<MBX_SQL_EOF
BEGIN;
DELETE FROM settings WHERE key = 'xrayTemplateConfig';
INSERT INTO settings (key, value)
  VALUES ('xrayTemplateConfig', CAST(readfile('\$MBX_TPL') AS TEXT));
COMMIT;
MBX_SQL_EOF
''',
      sshPassword,
      isRoot,
    );
  }

  /// Сравнивает сохранённый шаблон с ожидаемым как JSON-объекты.
  /// Строка с потерянными кавычками не распарсится и сравнение не пройдёт.
  static bool _templateMatches(String persisted, String expected) {
    final trimmed = persisted.trim();
    if (trimmed.isEmpty) return false;
    try {
      final actual = jsonDecode(trimmed);
      final wanted = jsonDecode(expected);
      return jsonEncode(actual) == jsonEncode(wanted);
    } on FormatException {
      return false;
    }
  }

  /// Выполняет SQL через base64, чтобы bash не менял кавычки в JSON.
  /// Конвейер завернут в `bash -c`, поэтому sudo (если [runCommand] его
  /// добавляет при isRoot == false) действует на весь конвейер, а не только
  /// на `echo`. Base64 не содержит кавычек, `$` и обратных апострофов.
  static Future<String> _runSqlViaBase64({
    required String sql,
    required String dbPath,
    required String sshPassword,
    required bool isRoot,
    required Future<String> Function(String, String, bool) runCommand,
  }) {
    return runCommand(
      ShellScripts.sql(sql, dbPath: dbPath),
      sshPassword,
      isRoot,
    );
  }

  /// Список outbound-ов Xray.
  static List<Map<String, dynamic>> _buildOutbounds(
    DeploymentOptions options, {
    bool? warpEnabled,
  }) {
    final outbounds = <Map<String, dynamic>>[
      {
        'tag': 'direct',
        'protocol': 'freedom',
        // UseIPv4 исключает AAAA-записи и прямые IPv6-соединения,
        // которые обходили WARP и ломали доступ к Gemini.
        'settings': {'domainStrategy': 'UseIPv4'},
      },
      {'tag': 'blocked', 'protocol': 'blackhole', 'settings': {}},
    ];

    if (warpEnabled ?? options.cloudflareWarp) {
      outbounds.add(WarpService.outbound());
    }

    return outbounds;
  }

  /// Настройка Telegram-бота панели 3X-UI.
  static Future<void> _configureTelegramBot({
    required String token,
    required String chatId,
    required String sshPassword,
    required bool isRoot,
    required Future<String> Function(String, String, bool) runCommand,
  }) async {
    await runCommand(
      WarpService.telegramSql(token, chatId),
      sshPassword,
      isRoot,
    );
  }

  static String generateRoutingScript(DeploymentOptions options) {
    String encodeTemplate(bool warpEnabled) => base64Encode(
      utf8.encode(
        jsonEncode({
          'dns': _dnsConfig(),
          'outbounds': _buildOutbounds(options, warpEnabled: warpEnabled),
          'routing': {
            'domainStrategy': 'AsIs',
            'rules': _buildRoutingRules(options, warpEnabled: warpEnabled),
          },
        }),
      ),
    );
    final directEncoded = encodeTemplate(false);
    final encoded = encodeTemplate(options.cloudflareWarp);
    // Run in a separate shell: putting its set-e script directly in an if
    // would disable errexit inside it and hide registration/install failures.
    final warpStep = options.cloudflareWarp
        ? '''
if bash -c ${ShellScripts.quote(WarpService.installScript)}; then
  MBX_WARP_ENABLED=true
  MBX_CONFIG='$encoded'
else
  echo ${ShellScripts.quote(WarpService.failureWarning)} >&2
  MBX_WARP_ENABLED=false
  MBX_CONFIG='$directEncoded'
fi
'''
        : "MBX_WARP_ENABLED=false\nMBX_CONFIG='$directEncoded'\n";

    return '''
#!/bin/bash
set -e
set -o pipefail
$warpStep
DB_PATH="/etc/x-ui/x-ui.db"
umask 077
MBX_TPL=\$(mktemp /tmp/mbx_tpl.XXXXXXXXXX) || exit 1
trap 'rm -f "\$MBX_TPL"' EXIT HUP INT TERM
printf '%s' "\$MBX_CONFIG" | base64 -d > "\$MBX_TPL" || exit 1
/usr/bin/sqlite3 -bail "\$DB_PATH" <<MBX_SQL_EOF
BEGIN;
DELETE FROM settings WHERE key = 'xrayTemplateConfig';
INSERT INTO settings (key, value)
  VALUES ('xrayTemplateConfig', CAST(readfile('\$MBX_TPL') AS TEXT));
COMMIT;
MBX_SQL_EOF
systemctl restart x-ui
echo "равила применены: RU=${options.bypassRuDomains}, Торрент=${options.antiTorrent}, AdBlock=${options.adBlock}, WARP=\$MBX_WARP_ENABLED"
''';
  }
}
