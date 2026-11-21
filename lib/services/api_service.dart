import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

/// Сервис управления панелью 3X-UI.
///
/// Работает в двух режимах:
///  * HTTP API — обычный путь, если удалось получить токен;
///  * SQLite — резервный путь: прямой доступ к `/etc/x-ui/x-ui.db` по SSH.
///    Используется, когда панель не отдала токен (новые версии 3X-UI
///    с редиректами/самоподписанными сертификатами и т.п.),
///    чтобы развёртывание не прерывалось.
class ApiService {
  final String ipAddress;
  final int panelPort;
  final String basePath;
  final String apiToken;

  /// Колбэк выполнения shell-команд на сервере (SQLite-режим).
  final Future<String> Function(String command)? runCommand;

  /// Транспорт создаваемых Inbound: 'xhttp' (рекомендуется с 2026)
  /// или 'tcp' (классический RAW + Vision, ТСПУ его активно ловит).
  final String transport;

  /// Путь XHTTP (например `/a8f3c2d1`). Для TCP не используется.
  final String xhttpPath;

  /// Маскировка паддинга XHTTP (xPaddingObfsMode и т.д.), null — выключена.
  final Map<String, dynamic>? xhttpPadding;

  /// Flow клиента зависит от транспорта: Vision работает только поверх
  /// голого TCP. На XHTTP с flow Vision клиент не подключится.
  String get clientFlow => flowFor(transport);

  static String flowFor(String transport) =>
      transport == 'tcp' ? 'xtls-rprx-vision' : '';

  /// streamSettings для VLESS + Reality. [target] — куда Reality отдаёт
  /// «чужие» подключения: сайт-маска `домен:443` или локальный nginx
  /// `127.0.0.1:8443` в режиме self-steal.
  static Map<String, dynamic> realityStream({
    required String transport,
    required String sni,
    required String privateKey,
    required String publicKey,
    required String shortId,
    String fingerprint = 'firefox',
    String? target,
    String xhttpPath = '/',
    Map<String, dynamic>? xhttpPadding,
  }) {
    final dest = target ?? '$sni:443';
    return <String, dynamic>{
      'network': transport,
      'security': 'reality',
      'realitySettings': {
        'show': false,
        'xver': 0,
        'target': dest,
        'dest': dest,
        'serverNames': [sni],
        'privateKey': privateKey,
        'minClientVer': '',
        'maxClientVer': '',
        'maxTimediff': 0,
        'shortIds': [shortId, ''],
        'settings': {
          'publicKey': publicKey,
          'fingerprint': fingerprint,
          'serverName': '',
          'spiderX': '/',
        },
      },
      if (transport == 'tcp')
        'tcpSettings': {
          'acceptProxyProtocol': false,
          'header': {'type': 'none'},
        }
      else
        // Только path и mode: значения по умолчанию Xray не пишем,
        // одинаковые «литералы» во всех конфигах ТСПУ использует как отпечаток.
        'xhttpSettings': {
          'path': xhttpPath,
          'host': '',
          'mode': 'auto',
          ...?xhttpPadding,
        },
    };
  }

  late final String baseUrl;
  late final HttpClient _client;

  ApiService({
    required this.ipAddress,
    required this.panelPort,
    required this.basePath,
    required this.apiToken,
    this.runCommand,
    this.transport = 'tcp',
    this.xhttpPath = '/',
    this.xhttpPadding,
  }) {
    final normalizedPath = basePath.replaceAll(RegExp(r'^/+|/+$'), '');
    baseUrl = Uri(
      scheme: 'http',
      host: ipAddress,
      port: panelPort,
      path: normalizedPath.isEmpty ? '' : '/$normalizedPath',
    ).toString();
    _client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  }

  /// true, если API-токен получить не удалось и все операции идут
  /// напрямую через базу SQLite.
  bool get usesSqliteFallback => apiToken.isEmpty;

