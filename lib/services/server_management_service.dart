import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dartssh2/dartssh2.dart';

import 'host_key_store.dart';
import '../models/server_config.dart';
import 'remote_executor.dart';
import 'shell_scripts.dart';
import 'api_service.dart';
import 'ssh_service.dart';
import '../widgets/client_policy_selector.dart';

/// Сервис для живого мониторинга и управления развернутыми серверами
class ServerManagementService {
  final Future<String> Function(String, String, bool)? commandRunner;
  ServerManagementService({this.commandRunner});
  SSHClient? _client;
  final StreamController<String> _logController =
      StreamController<String>.broadcast();

  Stream<String> get logStream => _logController.stream;

  void dispose() {
    _logController.close();
    _client?.close();
  }

  void _log(String message) {
    _logController.add(message);
  }

  void disconnect() {
    _client?.close();
    _client = null;
  }

  /// Подключение к серверу по SSH
  Future<void> connectSSH(ServerConfig config) async {
    disconnect();
    try {
      final socket = await SSHSocket.connect(
        config.ipAddress,
        config.sshPort,
        timeout: const Duration(seconds: 10),
      );

      _client = SSHClient(
        socket,
        username: config.sshUser,
        onPasswordRequest: () => config.sshPassword,
        onVerifyHostKey: HostKeyStore.verifier(config.ipAddress, config.sshPort),
        onUserInfoRequest: (SSHUserInfoRequest request) =>
            request.prompts.map((SSHUserInfoPrompt _) => config.sshPassword).toList(),
      );

      _log('✅ Подключено к ${config.ipAddress}');
    } catch (e) {
      _log('❌ Ошибка подключения: $e');
      rethrow;
    }
  }

  /// Получение живой статистики сервера одним SSH-запросом:
  /// CPU (по дельте /proc/stat), RAM, диск, load average, сеть,
  /// статус x-ui, соединения и трафик каждого клиента из базы 3X-UI.
  Future<ServerLiveStats> getServerStats(String password, bool isRoot) async {
    if (_client == null) throw Exception('SSH не подключен');

    try {
      const script = r"""
read -r _ u1 n1 s1 i1 w1 q1 sq1 st1 _ < /proc/stat
sleep 0.5
read -r _ u2 n2 s2 i2 w2 q2 sq2 st2 _ < /proc/stat
T=$(( (u2+n2+s2+i2+w2+q2+sq2+st2) - (u1+n1+s1+i1+w1+q1+sq1+st1) ))
I=$(( (i2+w2) - (i1+w1) ))
[ "$T" -gt 0 ] && echo "cpu=$(( (T-I)*1000/T ))" || echo "cpu=0"
free -m | awk 'NR==2{print "ram_used="$3; print "ram_total="$2}'
df -P / | awk 'NR==2{gsub("%","",$5); print "disk="$5; print "disk_used_kb="$3; print "disk_total_kb="$2}'
echo "load=$(cut -d' ' -f1-3 /proc/loadavg)"
echo "cores=$(nproc 2>/dev/null || echo 1)"
echo "uptime=$(uptime -p 2>/dev/null)"
echo "xui=$(systemctl is-active x-ui 2>/dev/null || echo inactive)"
echo "conns=$(ss -Htn state established 2>/dev/null | grep -cE ':(443|8443) ')"
IF=$(ip route show default 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')
if [ -n "$IF" ] && [ -r /sys/class/net/$IF/statistics/rx_bytes ]; then
  echo "rx=$(cat /sys/class/net/$IF/statistics/rx_bytes)"
  echo "tx=$(cat /sys/class/net/$IF/statistics/tx_bytes)"
fi
if command -v sqlite3 >/dev/null 2>&1 && [ -r /etc/x-ui/x-ui.db ]; then
  sqlite3 -separator '|' /etc/x-ui/x-ui.db \
    "SELECT 'client', email, up, down, total, expiry_time, enable FROM client_traffics ORDER BY (up+down) DESC LIMIT 50;" 2>/dev/null
fi
true
""";
      final out = await _runCommand(script, password, isRoot);
      return ServerLiveStats.parse(out);
    } catch (e) {
      _log('❌ Ошибка получения статистики: $e');
      rethrow;
    }
  }

