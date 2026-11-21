import 'package:flutter_test/flutter_test.dart';
import 'package:megabox_server_creator/services/api_service.dart';

/// Проверка SQLite-фолбэка: ApiService в режиме без токена должен
/// генерировать корректный SQL вместо HTTP-запросов.
void main() {
  late List<String> sent;

  ApiService build(String token, {String idOutput = '7\n'}) {
    sent = <String>[];
    return ApiService(
      ipAddress: '10.0.0.1',
      panelPort: 2053,
      basePath: 'admin-1',
      apiToken: token,
      runCommand: (String cmd) async {
        sent.add(cmd);
        // sqlite3 отдаёт id в том же вызове, что и INSERT.
        if (cmd.contains('SELECT max(id)')) return idOutput;
        return '';
      },
    );
  }

  test('пустой токен включает SQLite-режим', () {
    expect(build('').usesSqliteFallback, isTrue);
    expect(build('real-token').usesSqliteFallback, isFalse);
  });

  test('Inbound пишется в таблицу inbounds с REALITY-настройками', () async {
    final api = build('');

    final result = await api.addVlessRealityInbound(
      port: 443,
      publicKey: 'PUBKEY',
      privateKey: 'PRIVKEY',
      shortId: 'abcd1234',
      uuid: '11111111-2222-3333-4444-555555555555',
      sni: 'www.microsoft.com',
      remark: 'Test',
    );

    expect(result['success'], isTrue);

    final sql = sent.join('\n');

    // Таблица и ключевые поля.
    expect(sql, contains('INSERT INTO inbounds'));
    expect(sql, contains("'vless'"));
    expect(sql, contains('443'));
    expect(sql, contains("'Test'"));

    // REALITY-параметры попали в stream_settings.
    expect(sql, contains('"security":"reality"'));
    expect(sql, contains('"privateKey":"PRIVKEY"'));
    expect(sql, contains('"publicKey":"PUBKEY"'));
    expect(sql, contains('"dest":"www.microsoft.com:443"'));
    expect(sql, contains('"shortIds":["abcd1234",""]'));

    // Учёт трафика создан для основного клиента.
    expect(sql, contains('INSERT INTO client_traffics'));

    // SQL передаётся через heredoc, а не клеится в одну строку shell.
    expect(sql, contains("cat > \"\$MBX_SQL_FILE\" << 'MBX_SQL_EOF'"));
    expect(sql, contains('/usr/bin/sqlite3 -bail /etc/x-ui/x-ui.db'));
    expect(sql, contains('mktemp /tmp/mbx_api.XXXXXXXXXX'));
  });

  test('одинарная кавычка в remark экранируется удвоением', () async {
    final api = build('');

    await api.addVlessRealityInbound(
      port: 443,
      publicKey: 'P',
      privateKey: 'S',
      shortId: 'sid',
      uuid: 'uuid',
      sni: 'example.com',
      remark: "O'Brien's server",
    );

    final sql = sent.join('\n');
    expect(sql, contains("'O''Brien''s server'"));
    // Разорванной строки быть не должно.
    expect(sql, isNot(contains("'O'Brien's server'")));
  });

  test('клиент дописывается в settings.clients через json_set', () async {
    final api = build('');

    await api.addClientToInbound(
      inboundId: 3,
      uuid: '22222222-3333-4444-5555-666666666666',
      email: 'friend-ivan',
      limitIp: 0,
      totalGb: 1073741824,
      expiryTime: 1893456000000,
    );

    final sql = sent.join('\n');

    expect(sql, contains('UPDATE inbounds SET settings = json_set('));
    expect(sql, contains("json_array_length(settings, '\$.clients')"));
    expect(sql, contains('WHERE id = 3;'));
    expect(sql, contains('"email":"friend-ivan"'));
    expect(sql, contains('"expiryTime":1893456000000'));

    // Трафик для нового клиента тоже создан, с тем же сроком.
    expect(sql, contains('INSERT INTO client_traffics'));
    expect(sql, contains('1893456000000'));
  });

  test('id читается тем же вызовом, что и INSERT', () async {
    final api = build('');

    final result = await api.addVlessRealityInbound(
      port: 8443,
      publicKey: 'P',
      privateKey: 'S',
      shortId: 'sid',
      uuid: 'uuid',
      sni: 'example.com',
      remark: 'Backup',
    );

    final obj = result['obj'] as Map<String, dynamic>;
    expect(obj['id'], 7);
    expect(obj['port'], 8443);

    // Главное: INSERT и SELECT ушли одной командой, иначе id потеряется —
    // каждый запуск sqlite3 это новое соединение.
    final insertCmd = sent.firstWhere(
      (String c) => c.contains('INSERT INTO inbounds'),
    );
    expect(
      insertCmd,
      contains('SELECT max(id) FROM inbounds WHERE port = 8443;'),
    );

    // last_insert_rowid() больше не используется: в новом процессе он даёт 0.
    expect(sent.join('\n'), isNot(contains('last_insert_rowid')));
  });

  test('пустой вывод sqlite3 — явная ошибка, а не молчаливый id = 1', () async {
    final api = build('', idOutput: '');

    expect(
      () => api.addVlessRealityInbound(
        port: 443,
        publicKey: 'P',
        privateKey: 'S',
        shortId: 'sid',
        uuid: 'uuid',
        sni: 'example.com',
        remark: 'Main',
      ),
      throwsA(isA<Exception>()),
    );
  });

  test('мусор в выводе отфильтровывается, берётся число', () async {
    // Типичный случай: приглашение sudo и предупреждение перед ответом.
    final api = build(
      '',
      idOutput:
          '[sudo] password for user:\n'
          'Warning: cannot open history file\n'
          '12\n',
    );

    final result = await api.addVlessRealityInbound(
      port: 443,
      publicKey: 'P',
      privateKey: 'S',
      shortId: 'sid',
      uuid: 'uuid',
      sni: 'example.com',
      remark: 'Main',
    );

    expect((result['obj'] as Map<String, dynamic>)['id'], 12);
  });

  test('нечисловой и нулевой вывод — исключение с текстом SQLite', () async {
    for (final bad in <String>['NULL\n', 'Error: no such table\n', '0\n']) {
      final api = build('', idOutput: bad);

      expect(
        () => api.addVlessRealityInbound(
          port: 443,
          publicKey: 'P',
          privateKey: 'S',
          shortId: 'sid',
          uuid: 'uuid',
          sni: 'example.com',
          remark: 'Main',
        ),
        throwsA(isA<Exception>()),
        reason: 'вывод "$bad" не должен давать id',
      );
    }
  });

  test('getShareLink в SQLite-режиме даёт понятную ошибку, а не падение', () {
    final api = build('');
    expect(
      () => api.getShareLink(1),
      throwsA(
        isA<Exception>().having(
          (Exception e) => e.toString(),
          'message',
          contains('SQLite-режиме'),
        ),
      ),
    );
  });

  test('без runCommand SQLite-режим честно сообщает об ошибке', () {
    final api = ApiService(
      ipAddress: '10.0.0.1',
      panelPort: 2053,
      basePath: 'admin-1',
      apiToken: '',
    );

    expect(
      () => api.addClientToInbound(
        inboundId: 1,
        uuid: 'uuid',
        email: 'x',
        limitIp: 0,
        totalGb: 0,
      ),
      throwsA(
        isA<Exception>().having(
          (Exception e) => e.toString(),
          'message',
          contains('runCommand'),
        ),
      ),
    );
  });

  group('фиксированный набор колонок inbounds', () {
    test('набор колонок соответствует схеме 3X-UI v2.4/v2.5', () {
      expect(ApiService.baselineInboundColumns, <String>[
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
      ]);
    });

    test('INSERT по известному набору колонок, если схема не прочитана', () async {
      final api = build('');

      await api.addVlessRealityInbound(
        port: 443,
        publicKey: 'P',
        privateKey: 'S',
        shortId: 'sid',
        uuid: 'uuid',
        sni: 'example.com',
        remark: 'Main',
      );

      final insert = sent.firstWhere(
        (String c) => c.contains('INSERT INTO inbounds'),
      );
      expect(
        insert,
        contains(
          'INSERT INTO inbounds (${ApiService.baselineInboundColumns.join(', ')}) VALUES (',
        ),
      );
      // Вывод ошибок sqlite3 перехватывается.
      expect(
        insert,
        contains(
          '/usr/bin/sqlite3 -bail /etc/x-ui/x-ui.db < "\$MBX_SQL_FILE" 2>&1',
        ),
      );
    });

    test('INSERT строится только из реально существующих колонок', () async {
      sent = <String>[];
      final api = ApiService(
        ipAddress: '10.0.0.1',
        panelPort: 2053,
        basePath: 'admin-1',
        apiToken: '',
        runCommand: (String cmd) async {
          sent.add(cmd);
          if (cmd.contains('pragma_table_info')) {
            return 'user_id\nup\ndown\ntotal\nremark\nenable\nexpiry_time\n'
                'listen\nport\nprotocol\nsettings\nstream_settings\ntag\n';
          }
          if (cmd.contains('SELECT max(id)')) return '3\n';
          return '';
        },
      );

      await api.addVlessRealityInbound(
        port: 443,
        publicKey: 'P',
        privateKey: 'S',
        shortId: 'sid',
        uuid: 'uuid',
        sni: 'example.com',
        remark: 'Main',
      );

      final insert = sent.firstWhere(
        (String c) => c.contains('INSERT INTO inbounds'),
      );
      expect(insert, contains('stream_settings'));
      expect(insert, isNot(contains('sniffing')));
    });

    test('ошибка SQLite при INSERT — Exception с её текстом', () async {
      final api = ApiService(
        ipAddress: '10.0.0.1',
        panelPort: 2053,
        basePath: 'admin-1',
        apiToken: '',
        runCommand: (String cmd) async {
          if (cmd.contains('INSERT INTO inbounds')) {
            return 'Error: near line 1: UNIQUE constraint failed: inbounds.tag\n';
          }
          return '';
        },
      );

      expect(
        () => api.addVlessRealityInbound(
          port: 443,
          publicKey: 'P',
          privateKey: 'S',
          shortId: 'sid',
          uuid: 'uuid',
          sni: 'example.com',
          remark: 'Main',
        ),
        throwsA(
          isA<Exception>().having(
            (Exception e) => e.toString(),
            'message',
            contains('UNIQUE constraint failed'),
          ),
        ),
      );
    });

    test('клиент inbound: flow, enable и запись в client_traffics', () async {
      final api = build('');

      await api.addVlessRealityInbound(
        port: 443,
        publicKey: 'P',
        privateKey: 'S',
        shortId: 'sid',
        uuid: 'uuid',
        sni: 'example.com',
        remark: 'Main',
      );

      final sql = sent.join('\n');
      expect(sql, contains('"flow":"xtls-rprx-vision"'));
      expect(sql, contains('"enable":true'));
      expect(sql, contains('INSERT INTO client_traffics'));
    });
  });
}