  static const String _dbPath = '/etc/x-ui/x-ui.db';

  /// Экранирование строки для одинарных кавычек SQL.
  static String _sqlQuote(String value) => "'${value.replaceAll("'", "''")}'";

  /// Запись SQL через временный файл и `sqlite3 db < file`,
  /// чтобы не воевать с экранированием кавычек в shell.
  Future<String> _runSql(String sql) async {
    if (runCommand == null) {
      throw Exception('SQLite-режим недоступен: не задан runCommand');
    }
    const marker = 'MBX_SQL_EOF';
    if (sql.split('\n').any((line) => line.trim() == marker)) {
      throw ArgumentError('SQL contains the heredoc delimiter');
    }
    final script =
        'umask 077\n'
        'MBX_SQL_FILE=\$(mktemp /tmp/mbx_api.XXXXXXXXXX) || exit 1\n'
        'trap \'rm -f "\$MBX_SQL_FILE"\' EXIT HUP INT TERM\n'
        "cat > \"\$MBX_SQL_FILE\" << '$marker'\n"
        '$sql\n'
        '$marker\n'
        '/usr/bin/sqlite3 -bail $_dbPath < "\$MBX_SQL_FILE" 2>&1\n'
        'MBX_SQL_RC=\$?\n'
        'echo "MBX_SQL_STATUS=\$MBX_SQL_RC"\n';
    final output = await runCommand!(script);
    final status = RegExp(r'MBX_SQL_STATUS=(\d+)').firstMatch(output);
    if (status != null && status.group(1) != '0') {
      throw StateError('SQLite execution failed (exit ${status.group(1)})');
    }
    return output.replaceAll(RegExp(r'MBX_SQL_STATUS=\d+\s*'), '');
  }

  /// Строки вывода `sqlite3`, содержащие ошибку (`Error:`, `Parse error`,
  /// `Runtime error`). null — ошибок нет.
  static String? _extractSqlError(String output) {
    final errorRe = RegExp('error', caseSensitive: false);
    final lines = output
        .split('\n')
        .map((String line) => line.trim())
        .where((String line) => line.isNotEmpty && errorRe.hasMatch(line))
        .toList();
    return lines.isEmpty ? null : lines.join('\n');
  }

  /// Как [_runSql], но при ошибке SQLite бросает Exception с её текстом.
  Future<String> _runSqlChecked(String sql, String action) async {
    final out = await _runSql(sql);
    final error = _extractSqlError(out);
    if (error != null) {
      throw Exception('SQLite: не удалось $action: $error');
    }
    return out;
  }

  /// Разбор числового id из вывода `sqlite3`.
  ///
  /// Вывод может содержать мусор (приглашение sudo, предупреждения),
  /// поэтому берём последнюю строку, которая целиком является числом.
  /// Если ничего не нашлось — возвращаем [fallback], чтобы развёртывание
  /// не прерывалось: в 3X-UI первый inbound почти всегда получает id = 1.
  static int _parseId(String output, {int fallback = 1}) {
    final numeric = output
        .split('\n')
        .map((String line) => line.trim())
        .where((String line) => RegExp(r'^\d+$').hasMatch(line))
        .toList();

    if (numeric.isEmpty) return fallback;

    final parsed = int.tryParse(numeric.last);
    if (parsed == null || parsed <= 0) return fallback;
    return parsed;
  }

  /// Известный набор колонок таблицы `inbounds` для современных 3X-UI
  /// (v2.4/v2.5). INSERT строится из тех колонок этого списка, которые
  /// реально есть в таблице; если схему прочитать не удалось — по всему списку.
  @visibleForTesting
  static const List<String> baselineInboundColumns = <String>[
    'user_id',
    'up',
    'down',
    'total',
    'remark',
    'enable',
    'expiry_time',
    'listen',
    'port',
    'protocol',
    'settings',
    'stream_settings',
    'tag',
    'sniffing',
  ];