  /// Перезапуск Xray
  Future<void> restartXray(String password, bool isRoot) async {
    if (_client == null) throw Exception('SSH не подключен');

    try {
      _log('🔄 Перезапуск x-ui...');
      await _runCommand('systemctl restart x-ui', password, isRoot);
      await Future.delayed(const Duration(seconds: 2));

      final status = await _runCommand(
        'systemctl is-active x-ui',
        password,
        isRoot,
      );
      if (status.trim() == 'active') {
        _log('✅ x-ui успешно перезапущен');
      } else {
        throw Exception('x-ui не запустился после перезапуска');
      }
    } catch (e) {
      _log('❌ Ошибка перезапуска: $e');
      rethrow;
    }
  }

  /// Удаление 3X-UI с сервера
  Future<void> removeXui(String password, bool isRoot) async {
    if (_client == null) throw Exception('SSH не подключен');

    try {
      _log('🗑️ Удаление 3X-UI...');

      final removeScript = '''
systemctl stop x-ui 2>/dev/null || true
systemctl disable x-ui 2>/dev/null || true
rm -rf /usr/local/x-ui
rm -rf /etc/x-ui
rm -f /etc/systemd/system/x-ui.service
systemctl daemon-reload
''';

      await _runCommand(removeScript, password, isRoot);
      _log('✅ 3X-UI удалена');
    } catch (e) {
      _log('❌ Ошибка удаления: $e');
      rethrow;
    }
  }

  /// Скачивание бэкапа базы x-ui.db на ПК
  Future<void> downloadBackup(
    String password,
    bool isRoot,
    String localPath,
  ) async {
    if (_client == null) throw Exception('SSH не подключен');

    try {
      _log('💾 Скачивание бэкапа базы...');

      final tempBackup =
          '/tmp/x-ui-backup-${DateTime.now().millisecondsSinceEpoch}.db';
      await _runCommand('cp /etc/x-ui/x-ui.db $tempBackup', password, isRoot);
      await _runCommand('chmod 644 $tempBackup', password, isRoot);

      final sftp = await _client!.sftp();
      final remoteFile = await sftp.open(tempBackup);

      final localFile = File(localPath);
      final sink = localFile.openWrite();

      await for (final chunk in remoteFile.read()) {
        sink.add(chunk);
      }

      await sink.close();
      await remoteFile.close();

      await _runCommand('rm -f $tempBackup', password, isRoot);

      _log('✅ Бэкап сохранен: $localPath');
    } catch (e) {
      _log('❌ Ошибка скачивания бэкапа: $e');
      rethrow;
    }
  }

  /// Загрузка бэкапа на новый сервер (для миграции)
  Future<void> uploadBackup(
    String password,
    bool isRoot,
    String localPath,
  ) async {
    if (_client == null) throw Exception('SSH не подключен');

    try {
      _log('📤 Загрузка бэкапа на сервер...');

      final tempPath =
          '/tmp/x-ui-restore-${DateTime.now().millisecondsSinceEpoch}.db';

      final sftp = await _client!.sftp();
      final remoteFile = await sftp.open(
        tempPath,
        mode: SftpFileOpenMode.create | SftpFileOpenMode.write,
      );

      final localFile = File(localPath);
      final bytes = await localFile.readAsBytes();
      await remoteFile.writeBytes(bytes);
      await remoteFile.close();

      await _runCommand('systemctl stop x-ui', password, isRoot);
      await _runCommand('cp $tempPath /etc/x-ui/x-ui.db', password, isRoot);
      await _runCommand('chmod 600 /etc/x-ui/x-ui.db', password, isRoot);
      await _runCommand('chown root:root /etc/x-ui/x-ui.db', password, isRoot);
      await _runCommand('rm -f $tempPath', password, isRoot);
      await _runCommand('systemctl start x-ui', password, isRoot);

      _log('✅ База восстановлена и x-ui перезапущен');
    } catch (e) {
      _log('❌ Ошибка загрузки бэкапа: $e');
      rethrow;
    }
  }

