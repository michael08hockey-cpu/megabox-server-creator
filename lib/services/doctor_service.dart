import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';

import 'host_key_store.dart';
import '../models/server_config.dart';
import 'remote_executor.dart';
import 'shell_scripts.dart';

/// Сервис диагностики и авто-починки серверов
/// Система «🩺 Авто-Доктор» для проверки и восстановления работы сервера
class DoctorService {
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
    // Debug logging (commented out for production)
    // print('[Doctor] $message');
  }

  /// Главная функция диагностики и авто-починки
  Future<DiagnosticResult> diagnoseAndFix(ServerConfig config) async {
    try {
      _log('🩺 Начало диагностики сервера ${config.ipAddress}...');

      final result = DiagnosticResult();

      // 1. Проверка SSH доступности
      _log('🔍 Проверка SSH доступности...');
      result.sshAccessible = await _checkSshAccess(config);

      if (!result.sshAccessible) {
        result.issues.add('❌ SSH недоступен');
        result.recommendation = _analyzeNetworkIssue(config.ipAddress);
        return result;
      }

      result.fixedIssues.add('✅ SSH доступен');

      // Подключаемся
      await _connectSSH(config);
      final isRoot = config.sshUser == 'root';

      // 2. Проверка интернета на сервере
      _log('🌐 Проверка интернет-соединения сервера...');
      result.internetWorking = await _checkInternet(config.sshPassword, isRoot);

      if (!result.internetWorking) {
        result.issues.add('❌ Интернет на сервере недоступен');
        result.recommendation = 'Проверьте внешнее подключение провайдера';
        return result;
      }

      result.fixedIssues.add('✅ Интернет работает');

      // 3. Проверка службы 3X-UI
      _log('🔍 Проверка службы 3X-UI...');
      final xuiStatus = await _checkXuiService(config.sshPassword, isRoot);

      if (!xuiStatus['active']) {
        result.issues.add('❌ Служба 3X-UI не активна');

        // Автоматическая починка
        _log('🛠️ ИСПРАВЛЯЮ: Перезапуск службы 3X-UI...');
        await _fixXuiService(config.sshPassword, isRoot);

        // Проверяем снова
        final newStatus = await _checkXuiService(config.sshPassword, isRoot);
        if (newStatus['active']) {
          result.fixedIssues.add('🛠️ ИСПРАВЛЕНО: Служба 3X-UI перезапущена');
        } else {
          result.issues.add('⚠️ Не удалось перезапустить службу');
        }
      } else {
        result.fixedIssues.add('✅ Служба 3X-UI активна');
      }

      // 4. Проверка портов VLESS
      _log('🔍 Проверка доступности портов...');
      result.vlessPortOpen = await _checkPort(
        config.ipAddress,
        config.vlessPort,
      );

      if (!result.vlessPortOpen) {
        result.issues.add('❌ Порт ${config.vlessPort} недоступен извне');

        // Автоматическая починка
        _log('🛠️ ИСПРАВЛЯЮ: Открытие порта в ufw...');
        await _fixFirewall(config.vlessPort, config.sshPassword, isRoot);

        result.fixedIssues.add(
          '🛠️ ИСПРАВЛЕНО: Порт ${config.vlessPort} добавлен в ufw',
        );
      } else {
        result.fixedIssues.add('✅ Порт ${config.vlessPort} доступен');
      }

      // 5. Проверка SNI
      _log('🔍 Проверка SNI...');
      final List<String> countryCandidates =
          config.location.sniCandidates.isEmpty
          ? globalSniFallbacks
          : config.location.sniCandidates;
      final sniWorking = await _checkSniTls(countryCandidates.first);

      if (!sniWorking) {
        result.issues.add('⚠️ Текущий SNI недоступен');

        // Пытаемся найти рабочий SNI
        _log('🛠️ ИСПРАВЛЯЮ: Поиск рабочего SNI...');
        final newSni = await _findWorkingSni(countryCandidates);

        if (newSni != null) {
          result.fixedIssues.add('🛠️ ИСПРАВЛЕНО: Найден рабочий SNI: $newSni');
          await _applySniToInbound(config.sshPassword, isRoot, newSni);
          result.recommendation = 'Маскировочный домен заменён на: $newSni';
        } else {
          // Все SNI выбранной страны недоступны — перебираем глобальные резервные
          result.issues.add('⚠️ Все SNI выбранной страны недоступны');
          _log('🛠️ ИСПРАВЛЯЮ: Перебор глобальных резервных доменов...');
          final globalSni = await _findWorkingSni(globalSniFallbacks);

          if (globalSni != null) {
            result.fixedIssues.add(
              '🛠️ ИСПРАВЛЕНО: Использован глобальный резервный SNI: $globalSni',
            );
            await _applySniToInbound(config.sshPassword, isRoot, globalSni);
            result.recommendation =
                'Маскировочный домен заменён на глобальный резервный: $globalSni';
          } else {
            // Ни один SNI недоступен — переключаем трафик на резервный порт 8443
            result.issues.add(
              '⚠️ Ни один SNI недоступен, включая глобальные резервные',
            );
            _log(
              '🛠️ ИСПРАВЛЯЮ: Переключение трафика на резервный порт $fallbackBackupPort...',
            );
            final bool switched = await _switchToFallbackPort(
              config.sshPassword,
              isRoot,
            );

            if (switched) {
              result.fixedIssues.add(
                '🛠️ ИСПРАВЛЕНО: Трафик переключён на резервный порт $fallbackBackupPort (gRPC/XHTTP)',
              );
              result.recommendation =
                  'Все маскировочные домены недоступны. Трафик переведён на резервный порт $fallbackBackupPort — укажите порт $fallbackBackupPort в клиенте.';
            } else {
              result.issues.add('❌ Не удалось переключиться на резервный порт');
              result.recommendation = 'Все маскировочные домены недоступны. Смените IP или обратитесь в поддержку провайдера.';
            }
          }
        }
      } else {
        result.fixedIssues.add('✅ SNI работает');
      }

      _log('✅ Диагностика завершена');

      return result;
    } catch (e) {
      _log('❌ Ошибка диагностики: $e');
      rethrow;
    } finally {
      _client?.close();
      _client = null;
    }
  }

  /// Получение статистики сервера (CPU, RAM, Диск, Uptime)
  Future<ServerStats> getServerStats(ServerConfig config) async {
    try {
      await _connectSSH(config);
      final isRoot = config.sshUser == 'root';

      final cpuCmd =
          "top -bn1 | grep 'Cpu(s)' | awk '{print \$2}' | cut -d'%' -f1";
      final memCmd = "free -m | awk 'NR==2{printf \"%.1f\", \$3*100/\$2 }'";
      final diskCmd = "df -h / | awk 'NR==2{print \$5}' | cut -d'%' -f1";
      final uptimeCmd = "uptime -p";

      final cpu = await _runCommand(cpuCmd, config.sshPassword, isRoot);
      final mem = await _runCommand(memCmd, config.sshPassword, isRoot);
      final disk = await _runCommand(diskCmd, config.sshPassword, isRoot);
      final uptime = await _runCommand(uptimeCmd, config.sshPassword, isRoot);

      return ServerStats(
        cpuUsage: double.tryParse(cpu.trim()) ?? 0,
        memUsage: double.tryParse(mem.trim()) ?? 0,
        diskUsage: double.tryParse(disk.trim()) ?? 0,
        uptime: uptime.trim(),
      );
    } finally {
      _client?.close();
      _client = null;
    }
  }

  /// Скачивание бэкапа x-ui.db
  Future<File> downloadBackup(ServerConfig config, String savePath) async {
    try {
      _log('📥 Скачивание бэкапа x-ui.db...');

      await _connectSSH(config);
      final isRoot = config.sshUser == 'root';

      const dbPath = '/etc/x-ui/x-ui.db';
      final tmpPath =
          '/tmp/x-ui-backup-${DateTime.now().millisecondsSinceEpoch}.db';
      await _runCommand('cp $dbPath $tmpPath', config.sshPassword, isRoot);

      final sftp = await _client!.sftp();
      final remoteFile = await sftp.open(tmpPath);
      final localFile = File(savePath);

      final content = await remoteFile.readBytes();
      await localFile.writeAsBytes(content);

      await _runCommand('rm -f $tmpPath', config.sshPassword, isRoot);

      _log('✅ Бэкап скачан: $savePath');
      return localFile;
    } finally {
      _client?.close();
      _client = null;
    }
  }

  /// Загрузка бэкапа на новый сервер
  Future<void> uploadBackup(ServerConfig config, String backupPath) async {
    try {
      _log('📤 Загрузка бэкапа на сервер...');

      await _connectSSH(config);
      final isRoot = config.sshUser == 'root';

      const dbPath = '/etc/x-ui/x-ui.db';
      final tmpPath =
          '/tmp/x-ui-restore-${DateTime.now().millisecondsSinceEpoch}.db';

      final sftp = await _client!.sftp();
      final remoteFile = await sftp.open(
        tmpPath,
        mode: SftpFileOpenMode.create | SftpFileOpenMode.write,
      );

      final localFile = File(backupPath);
      await remoteFile.write(localFile.openRead().cast());

      await _runCommand('systemctl stop x-ui', config.sshPassword, isRoot);
      await _runCommand('cp $tmpPath $dbPath', config.sshPassword, isRoot);
      await _runCommand('chown root:root $dbPath', config.sshPassword, isRoot);
      await _runCommand('systemctl start x-ui', config.sshPassword, isRoot);
      await _runCommand('rm -f $tmpPath', config.sshPassword, isRoot);

      _log('✅ Бэкап восстановлен');
    } finally {
      _client?.close();
      _client = null;
    }
  }

  /// Тест сбоя
  Future<void> createTestFailure(ServerConfig config) async {
    try {
      _log('🧪 Создание тестового сбоя...');
      await _connectSSH(config);
      await _runCommand(
        'systemctl stop x-ui',
        config.sshPassword,
        config.sshUser == 'root',
      );
      _log('✅ Служба остановлена');
    } finally {
      _client?.close();
      _client = null;
    }
  }

  // Вспомогательные методы проверок

  Future<void> _connectSSH(ServerConfig config) async {
    final socket = await SSHSocket.connect(
      config.ipAddress,
      config.sshPort,
      timeout: const Duration(seconds: 15),
    );

    _client = SSHClient(
      socket,
      username: config.sshUser,
      onPasswordRequest: () => config.sshPassword,
      onVerifyHostKey: HostKeyStore.verifier(config.ipAddress, config.sshPort),
      onUserInfoRequest: (SSHUserInfoRequest request) =>
          request.prompts.map((SSHUserInfoPrompt _) => config.sshPassword).toList(),
    );
  }

  Future<String> _runCommand(
    String command,
    String password,
    bool isRoot,
  ) async {
    if (_client == null) throw StateError('SSH not connected');
    return RemoteExecutor.run(
      _client!,
      command,
      sudoPassword: isRoot ? null : password,
    );
  }

  Future<bool> _checkSshAccess(ServerConfig config) async {
    try {
      final socket = await SSHSocket.connect(
        config.ipAddress,
        config.sshPort,
        timeout: const Duration(seconds: 5),
      );
      socket.close();
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<bool> _checkInternet(String password, bool isRoot) async {
    try {
      final result = await _runCommand(
        'ping -c 1 -W 3 8.8.8.8',
        password,
        isRoot,
      );
      return result.contains('1 received') ||
          result.contains('1 packets received');
    } catch (e) {
      return false;
    }
  }

  Future<Map<String, dynamic>> _checkXuiService(
    String password,
    bool isRoot,
  ) async {
    try {
      final result = await _runCommand(
        'systemctl is-active x-ui',
        password,
        isRoot,
      );
      return {'active': result.trim() == 'active'};
    } catch (e) {
      return {'active': false};
    }
  }

  Future<void> _fixXuiService(String password, bool isRoot) async {
    await _runCommand('systemctl restart x-ui', password, isRoot);
  }

  Future<bool> _checkPort(String host, int port) async {
    try {
      final socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 3),
      );
      socket.destroy();
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<void> _fixFirewall(int port, String password, bool isRoot) async {
    await _runCommand('ufw allow $port/tcp', password, isRoot);
  }

  Future<bool> _checkSniTls(String sni) async {
    try {
      final socket = await SecureSocket.connect(
        sni,
        443,
        timeout: const Duration(seconds: 3),
      );
      socket.destroy();
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<String?> _findWorkingSni(List<String> candidates) async {
    for (final sni in candidates) {
      if (await _checkSniTls(sni)) {
        return sni;
      }
    }
    return null;
  }

  /// Применение нового маскировочного домена (SNI) к Inbound в базе 3X-UI.
  Future<bool> _applySniToInbound(
    String password,
    bool isRoot,
    String newSni,
  ) async {
    try {
      _log('🔄 Применяю SNI $newSni в Inbound...');
      // SQL передаётся через heredoc, чтобы не экранировать кавычки в shell.
      final script =
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
      await _runCommand(ShellScripts.sql(script), password, isRoot);
      await _runCommand('systemctl restart x-ui', password, isRoot);
      _log('✅ SNI обновлён: $newSni');
      return true;
    } catch (e) {
      _log('⚠️ Не удалось применить SNI: $e');
      return false;
    }
  }

  /// Переключение трафика на резервный порт gRPC/XHTTP (8443),
  /// когда ни один маскировочный домен недоступен.
  Future<bool> _switchToFallbackPort(String password, bool isRoot) async {
    try {
      _log('🚪 Переключаю входящий на резервный порт $fallbackBackupPort...');
      final script =
          '''
DB=/etc/x-ui/x-ui.db
MAIN=\$(sqlite3 \$DB "SELECT id FROM inbounds WHERE protocol='vless' AND stream_settings LIKE '%reality%' ORDER BY id LIMIT 1;")
BUSY=\$(sqlite3 \$DB "SELECT COUNT(*) FROM inbounds WHERE port=$fallbackBackupPort AND id<>\$MAIN;")
if [ "\$BUSY" != "0" ]; then echo "MBX_BACKUP_EXISTS"; exit 0; fi
sqlite3 \$DB "UPDATE inbounds SET port=$fallbackBackupPort WHERE id=\$MAIN;"
systemctl restart x-ui
ufw allow $fallbackBackupPort/tcp 2>/dev/null || true
''';
      final out = await _runCommand(script, password, isRoot);
      if (out.contains('MBX_BACKUP_EXISTS')) {
        // Порт уже занят резервным Inbound — перенос основного вызвал бы
        // конфликт портов и падение Xray. Используйте резервную ссылку.
        _log('ℹ️ Порт $fallbackBackupPort уже занят резервным Inbound — используйте резервную ссылку');
        return true;
      }
      _log('✅ Трафик переключён на порт $fallbackBackupPort');
      return true;
    } catch (e) {
      _log('⚠️ Не удалось переключить порт: $e');
      return false;
    }
  }

  String _analyzeNetworkIssue(String ipAddress) {
    final isLocal =
        ipAddress.startsWith('192.168.') ||
        ipAddress.startsWith('10.') ||
        ipAddress.startsWith('100.64.');

    if (isLocal) {
      return '❌ Сервер физически отключен от локальной сети (проверьте кабель Ethernet или питание)';
    } else {
      return '❌ VPS недоступен из интернета. Возможные причины:\n'
          '  • IP заблокирован провайдером\n'
          '  • Сервер выключен\n'
          '  • Проблемы с хостинг-провайдером';
    }
  }
}

/// Результат диагностики
class DiagnosticResult {
  bool sshAccessible = false;
  bool internetWorking = false;
  bool vlessPortOpen = false;
  List<String> issues = [];
  List<String> fixedIssues = [];
  String? recommendation;
}

/// Статистика сервера
class ServerStats {
  final double cpuUsage;
  final double memUsage;
  final double diskUsage;
  final String uptime;

  ServerStats({
    required this.cpuUsage,
    required this.memUsage,
    required this.diskUsage,
    required this.uptime,
  });
}