  /// Разбор имён колонок из вывода `pragma_table_info` / `PRAGMA table_info`.
  ///
  /// Понимает строки `cid|name|type|...` и «одно имя в строке».
  /// Мусор (приглашение sudo, тексты ошибок sqlite3) отбрасывается.
  @visibleForTesting
  static List<String> parseTableColumns(String pragmaOutput) {
    final nameRe = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');
    final columns = <String>[];

    for (final line in pragmaOutput.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      if (trimmed.contains('|')) {
        final parts = trimmed.split('|');
        if (parts.length >= 2) {
          final name = parts[1].trim();
          if (nameRe.hasMatch(name)) columns.add(name);
        }
        continue;
      }

      if (nameRe.hasMatch(trimmed)) columns.add(trimmed);
    }

    return columns;
  }

  /// Строка для таблицы `client_traffics` (учёт трафика клиента).
  String _trafficInsertSql({
    required int inboundId,
    required String email,
    required int totalGb,
    required int expiryTime,
    required int enable,
  }) {
    return 'INSERT INTO client_traffics '
        '(inbound_id, enable, email, up, down, expiry_time, total, reset) '
        'VALUES ($inboundId, $enable, ${_sqlQuote(email)}, 0, 0, '
        '$expiryTime, $totalGb, 0);';
  }

  Future<Map<String, dynamic>> addVlessRealityInbound({
    required int port,
    required String publicKey,
    required String privateKey,
    required String shortId,
    required String uuid,
    required String sni,
    required String remark,
    String fingerprint = 'firefox',
    String? target,
  }) {
    return addOrUpdateVlessRealityInbound(
      port: port,
      publicKey: publicKey,
      privateKey: privateKey,
      shortId: shortId,
      uuid: uuid,
      sni: sni,
      remark: remark,
      fingerprint: fingerprint,
      target: target,
    );
  }

  Future<Map<String, dynamic>> addOrUpdateVlessRealityInbound({
    required int port,
    required String publicKey,
    required String privateKey,
    required String shortId,
    required String uuid,
    required String sni,
    required String remark,
    String fingerprint = 'firefox',
    String? target,
    int? inboundId,
  }) async {
    if (usesSqliteFallback) {
      return _sqliteAddInbound(
        port: port,
        publicKey: publicKey,
        privateKey: privateKey,
        shortId: shortId,
        uuid: uuid,
        sni: sni,
        remark: remark,
        fingerprint: fingerprint,
        target: target,
      );
    }

    final isUpdate = inboundId != null;
    final path = isUpdate
        ? '$baseUrl/panel/api/inbounds/update/$inboundId'
        : '$baseUrl/panel/api/inbounds/add';
    final uri = Uri.parse(path);
    final request = await _client.postUrl(uri);

    request.headers.set('Content-Type', 'application/json; charset=utf-8');
    request.headers.set('Authorization', 'Bearer $apiToken');

    final payload = {
      'enable': true,
      'port': port,
      'protocol': 'vless',
      'remark': remark,
      'tag': 'inbound-$port',
      'listen': '',
      'expiryTime': 0,
      'clientStats': '',
      'sniffing': json.encode({
        'enabled': true,
        'destOverride': ['http', 'tls', 'quic', 'fakedns'],
        'metadataOnly': false,
        'routeOnly': false,
      }),
      'allocate': json.encode({
        'strategy': 'always',
        'refresh': 5,
        'concurrency': 3,
      }),
      'settings': json.encode({
        'clients': [
          {
            'id': uuid,
            'flow': clientFlow,
            'email': '$remark-client',
            'totalGB': 0,
            'expiryTime': 0,
            'enable': true,
            'tgId': 0,
            'subId': '',
            'reset': 0,
          },
        ],
        'decryption': 'none',
        'fallbacks': [],
      }),
      'streamSettings': json.encode(
        realityStream(
          transport: transport,
          sni: sni,
          privateKey: privateKey,
          publicKey: publicKey,
          shortId: shortId,
          fingerprint: fingerprint,
          target: target,
          xhttpPath: xhttpPath,
          xhttpPadding: xhttpPadding,
        ),
      ),
    };

    request.write(json.encode(payload));

    final response = await request.close();
    final responseBody = await response.transform(utf8.decoder).join();

    if (response.statusCode != 200) {
      throw Exception(
        'Не удалось сохранить inbound: ${response.statusCode} $responseBody',
      );
    }

    final Map<String, dynamic> result =
        json.decode(responseBody) as Map<String, dynamic>;
    if (result['success'] != true) {
      throw Exception(
        'Ошибка API при сохранении inbound: ${result['msg'] ?? 'неизвестная ошибка'}',
      );
    }

    return result;
  }