  /// Переезд на новый VPS в 1 клик:
  /// скачивает базу со старого сервера, ставит 3X-UI на новый,
  /// переносит базу со всеми UUID и выдаёт новые vless:// ссылки.
  Future<List<String>> migrateServer({
    required String oldPassword,
    required String newIp,
    required int newPort,
    required String newUser,
    required String newPassword,
  }) async {
    _log('🚀 Начинаю переезд на $newIp:$newPort...');

    // 1. Скачиваем базу со старого сервера во временный файл
    final tempLocal = File(
      '${Directory.systemTemp.path}/x-ui-migrate-${DateTime.now().millisecondsSinceEpoch}.db',
    );

    await downloadBackup(oldPassword, true, tempLocal.path);
    _log('✅ База скачана со старого сервера');

    // 2. Подключаемся к новому серверу
    final socket = await SSHSocket.connect(
      newIp,
      newPort,
      timeout: const Duration(seconds: 15),
    );
    final newClient = SSHClient(
      socket,
      username: newUser,
      onPasswordRequest: () => newPassword,
      onVerifyHostKey: HostKeyStore.verifier(newIp, newPort),
      onUserInfoRequest: (SSHUserInfoRequest request) =>
          request.prompts.map((SSHUserInfoPrompt _) => newPassword).toList(),
    );

    Future<String> runOnNew(String cmd) => RemoteExecutor.run(newClient, cmd);

    try {
      // 3. Устанавливаем 3X-UI на новый сервер
      _log('📦 Установка 3X-UI на новый сервер...');
      await runOnNew('''
cd /tmp
rm -f xui_install.sh
curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh -o xui_install.sh
chmod +x xui_install.sh
bash /tmp/xui_install.sh
''');
      await Future.delayed(const Duration(seconds: 8));

      // 4. Загружаем базу через SFTP
      _log('📤 Перенос базы x-ui.db со всеми ключами...');
      final sftp = await newClient.sftp();
      final remotePath = '/tmp/x-ui-migrate.db';
      final remoteFile = await sftp.open(
        remotePath,
        mode: SftpFileOpenMode.create | SftpFileOpenMode.write,
      );
      await remoteFile.writeBytes(await tempLocal.readAsBytes());
      await remoteFile.close();

      await runOnNew('''
systemctl stop x-ui 2>/dev/null || true
mkdir -p /etc/x-ui
cp /tmp/x-ui-migrate.db /etc/x-ui/x-ui.db
chmod 600 /etc/x-ui/x-ui.db
chown root:root /etc/x-ui/x-ui.db
rm -f /tmp/x-ui-migrate.db
systemctl start x-ui
systemctl enable x-ui
''');
      await Future.delayed(const Duration(seconds: 4));

      // 5. Читаем ключи с нового сервера и формируем ссылки с новым IP
      _log('🔗 Формирование обновлённых ссылок...');
      final sftpNew = await newClient.sftp();
      final dbFile = await sftpNew.open('/etc/x-ui/x-ui.db');
      final bytes = <int>[];
      await for (final chunk in dbFile.read()) {
        bytes.addAll(chunk);
      }
      await dbFile.close();

      final links = _extractLinksFromDbBytes(bytes, newIp);
      _log('✅ Переезд завершён, ключей перенесено: ${links.length}');
      return links;
    } catch (e) {
      _log('❌ Ошибка переезда: $e');
      rethrow;
    } finally {
      newClient.close();
      if (tempLocal.existsSync()) {
        try {
          tempLocal.deleteSync();
        } catch (_) {
          // игнорируем ошибку удаления временного файла
        }
      }
    }
  }