  /// Резервное создание Inbound напрямую в базе 3X-UI.
  ///
  /// Формат `settings`/`streamSettings` повторяет то, что отправляет
  /// HTTP API выше, поэтому панель видит такой Inbound как обычный.
  Future<Map<String, dynamic>> _sqliteAddInbound({
    required int port,
    required String publicKey,
    required String privateKey,
    required String shortId,
    required String uuid,
    required String sni,
    required String remark,
    String fingerprint = 'firefox',
    String? target,
  }) async {
    final settings = json.encode({
      'clients': [
        {
          'id': uuid,
          'flow': clientFlow,
          'email': '$remark-client',
          'totalGB': 0,
          'expiryTime': 0,
          'enable': true,
          'tgId': 0,
          'subId': '',
          'reset': 0,
        },
      ],
      'decryption': 'none',
      'fallbacks': [],
    });

    final streamSettings = json.encode(
      realityStream(
        transport: transport,
        sni: sni,
        privateKey: privateKey,
        publicKey: publicKey,
        shortId: shortId,
        fingerprint: fingerprint,
        target: target,
        xhttpPath: xhttpPath,
        xhttpPadding: xhttpPadding,
      ),
    );

    final sniffing = json.encode({
      'enabled': true,
      'destOverride': ['http', 'tls', 'quic', 'fakedns'],
      'metadataOnly': false,
      'routeOnly': false,
    });

    // Значения для всех колонок из [baselineInboundColumns].
    final values = <String, String>{
      'user_id': '1',
      'up': '0',
      'down': '0',
      'total': '0',
      'remark': _sqlQuote(remark),
      'enable': '1',
      'expiry_time': '0',
      'listen': _sqlQuote(''),
      'port': '$port',
      'protocol': _sqlQuote('vless'),
      'settings': _sqlQuote(settings),
      'stream_settings': _sqlQuote(streamSettings),
      'tag': _sqlQuote('inbound-$port'),
      'sniffing': _sqlQuote(sniffing),
    };

    // Читаем реальные колонки таблицы. Первый запрос — для новых sqlite3,
    // PRAGMA — резерв для старых без pragma_table_info(). Ошибки sqlite3
    // в выводе (2>&1) парсер отбрасывает.
    final schemaOut = await _runSql(
      "SELECT name FROM pragma_table_info('inbounds');\n"
      'PRAGMA table_info(inbounds);',
    );
    final existing = parseTableColumns(schemaOut).toSet();
    var insertCols = baselineInboundColumns
        .where((String column) => existing.contains(column))
        .toList();
    // Схему прочитать не удалось — берём известный набор;
    // реальную причину покажет ошибка INSERT ниже.
    if (insertCols.isEmpty) {
      insertCols = List<String>.of(baselineInboundColumns);
    }

    final cols = insertCols.join(', ');
    final vals = insertCols.map((String column) => values[column]!).join(', ');
    final insert = 'INSERT INTO inbounds ($cols) VALUES ($vals);';

    // При повторном развёртывании inbound с этим портом/тегом уже есть,
    // и INSERT падает с UNIQUE constraint failed: inbounds.tag.
    // Старые записи (и их учёт трафика) удаляются в том же SQL-скрипте.
    final quotedTag = values['tag']!;
    final bindingColumns = parseTableColumns(
      await _runSql('PRAGMA table_info(client_inbounds);'),
    ).toSet();
    final bindingCleanup = bindingColumns.contains('inbound_id')
        ? 'DELETE FROM client_inbounds WHERE inbound_id IN '
              '(SELECT id FROM inbounds WHERE port = $port OR tag = $quotedTag);\n'
        : '';
    final cleanup =
        '$bindingCleanup'
        'DELETE FROM client_traffics WHERE inbound_id IN '
        '(SELECT id FROM inbounds WHERE port = $port OR tag = $quotedTag);\n'
        'DELETE FROM inbounds WHERE port = $port OR tag = $quotedTag;';

    // INSERT и чтение id идут ОДНИМ скриптом. Отдельный вызов
    // `SELECT last_insert_rowid();` здесь не работает: каждый запуск
    // sqlite3 — это новое соединение, а last_insert_rowid() привязан
    // к соединению и в свежем процессе всегда вернёт 0.
    // Порт уникален для inbound, поэтому ищем запись по нему;
    // max(id) — на случай, если inbound с таким портом уже существовал.
    final out = await _runSqlChecked(
      'BEGIN IMMEDIATE;\n'
          '$cleanup\n'
          '$insert\n'
          'SELECT max(id) FROM inbounds WHERE port = $port;\n'
          'COMMIT;',
      'создать inbound',
    );

    // Молчаливого id = 1 больше нет: без числового id вставка не удалась.
    final newId = _parseId(out, fallback: 0);
    if (newId <= 0) {
      throw Exception(
        'SQLite: inbound не создан, sqlite3 не вернул id. '
        'Вывод: ${out.trim().isEmpty ? '(пусто)' : out.trim()}',
      );
    }

    // Учёт трафика создаётся для каждого клиента, иначе панель
    // не покажет статистику и не применит лимиты.
    final normalized = await _normalizedClientSql(
      inboundId: newId,
      uuid: uuid,
      email: '$remark-client',
      limitIp: 0,
      totalGb: 0,
      expiryTime: 0,
    );
    await _runSqlChecked(
      'BEGIN IMMEDIATE;\n$normalized${_trafficInsertSql(inboundId: newId, email: '$remark-client', totalGb: 0, expiryTime: 0, enable: 1)}\nCOMMIT;',
      'создать клиента, привязку и запись client_traffics',
    );

    return <String, dynamic>{
      'success': true,
      'msg': 'inbound добавлен через SQLite',
      'obj': <String, dynamic>{'id': newId, 'port': port},
    };
  }

  Future<String> getShareLink(int inboundId) async {
    if (usesSqliteFallback) {
      throw Exception(
        'Ссылки недоступны в SQLite-режиме: панель не отдала API-токен',
      );
    }

    final uri = Uri.parse('$baseUrl/panel/api/inbounds/allLinks?id=$inboundId');
    final request = await _client.getUrl(uri);

    request.headers.set('Authorization', 'Bearer $apiToken');

    final response = await request.close();
    final responseBody = await response.transform(utf8.decoder).join();

    if (response.statusCode != 200) {
      throw Exception('Не удалось получить ссылку: ${response.statusCode}');
    }

    final Map<String, dynamic> result =
        json.decode(responseBody) as Map<String, dynamic>;
    if (result['success'] != true) {
      throw Exception(
        'Ошибка API при получении ссылки: ${result['msg'] ?? 'неизвестная ошибка'}',
      );
    }

    final obj = result['obj'] as Map<String, dynamic>?;
    if (obj == null || obj.isEmpty) {
      throw Exception('Ссылки не вернулись');
    }

    // Return first client link
    final links = obj.values.first as List<dynamic>?;
    if (links == null || links.isEmpty) {
      throw Exception('Список ссылок клиента пуст');
    }

    return links[0] as String;
  }

  Future<Map<String, dynamic>> addClientToInbound({
    required int inboundId,
    required String uuid,
    required String email,
    required int limitIp,
    required int totalGb,
    int? expiryTime, // НОВОЕ: срок истечения в миллисекундах
  }) async {
    if (usesSqliteFallback) {
      return _sqliteAddClient(
        inboundId: inboundId,
        uuid: uuid,
        email: email,
        limitIp: limitIp,
        totalGb: totalGb,
        expiryTime: expiryTime ?? 0,
      );
    }

    final path = '$baseUrl/panel/api/inbounds/addClient';
    final uri = Uri.parse(path);
    final request = await _client.postUrl(uri);

    request.headers.set('Content-Type', 'application/json; charset=utf-8');
    request.headers.set('Authorization', 'Bearer $apiToken');

    final payload = {
      'id': inboundId,
      'settings': jsonEncode({
        'clients': [
          {
            'id': uuid,
            'flow': clientFlow,
            'email': email,
            'limitIp': limitIp,
            'totalGB': totalGb,
            'expiryTime': expiryTime ?? 0, // НОВОЕ: используем параметр
            'enable': true,
            'tgId': 0,
            'subId': '',
            'reset': 0,
          },
        ],
      }),
    };

    request.write(jsonEncode(payload));

    final response = await request.close();
    final responseBody = await response.transform(utf8.decoder).join();

    if (response.statusCode != 200) {
      throw Exception(
        'Не удалось добавить клиента: ${response.statusCode} $responseBody',
      );
    }

    final Map<String, dynamic> result =
        jsonDecode(responseBody) as Map<String, dynamic>;
    if (result['success'] != true) {
      throw Exception(
        'Ошибка API при добавлении клиента: ${result['msg'] ?? 'неизвестная ошибка'}',
      );
    }

    return result;
  }