  /// Извлечение vless-ссылок из бинарного содержимого x-ui.db
  List<String> _extractLinksFromDbBytes(List<int> bytes, String serverIp) {
    final links = <String>[];
    try {
      final content = String.fromCharCodes(bytes);
      // UUID всех клиентов
      final uuidRegex = RegExp(
        r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}',
      );
      final uuids = uuidRegex
          .allMatches(content)
          .map((m) => m.group(0)!)
          .toSet()
          .toList();

      // Публичный ключ REALITY (base64 43 символа)
      final pbkRegex = RegExp(r'"publicKey"\s*:\s*"([A-Za-z0-9_\-=]{43})"');
      final pbkMatch = pbkRegex.firstMatch(content);
      final publicKey = pbkMatch?.group(1) ?? '';

      // SNI
      final sniRegex = RegExp(r'"serverNames"\s*:\s*\[\s*"([^"]+)"');
      final sniMatch = sniRegex.firstMatch(content);
      final sni = sniMatch?.group(1) ?? '';

      // Short ID
      final sidRegex = RegExp(r'"shortIds"\s*:\s*\[\s*"([^"]*)"');
      final sidMatch = sidRegex.firstMatch(content);
      final shortId = sidMatch?.group(1) ?? '';

      // Порт
      final portMatch = RegExp(r'"port"\s*:\s*"?(\d{2,5})"?')
          .firstMatch(content);
      final port = int.tryParse(portMatch?.group(1) ?? '') ?? 443;

      // Транспорт, путь и маскировка XHTTP
      final isXhttp = RegExp(r'"network"\s*:\s*"xhttp"').hasMatch(content);
      final xhttpSettings = extractJsonObject(content, 'xhttpSettings') ?? {};
      final xhttpPath = xhttpSettings['path'] as String? ?? '/';

      if (publicKey.isEmpty) {
        _log('⚠️ Не удалось прочитать publicKey из базы');
        return links;
      }

      for (final uuid in uuids) {
        links.add(
          _buildVlessLink(
            server: serverIp,
            port: port,
            uuid: uuid,
            publicKey: publicKey,
            shortId: shortId,
            sni: sni,
            fingerprint: 'firefox',
            remark: 'MegaBox',
            transport: isXhttp ? 'xhttp' : 'tcp',
            xhttpPath: xhttpPath,
            xhttpExtra: SSHService.xhttpExtraFromSettings(xhttpSettings),
          ),
        );
      }
    } catch (e) {
      _log('❌ Ошибка разбора базы: $e');
    }
    return links;
  }

  /// Выполнение SQL-скрипта через heredoc (безопасно от shell-экранирования)
  /// SQL-литерал с экранированием одинарных кавычек.
  static String _sqlText(String v) => "'${v.replaceAll("'", "''")}'";

  /// Обнулить счётчики трафика клиента (по email из 3X-UI).
  Future<void> resetClientTraffic(
    String password,
    bool isRoot,
    String email,
  ) async {
    final e = _sqlText(email);
    _log('🧹 Сброс трафика клиента $email...');
    await _runSqlScript(
      'UPDATE client_traffics SET up = 0, down = 0 WHERE email = $e;',
      password,
      isRoot,
    );
    await _runCommand('systemctl restart x-ui', password, isRoot);
    _log('✅ Трафик клиента $email сброшен');
  }

  /// Включить или отключить клиента: флаг меняется и в client_traffics,
  /// и в JSON настроек Inbound, иначе Xray продолжит пускать клиента.
  Future<void> setClientEnabled(
    String password,
    bool isRoot,
    String email,
    bool enabled,
  ) async {
    final e = _sqlText(email);
    final flag = enabled ? 'true' : 'false';
    _log('${enabled ? '▶️ Включение' : '⏸️ Отключение'} клиента $email...');
    await _runSqlScript(
      '''
BEGIN;
UPDATE client_traffics SET enable = ${enabled ? 1 : 0} WHERE email = $e;
UPDATE inbounds SET settings = (
  SELECT json_set(inbounds.settings, '\$.clients[' || j.key || '].enable', json('$flag'))
  FROM json_each(inbounds.settings, '\$.clients') AS j
  WHERE json_extract(j.value, '\$.email') = $e
  LIMIT 1
)
WHERE EXISTS (
  SELECT 1 FROM json_each(inbounds.settings, '\$.clients') AS j
  WHERE json_extract(j.value, '\$.email') = $e
);
COMMIT;
''',
      password,
      isRoot,
    );
    await _runCommand('systemctl restart x-ui', password, isRoot);
    _log('✅ Клиент $email ${enabled ? 'включён' : 'отключён'}');
  }

  Future<String> _runSqlScript(String sql, String password, bool isRoot) async {
    return _runCommand(ShellScripts.sql(sql), password, isRoot);
  }

  /// Смена SNI (маскировочного домена) в 1 клик
  Future<void> changeSni(String password, bool isRoot, String newSni) async {
    if (!RegExp(r'^(?=.{1,253}$)[a-zA-Z0-9](?:[a-zA-Z0-9.-]*[a-zA-Z0-9])?$')
        .hasMatch(newSni)) {
      throw ArgumentError('Invalid SNI hostname');
    }
    if (_client == null) throw Exception('SSH не подключен');

    try {
      _log('🌐 Смена SNI на $newSni...');

      final sql =
          '''
UPDATE inbounds
SET stream_settings = json_set(
  stream_settings,
  '\$.realitySettings.serverNames[0]', '$newSni',
  '\$.realitySettings.dest', '$newSni:443',
  '\$.realitySettings.target', '$newSni:443'
)
WHERE id = (SELECT id FROM inbounds WHERE protocol='vless' AND stream_settings LIKE '%reality%' ORDER BY id LIMIT 1);
''';

      await _runSqlScript(sql, password, isRoot);
      await _runCommand('systemctl restart x-ui', password, isRoot);
      _log('✅ SNI изменён на $newSni, x-ui перезапущен');
    } catch (e) {
      _log('❌ Ошибка смены SNI: $e');
      rethrow;
    }
  }

  /// Добавление нового ключа (друга) на работающий сервер.
  /// [expiryHours] задаёт срок жизни ключа в часах (null — без ограничений).
  /// Возвращает готовую vless:// ссылку с актуальным IP.
  /// Установка 3X-UI на новый сервер (для миграции)
  Future<void> installXuiOnNewServer(String password, bool isRoot) async {
    if (_client == null) throw Exception('SSH не подключен');

    try {
      _log('📦 Установка 3X-UI на новый сервер...');

      final installCmd = '''
cd /tmp
rm -f xui_install.sh
curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh -o xui_install.sh
chmod +x xui_install.sh
bash /tmp/xui_install.sh
''';

      await _runCommand(installCmd, password, isRoot);
      await Future.delayed(const Duration(seconds: 5));
      _log('✅ 3X-UI установлена на новом сервере');
    } catch (e) {
      _log('❌ Ошибка установки на новом сервере: $e');
      rethrow;
    }
  }

  /// Получение списка ключей (vless-ссылок) с сервера
  /// Reads both real ports, avoiding assumptions about inbound IDs.
  Future<List<Map<String, dynamic>>> _realityInbounds(
    String password,
    bool isRoot,
  ) async {
    final raw = await _runSqlScript(
      "SELECT json_object('id', id, 'port', port, 'settings', settings, 'stream', stream_settings) "
      "FROM inbounds WHERE protocol = 'vless' AND port IN (443, 8443) ORDER BY port;",
      password,
      isRoot,
    );
    return raw
        .split('\n')
        .where((line) => line.trim().startsWith('{'))
        .map((line) => jsonDecode(line) as Map<String, dynamic>)
        .toList();
  }

  static String _linkForInbound(
    Map<String, dynamic> row,
    String serverIp,
    String uuid,
    String email,
  ) {
    final stream = jsonDecode(row['stream'] as String) as Map<String, dynamic>;
    final reality = stream['realitySettings'] as Map<String, dynamic>;
    final inner = reality['settings'] as Map<String, dynamic>? ?? {};
    final key = inner['publicKey'] as String? ?? '';
    final names = reality['serverNames'] as List<dynamic>? ?? [];
    final ids = reality['shortIds'] as List<dynamic>? ?? [];
    final network = stream['network'] as String? ?? 'tcp';
    if (key.isEmpty ||
        names.isEmpty ||
        stream['security'] != 'reality' ||
        (network != 'tcp' && network != 'xhttp')) {
      throw StateError(
        'Inbound is not a supported TCP/XHTTP VLESS-Reality configuration',
      );
    }
    final xhttp = stream['xhttpSettings'] as Map<String, dynamic>? ?? {};
    return SSHService.buildVlessLink(
      server: serverIp,
      port: row['port'] as int,
      uuid: uuid,
      publicKey: key,
      shortId: ids.isEmpty ? '' : ids.first.toString(),
      sni: names.first.toString(),
      fingerprint: inner['fingerprint'] as String? ?? 'firefox',
      remark: '$email-${row['port']}',
      transport: network,
      xhttpPath: xhttp['path'] as String? ?? '/',
      xhttpExtra: SSHService.xhttpExtraFromSettings(xhttp),
    );
  }

  /// Creates the same UUID on all existing main/backup Reality inbounds.
  Future<List<String>> addFriendKeys(
    String password,
    bool isRoot,
    String serverIp,
    String email, {
    ClientPolicy policy = const ClientPolicy(),
  }) async {
    final rows = await _realityInbounds(password, isRoot);
    if (rows.isEmpty) throw StateError('No VLESS-Reality inbound on 443/8443');
    final uuid = _generateUuid();
    final links = rows
        .map((row) => _linkForInbound(row, serverIp, uuid, email))
        .toList();
    // Flow клиента зависит от транспорта Inbound (Vision только для TCP),
    // поэтому Inbound с разными транспортами обрабатываем раздельно.
    final byNetwork = <String, List<int>>{};
    for (final row in rows) {
      final stream = jsonDecode(row['stream'] as String) as Map<String, dynamic>;
      final network = stream['network'] as String? ?? 'tcp';
      byNetwork.putIfAbsent(network, () => <int>[]).add(row['id'] as int);
    }
    for (final entry in byNetwork.entries) {
      final api = ApiService(
        ipAddress: serverIp,
        panelPort: 2053,
        basePath: '',
        apiToken: '',
        runCommand: (sql) => _runCommand(sql, password, isRoot),
        transport: entry.key,
      );
      try {
        await api.addClientToInbounds(
          inboundIds: entry.value,
          uuid: uuid,
          email: email,
          limitIp: 0,
          totalGb: policy.totalBytes,
          expiryTime: policy.expiryAt(DateTime.now()),
        );
      } finally {
        api.dispose();
      }
    }
    await _runCommand('systemctl restart x-ui', password, isRoot);
    return links;
  }

  Future<List<String>> getServerLinks(
    String password,
    bool isRoot,
    String serverIp,
  ) async {
    final rows = await _realityInbounds(password, isRoot);
    final links = <String>[];
    for (final row in rows) {
      final settings =
          jsonDecode(row['settings'] as String) as Map<String, dynamic>;
      final clients = settings['clients'] as List<dynamic>? ?? [];
      for (final item in clients) {
        final client = item as Map<String, dynamic>;
        if (client['enable'] == false) continue;
        final uuid = client['id'] as String? ?? '';
        if (uuid.isNotEmpty) {
          links.add(
            _linkForInbound(
              row,
              serverIp,
              uuid,
              client['email'] as String? ?? 'client',
            ),
          );
        }
      }
    }
    return links;
  }

  String _generateUuid() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    return [
          bytes.sublist(0, 4),
          bytes.sublist(4, 6),
          bytes.sublist(6, 8),
          bytes.sublist(8, 10),
          bytes.sublist(10, 16),
        ]
        .map((b) => b.map((e) => e.toRadixString(16).padLeft(2, '0')).join())
        .join('-');
  }

  String _buildVlessLink({
    required String server,
    required int port,
    required String uuid,
    required String publicKey,
    required String shortId,
    required String sni,
    required String fingerprint,
    required String remark,
    String transport = 'tcp',
    String xhttpPath = '/',
    Map<String, dynamic>? xhttpExtra,
  }) {
    return SSHService.buildVlessLink(
      server: server,
      port: port,
      uuid: uuid,
      publicKey: publicKey,
      shortId: shortId,
      sni: sni,
      fingerprint: fingerprint,
      remark: remark,
      transport: transport,
      xhttpPath: xhttpPath,
      xhttpExtra: xhttpExtra,
    );
  }

  /// Находит в тексте JSON-объект по ключу (`"key": { ... }`) с учётом
  /// вложенных скобок и строк. null — не найден или не разбирается.
  static Map<String, dynamic>? extractJsonObject(String content, String key) {
    final m = RegExp('"${RegExp.escape(key)}"\\s*:\\s*\\{').firstMatch(content);
    if (m == null) return null;
    final start = m.end - 1;
    var depth = 0;
    var inString = false;
    for (var i = start; i < content.length; i++) {
      final c = content[i];
      if (inString) {
        if (c == '\\') {
          i++;
        } else if (c == '"') {
          inString = false;
        }
        continue;
      }
      if (c == '"') {
        inString = true;
      } else if (c == '{') {
        depth++;
      } else if (c == '}') {
        depth--;
        if (depth == 0) {
          try {
            final v = jsonDecode(content.substring(start, i + 1));
            return v is Map<String, dynamic> ? v : null;
          } catch (_) {
            return null;
          }
        }
      }
    }
    return null;
  }

  Future<String> _runCommand(
    String command,
    String password,
    bool isRoot,
  ) async {
    if (commandRunner != null) return commandRunner!(command, password, isRoot);
    if (_client == null) throw StateError('SSH not connected');
    return RemoteExecutor.run(
      _client!,
      command,
      sudoPassword: isRoot ? null : password,
    );
  }
}