  /// Резервное добавление клиента напрямую в базу 3X-UI:
  /// клиент дописывается в `settings.clients` через `json_set`,
  /// а учёт трафика — новым рядком в `client_traffics`.
  ///
  /// Поле `totalGB` (не `totalGb`!) и `limitIp` обязательны,
  /// чтобы панель корректно отбирала клиентов на счёт/лимиты.
  Future<Map<String, dynamic>> _sqliteAddClient({
    required int inboundId,
    required String uuid,
    required String email,
    required int limitIp,
    required int totalGb,
    required int expiryTime,
  }) async {
    final clientJson = json.encode({
      'id': uuid,
      'flow': clientFlow,
      'email': email,
      'limitIp': limitIp,
      'totalGB': totalGb,
      'expiryTime': expiryTime,
      'enable': true,
      'tgId': 0,
      'subId': '',
      'reset': 0,
    });

    // json_set с json_array_length добавляет элемент в конец массива clients.
    final update =
        'UPDATE inbounds SET settings = json_set('
        'settings, '
        "'\$.clients[' || json_array_length(settings, '\$.clients') || ']', "
        'json(${_sqlQuote(clientJson)})'
        ') WHERE id = $inboundId;';

    final normalized = await _normalizedClientSql(
      inboundId: inboundId,
      uuid: uuid,
      email: email,
      limitIp: limitIp,
      totalGb: totalGb,
      expiryTime: expiryTime,
    );
    final traffic = _trafficInsertSql(
      inboundId: inboundId,
      email: email,
      totalGb: totalGb,
      expiryTime: expiryTime,
      enable: 1,
    );
    await _runSqlChecked(
      'BEGIN IMMEDIATE;\n$update\n$normalized$traffic\nCOMMIT;',
      'добавить клиента и его привязку/учёт трафика',
    );

    return <String, dynamic>{
      'success': true,
      'msg': 'клиент добавлен через SQLite',
      'obj': <String, dynamic>{'id': inboundId, 'email': email},
    };
  }