/// Трафик одного клиента из таблицы client_traffics 3X-UI.
class ClientTraffic {
  final String email;
  final int up;
  final int down;

  /// Лимит трафика в байтах (0 — без лимита).
  final int total;

  /// Срок действия в мс с эпохи (0 — бессрочно, <0 — с первого подключения).
  final int expiryTime;
  final bool enabled;

  const ClientTraffic({
    required this.email,
    required this.up,
    required this.down,
    required this.total,
    required this.expiryTime,
    required this.enabled,
  });

  int get used => up + down;
}

/// Живая статистика сервера
class ServerLiveStats {
  final double cpuUsage;
  final double ramUsedMb;
  final double ramTotalMb;
  final double ramPercent;
  final double diskUsage;
  final String uptime;
  final bool xuiActive;
  final int activeConnections;

  /// Load average за 1/5/15 минут, например «0.12 0.08 0.05».
  final String loadAverage;
  final int cpuCores;
  final double diskUsedGb;
  final double diskTotalGb;

  /// Счётчики байт сетевого интерфейса по умолчанию (null — не удалось).
  final int? rxBytes;
  final int? txBytes;
  final List<ClientTraffic> clients;
  final DateTime takenAt;

  ServerLiveStats({
    required this.cpuUsage,
    required this.ramUsedMb,
    required this.ramTotalMb,
    required this.ramPercent,
    required this.diskUsage,
    required this.uptime,
    required this.xuiActive,
    required this.activeConnections,
    this.loadAverage = '',
    this.cpuCores = 1,
    this.diskUsedGb = 0,
    this.diskTotalGb = 0,
    this.rxBytes,
    this.txBytes,
    this.clients = const <ClientTraffic>[],
    DateTime? takenAt,
  }) : takenAt = takenAt ?? DateTime.now();

  /// Разбор вывода скрипта getServerStats (строки key=value и client|...).
  factory ServerLiveStats.parse(String out) {
    final kv = <String, String>{};
    final clients = <ClientTraffic>[];
    for (final raw in out.split('\n')) {
      final line = raw.trim();
      if (line.startsWith('client|')) {
        final p = line.split('|');
        if (p.length >= 7) {
          clients.add(
            ClientTraffic(
              email: p[1],
              up: int.tryParse(p[2]) ?? 0,
              down: int.tryParse(p[3]) ?? 0,
              total: int.tryParse(p[4]) ?? 0,
              expiryTime: int.tryParse(p[5]) ?? 0,
              enabled: p[6] == '1' || p[6].toLowerCase() == 'true',
            ),
          );
        }
        continue;
      }
      final i = line.indexOf('=');
      if (i > 0) kv[line.substring(0, i)] = line.substring(i + 1).trim();
    }
    double d(String k) => double.tryParse(kv[k] ?? '') ?? 0;
    final used = d('ram_used');
    final total = d('ram_total') <= 0 ? 1.0 : d('ram_total');
    return ServerLiveStats(
      cpuUsage: d('cpu') / 10,
      ramUsedMb: used,
      ramTotalMb: total,
      ramPercent: used / total * 100,
      diskUsage: d('disk'),
      diskUsedGb: d('disk_used_kb') / 1024 / 1024,
      diskTotalGb: d('disk_total_kb') / 1024 / 1024,
      uptime: (kv['uptime'] ?? '').replaceFirst('up ', ''),
      xuiActive: kv['xui'] == 'active',
      activeConnections: int.tryParse(kv['conns'] ?? '') ?? 0,
      loadAverage: kv['load'] ?? '',
      cpuCores: int.tryParse(kv['cores'] ?? '') ?? 1,
      rxBytes: int.tryParse(kv['rx'] ?? ''),
      txBytes: int.tryParse(kv['tx'] ?? ''),
      clients: clients,
    );
  }
}