  /// Detect authoritative client tables used by newer 3X-UI versions.
  Future<String> _normalizedClientSql({
    required int inboundId,
    required String uuid,
    required String email,
    required int limitIp,
    required int totalGb,
    required int expiryTime,
  }) async {
    final clientColumns = parseTableColumns(
      await _runSql('PRAGMA table_info(clients);'),
    ).toSet();
    final bindingColumns = parseTableColumns(
      await _runSql('PRAGMA table_info(client_inbounds);'),
    ).toSet();
    if (clientColumns.isEmpty && bindingColumns.isEmpty) return '';
    if (!clientColumns.containsAll(['id', 'email', 'uuid', 'flow']) ||
        !bindingColumns.containsAll(['client_id', 'inbound_id'])) {
      throw StateError('Unsupported or incomplete 3X-UI client schema');
    }
    final values = <String, String>{
      'email': _sqlQuote(email),
      'uuid': _sqlQuote(uuid),
      'flow': _sqlQuote(clientFlow),
      'limit_ip': '$limitIp',
      'total_gb': '$totalGb',
      'expiry_time': '$expiryTime',
      'enable': '1',
      'tg_id': '0',
      'sub_id': _sqlQuote(''),
      'password': _sqlQuote(''),
      'auth': _sqlQuote(''),
      'security': _sqlQuote(''),
      'reset': '0',
      'created_at': '0',
      'updated_at': '0',
    };
    final cols = values.keys.where(clientColumns.contains).toList();
    final assignments = cols
        .where((c) => c != 'email')
        .map((c) => '$c = ${values[c]}')
        .join(', ');
    final binding = <String, String>{
      'client_id': '(SELECT id FROM clients WHERE email = ${_sqlQuote(email)})',
      'inbound_id': '$inboundId',
      'flow_override': _sqlQuote(clientFlow),
      'created_at': '0',
    };
    final bindCols = binding.keys.where(bindingColumns.contains).toList();
    // Старые версии 3X-UI хранят клиентов только в inbounds.settings.
    if (cols.isEmpty && bindCols.isEmpty) return '';
    final buffer = StringBuffer();
    if (cols.isNotEmpty) {
      buffer.writeln(
        'INSERT INTO clients (${cols.join(', ')}) '
        'SELECT ${cols.map((c) => values[c]).join(', ')} '
        'WHERE NOT EXISTS (SELECT 1 FROM clients WHERE email = ${_sqlQuote(email)});',
      );
      if (assignments.isNotEmpty) {
        buffer.writeln(
          'UPDATE clients SET $assignments WHERE email = ${_sqlQuote(email)};',
        );
      }
    }
    if (bindCols.isNotEmpty) {
      buffer.writeln(
        'DELETE FROM client_inbounds WHERE client_id = ${binding['client_id']} '
        'AND inbound_id = $inboundId;',
      );
      buffer.writeln(
        'INSERT INTO client_inbounds (${bindCols.join(', ')}) '
        'VALUES (${bindCols.map((c) => binding[c]).join(', ')});',
      );
    }
    return buffer.toString();
  }

  /// Bind one UUID to all ports, avoiding legacy global traffic-email conflicts.
  Future<void> addClientToInbounds({
    required List<int> inboundIds,
    required String uuid,
    required String email,
    required int limitIp,
    required int totalGb,
    int? expiryTime,
  }) async {
    if (inboundIds.isEmpty || inboundIds.any((id) => id <= 0)) {
      throw ArgumentError.value(inboundIds, 'inboundIds');
    }
    for (final id in inboundIds.toSet()) {
      await addClientToInbound(
        inboundId: id,
        uuid: uuid,
        email: id == inboundIds.first ? email : '$email-inbound-$id',
        limitIp: limitIp,
        totalGb: totalGb,
        expiryTime: expiryTime,
      );
    }
  }

  void dispose() {
    _client.close();
  }
}
