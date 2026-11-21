import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../models/server_config.dart';
import 'host_key_store.dart';
import '../models/deployment_result.dart';
import '../models/deployment_log.dart';
import '../models/terminal_line.dart';
import 'api_service.dart';
import 'xui_routing_helper.dart';
import 'shell_scripts.dart';
import 'warp_service.dart';

/// Основной SSH-сервис для развертывания 3X-UI на сервере
/// Поддерживает работу с не-root пользователями через sudo -S
class SSHService {
  SSHClient? _client;
  final StreamController<DeploymentLog> _logController =
      StreamController<DeploymentLog>.broadcast();

  Stream<DeploymentLog> get logStream => _logController.stream;

  /// Живой терминал: каждая SSH-команда (`$ cmd`) и весь stdout/stderr.
  final StreamController<TerminalLine> _terminalController =
      StreamController<TerminalLine>.broadcast();

  Stream<TerminalLine> get terminalStream => _terminalController.stream;

  void _term(String text, TerminalLineKind kind) {
    if (_terminalController.isClosed) return;
    final config = _activeConfig;
    for (final secret in [config?.sshPassword, config?.options.tgBotToken]) {
      if (secret != null && secret.isNotEmpty) {
        text = text.replaceAll(secret, '[REDACTED]');
      }
    }
    _terminalController.add(TerminalLine(text: text, kind: kind));
  }

  void dispose() {
    _logController.close();
    _terminalController.close();
    _client?.close();
    _client = null;
    _activeConfig = null;
  }

  void _log(String message, {DeploymentLogType type = DeploymentLogType.info}) {
    if (_logController.isClosed) return;
    _logController.add(
      DeploymentLog(timestamp: DateTime.now(), message: message, type: type),
    );
  }

  /// Главная функция развертывания сервера
  Future<DeploymentResult> deployServer(ServerConfig config) async {
    try {
      _log('🚀 Начало развёртывания сервера ${config.ipAddress}');
      _log('👤 Пользователь: ${config.sshUser}');

      await _connectSSH(config);

      final isRoot = config.sshUser == 'root';
      _log(isRoot ? '🔑 Режим root' : '🔓 Режим sudo для ${config.sshUser}');

      await runPreDeploymentCleanup(
        config: config,
        runCommand: _runCommand,
        onLog: (message, type) => _log(message, type: type),
      );

      // На чистых VPS sqlite3 отсутствует, а запись в базу 3X-UI идёт через него.
      // Если sqlite3 уже установлен — шаг завершается успешно, не трогая apt/dpkg.
      _log('🗄️ Проверка sqlite3...');
      // При отсутствии пакета чиним менеджер пакетов: ждём завершения apt/dpkg,
      // затем принудительно снимаем блокировки (см. ShellScripts.aptUnlock).
      await _runCommand(ShellScripts.installSqlite, config.sshPassword, isRoot);
      final sqliteCheck = await _runCommand(
        'command -v sqlite3 || echo MBX_SQLITE_MISSING',
        config.sshPassword,
        isRoot,
      );
      if (sqliteCheck.contains('MBX_SQLITE_MISSING') ||
          !sqliteCheck.contains('/sqlite3')) {
        throw Exception(
          'sqlite3 не установлен на сервере (apt-get install -y sqlite3 '
          'не сработал). Вывод: ${sqliteCheck.trim()}',
        );
      }
      _log(
        '✅ sqlite3 установлен: ${sqliteCheck.trim()}',
        type: DeploymentLogType.success,
      );

      // IPv6 отключается до установки панели: сервисы Google иначе могут
      // уйти в IPv6 в обход WARP и получать битые AAAA-записи.
      await _disableIpv6IfNeeded(config.sshPassword, isRoot);

      // ============ НОВАЯ ФУНКЦИЯ: Авто-Swap 2GB ============
      if (config.options.autoSwap) {
        await _setupSwapIfNeeded(config.sshPassword, isRoot);
      }

      _log('📦 Установка 3X-UI...');
      await _installXui(config.sshPassword, isRoot);

      _log('🔐 Генерация ключей Reality...');
      final keys = await _generateRealityKeys(config.sshPassword, isRoot);

      _log('⚙️ Настройка панели 3X-UI...');
      final panelUser = 'admin';
      final panelPass = _generatePassword(12);
      final panelPort = 2053;
      final panelPath = _generateRandomPath();

      await _configurePanel(
        password: config.sshPassword,
        isRoot: isRoot,
        panelUser: panelUser,
        panelPass: panelPass,
        panelPort: panelPort,
        panelPath: panelPath,
      );

      // ============ НОВАЯ ФУНКЦИЯ: Telegram Bot ============
      if (config.options.tgBotToken != null &&
          config.options.tgBotChatId != null) {
        await _configureTelegramBot(
          config.sshPassword,
          isRoot,
          config.options.tgBotToken!,
          config.options.tgBotChatId!,
        );
      }

      // ============ НОВАЯ ФУНКЦИЯ: Маскировка панели (Decoy Website) ============
      // Панель остаётся на порту 2053 (только localhost-прокси от Caddy),
      // а внешний адрес отдаёт сайт-заглушку; админка — по секретному пути.
      final useDecoy =
          config.options.decoyWebsite && !config.options.useSelfSteal;
      if (config.options.decoyWebsite && config.options.useSelfSteal) {
        _log(
          'ℹ️ Сайт-заглушка не нужен: в режиме self-steal на сервере '
          'будет настоящий сайт на твоём домене',
        );
      }
      if (useDecoy) {
        await _runCommand(
          'ufw deny $panelPort/tcp >/dev/null 2>&1 || true',
          config.sshPassword,
          isRoot,
        );
        await _setupDecoyWebsite(
          config.sshPassword,
          isRoot,
          serverIp: config.ipAddress,
          panelPort: panelPort,
          panelPath: panelPath,
        );
      }

      await Future.delayed(const Duration(seconds: 3));

      _log('🎫 Получение API токена...');
      final apiToken = await _getApiToken(
        config.ipAddress,
        panelPort,
        panelPath,
        panelUser,
        panelPass,
        config.sshPassword,
        isRoot,
      );

      final usesSqlite = apiToken.isEmpty;
      if (usesSqlite) {
        _log(
          '🗄️ Режим прямой записи в базу 3X-UI (без HTTP API)',
          type: DeploymentLogType.warning,
        );
      }

      final transport = config.options.transport == 'tcp' ? 'tcp' : 'xhttp';
      final xhttpPath = '/${_generatePassword(10).toLowerCase()}';
      final xhttpPadding = transport == 'xhttp' && config.options.xhttpObfs
          ? randomXhttpPadding()
          : null;
      final xhttpExtra = xhttpPadding == null
          ? null
          : xhttpExtraFromSettings({'mode': 'auto', ...xhttpPadding});
      if (xhttpPadding != null) {
        _log(
          '🎭 Маскировка паддинга XHTTP: ключ «${xhttpPadding['xPaddingKey']}», '
          '${xhttpPadding['xPaddingBytes']} байт',
        );
      }
      if (transport == 'tcp') {
        _log(
          '⚠️ Выбран старый транспорт TCP: связку TCP+Reality ТСПУ блокирует '
          'массово с 2026 года. Рекомендуется XHTTP.',
          type: DeploymentLogType.warning,
        );
      } else {
        _log('🛡️ Транспорт: XHTTP + Reality (путь $xhttpPath)');
      }
      if (config.vlessPort != 443) {
        _log(
          '⚠️ Порт ${config.vlessPort} вместо 443: Reality не на 443 '
          'повышает риск блокировки IP. Рекомендуется 443.',
          type: DeploymentLogType.warning,
        );
      }

      final apiService = ApiService(
        ipAddress: config.ipAddress,
        panelPort: panelPort,
        basePath: panelPath,
        apiToken: apiToken,
        // В SQLite-режиме все операции идут по SSH.
        runCommand: (String cmd) =>
            _runCommand(cmd, config.sshPassword, isRoot),
        transport: transport,
        xhttpPath: xhttpPath,
        xhttpPadding: xhttpPadding,
      );

      Map<String, String>? selfStealSni;
      String? realityTarget;
      if (config.options.useSelfSteal) {
        final domain = config.options.selfStealDomain!.trim().toLowerCase();
        if (await _setupSelfSteal(domain, config, isRoot)) {
          selfStealSni = {'sni': domain, 'ping': '0'};
          realityTarget = '127.0.0.1:$selfStealLocalPort';
        }
      }
      final sniResult = selfStealSni ?? await _selectBestSni(config, isRoot);

      _log('🔗 Создание основного Inbound (порт ${config.vlessPort})...');
      final uuid = _generateUuid();
      final mainInbound = await apiService.addVlessRealityInbound(
        port: config.vlessPort,
        publicKey: keys['publicKey']!,
        privateKey: keys['privateKey']!,
        shortId: keys['shortId']!,
        uuid: uuid,
        sni: sniResult['sni']!,
        remark: config.remark,
        fingerprint: config.location.fingerprint,
        target: realityTarget,
      );

      final vlessLink = buildVlessLink(
        server: config.ipAddress,
        port: config.vlessPort,
        uuid: uuid,
        publicKey: keys['publicKey']!,
        shortId: keys['shortId']!,
        sni: sniResult['sni']!,
        fingerprint: config.location.fingerprint,
        remark: config.remark,
        transport: transport,
        xhttpPath: xhttpPath,
        xhttpExtra: xhttpExtra,
      );

      String? backupVlessLink;
      int? backupInboundId;
      if (config.options.backupInbound && config.vlessPort != 8443) {
        _log('🔗 Создание резервного Inbound (порт 8443)...');
        final backupUuid = uuid;
        final backupInbound = await apiService.addVlessRealityInbound(
          port: 8443,
          publicKey: keys['publicKey']!,
          privateKey: keys['privateKey']!,
          shortId: keys['shortId']!,
          uuid: backupUuid,
          sni: sniResult['sni']!,
          remark: '${config.remark}-Backup',
          fingerprint: config.location.fingerprint,
          target: realityTarget,
        );

        backupInboundId =
            (backupInbound['obj'] as Map<String, dynamic>)['id'] as int;
        backupVlessLink = buildVlessLink(
          server: config.ipAddress,
          port: 8443,
          uuid: backupUuid,
          publicKey: keys['publicKey']!,
          shortId: keys['shortId']!,
          sni: sniResult['sni']!,
          fingerprint: config.location.fingerprint,
          remark: '${config.remark}-Backup',
          transport: transport,
          xhttpPath: xhttpPath,
          xhttpExtra: xhttpExtra,
        );
      }

      final mainInboundId =
          (mainInbound['obj'] as Map<String, dynamic>)['id'] as int;
      final friendsResult = await _createFriendKeys(
        config,
        apiService,
        keys,
        sniResult,
        mainInboundId,
        backupInboundId,
      );
      apiService.dispose();

      // Open the actual VLESS ports when UFW is enabled; provider firewalls
      // must still be configured separately.
      await _runCommand(
        'if command -v ufw >/dev/null 2>&1; then\n'
        '  ufw allow ${config.vlessPort}/tcp\n'
        '${backupInboundId != null ? '  ufw allow 8443/tcp\n' : ''}'
        '${realityTarget != null ? '  ufw allow 80/tcp\n' : ''}'
        'fi',
        config.sshPassword,
        isRoot,
      );

      // После прямой записи в базу Xray нужно перечитать конфиг.
      if (usesSqlite) {
        _log('🔄 Перезапуск x-ui для применения конфигурации из базы...');
        await _runCommand(
          'systemctl restart x-ui >/dev/null 2>&1 || true',
          config.sshPassword,
          isRoot,
        );
        await _waitForPanelPort(config.sshPassword, isRoot, panelPort);
      }

      _log('🛣️ Настройка правил маршрутизации...');
      await XuiRoutingHelper.applyRoutingRules(
        sshPassword: config.sshPassword,
        isRoot: isRoot,
        runCommand: _runCommand,
        options: config.options,
        onWarning: (message) => _log(message, type: DeploymentLogType.warning),
      );

      if (config.options.updateXrayCore) {
        await _updateXrayCore(config, isRoot);
      }

      // ============ НОВАЯ ФУНКЦИЯ: Watchdog ============
      if (config.options.watchdogEnabled &&
          config.options.tgBotToken != null &&
          config.options.tgBotChatId != null) {
        await _setupWatchdog(
          config.sshPassword,
          isRoot,
          config.ipAddress,
          config.options.tgBotToken,
          config.options.tgBotChatId,
        );
      }

      final actualPorts = <int>[
        config.vlessPort,
        if (backupVlessLink != null) 8443,
      ];
      _log('⏳ Ожидание Xray на портах ${actualPorts.join(", ")}...');
      var listeningPorts = <int>[];
      try {
        final output = await _runCommand(
          ShellScripts.waitForXrayPorts(actualPorts),
          config.sshPassword,
          isRoot,
        );
        listeningPorts = parseXrayListeningPorts(output, actualPorts);
      } catch (e) {
        _log(
          '⚠️ Не удалось проверить слушающие порты Xray: $e',
          type: DeploymentLogType.warning,
        );
      }
      _log('🔎 Проверка TCP-доступности обоих портов с ПК...');
      final reachablePorts = await probeTcpPorts(config.ipAddress, actualPorts);
      final serverReady = actualPorts.every(listeningPorts.contains);
      if (serverReady) {
        _log(
          reachablePorts.values.every((value) => value)
              ? '✅ Сервер готов: Xray слушает порты; TCP-доступность подтверждена'
              : '✅ Сервер готов: Xray слушает порты. Проверка с ПК не прошла; '
                    'проверьте локальную сеть и внешний firewall провайдера.',
          type: DeploymentLogType.success,
        );
      } else {
        _log(
          '⚠️ Не все порты Xray начали слушать на VPS: '
          '${actualPorts.where((p) => !listeningPorts.contains(p)).join(", ")}',
          type: DeploymentLogType.warning,
        );
      }

      final panelHidden = config.options.hidePanel && !useDecoy;
      if (panelHidden) {
        await _hidePanelFromInternet(
          config,
          isRoot,
          panelPort: panelPort,
          panelPath: panelPath,
        );
      }

      _log(
        '🎉 Развёртывание завершено успешно!',
        type: DeploymentLogType.success,
      );

      return DeploymentResult(
        vlessLink: vlessLink,
        backupVlessLink: backupVlessLink,
        panelUrl: useDecoy
            ? 'http://${config.ipAddress}/$panelPath'
            : panelHidden
            ? 'http://127.0.0.1:$panelPort/$panelPath'
            : 'http://${config.ipAddress}:$panelPort/$panelPath',
        panelUsername: panelUser,
        panelPassword: panelPass,
        locationFlag: config.location.flag,
        locationName: config.location.nameRu,
        selectedSni: sniResult['sni']!,
        sniPing: double.parse(sniResult['ping']!),
        // A TCP handshake is not an authenticated VLESS traffic test.
        trafficVerified: false,
        httpCode: 0,
        portReachable: reachablePorts[config.vlessPort] ?? false,
        serverListeningPorts: listeningPorts,
        portReachability: reachablePorts,
        trafficError: serverReady ? null : 'Не все порты Xray готовы на VPS',
        friendLinks: friendsResult['links'] as Map<String, String>,
        friendBackupLinks: friendsResult['backupLinks'] as Map<String, String>,
        subUrl: friendsResult['subUrl'] as String?,
      );
    } catch (e, stackTrace) {
      _log('❌ Критическая ошибка: $e', type: DeploymentLogType.error);
      _log('Stack trace: $stackTrace', type: DeploymentLogType.error);
      rethrow;
    } finally {
      _client?.close();
      _client = null;
      _activeConfig = null;
    }
  }

  Future<Map<String, dynamic>> _createFriendKeys(
    ServerConfig config,
    ApiService apiService,
    Map<String, String> keys,
    Map<String, String> sniResult,
    int inboundId,
    int? backupInboundId,
  ) async {
    Map<String, String> friendLinks = {};
    final friendBackupLinks = <String, String>{};
    String? subUrl;

    if (config.options.friendNames.isNotEmpty) {
      _log(
        '👥 Создание ключей для друзей: ${config.options.friendNames.join(", ")}...',
      );

      for (final friendName in config.options.friendNames) {
        final friendUuid = _generateUuid();

        // НОВОЕ: Вычисляем expiryTime если включены временные ключи
        int? expiryTime;
        if (config.options.temporaryKeys &&
            config.options.keyExpiryHours != null) {
          final now = DateTime.now();
          final expiry = now.add(
            Duration(hours: config.options.keyExpiryHours!),
          );
          expiryTime = expiry.millisecondsSinceEpoch;
        }

        await apiService.addClientToInbounds(
          inboundIds: [inboundId, ?backupInboundId],
          uuid: friendUuid,
          email: friendName,
          limitIp: config.options.limitIp,
          totalGb: config.options.limitGb * 1073741824,
          expiryTime: expiryTime, // НОВОЕ: передаем срок истечения
        );

        final friendLink = buildVlessLink(
          server: config.ipAddress,
          port: config.vlessPort,
          uuid: friendUuid,
          publicKey: keys['publicKey']!,
          shortId: keys['shortId']!,
          sni: sniResult['sni']!,
          fingerprint: config.location.fingerprint,
          remark: '$friendName-${config.remark}',
          transport: apiService.transport,
          xhttpPath: apiService.xhttpPath,
          xhttpExtra: _extraFor(apiService),
        );

        friendLinks[friendName] = friendLink;
        if (backupInboundId != null) {
          friendBackupLinks[friendName] = buildVlessLink(
            server: config.ipAddress,
            port: 8443,
            uuid: friendUuid,
            publicKey: keys['publicKey']!,
            shortId: keys['shortId']!,
            sni: sniResult['sni']!,
            fingerprint: config.location.fingerprint,
            remark: '$friendName-${config.remark}-Backup',
            transport: apiService.transport,
            xhttpPath: apiService.xhttpPath,
            xhttpExtra: _extraFor(apiService),
          );
        }
      }

      // Do not publish a random subscription URL that was never registered.
    }

    return {
      'links': friendLinks,
      'backupLinks': friendBackupLinks,
      'subUrl': subUrl,
    };
  }

  /// Параметры активного соединения — нужны для переподключения,
  /// если транспорт умрёт посреди развёртывания (перезапуск сети, reboot).
  ServerConfig? _activeConfig;

  Future<void> _connectSSH(ServerConfig config) async {
    // Старое соединение закрываем, иначе повторный вызов оставит
    // висящий сокет и предыдущий клиент продолжит держать транспорт.
    _client?.close();
    _client = null;
    _activeConfig = config;

    try {
      final socket = await SSHSocket.connect(
        config.ipAddress,
        config.sshPort,
        timeout: const Duration(seconds: 15),
      );

      final client = SSHClient(
        socket,
        username: config.sshUser,
        onPasswordRequest: () => config.sshPassword,
        onVerifyHostKey: HostKeyStore.verifier(config.ipAddress, config.sshPort),
        // Без этого обработчика в списке методов остаются только
        // password и none. Если на сервере включён
        // KbdInteractiveAuthentication (частая настройка VPS-провайдеров),
        // dartssh2 исчерпывает методы и бросает
        // SSHAuthFailError('All authentication methods failed').
        onUserInfoRequest: (SSHUserInfoRequest request) {
          // RFC 4256: ответ нужен на каждый prompt, порядок сохраняем.
          return request.prompts
              .map((SSHUserInfoPrompt _) => config.sshPassword)
              .toList();
        },
      );

      // Ключевая правка: ждём завершения авторизации здесь.
      // SSHClient() только запускает хендшейк в фоне, поэтому раньше
      // «✅ SSH соединение установлено» печаталось до проверки пароля,
      // а SSHAuthFailError всплывал позже — на первой же команде
      // (SSHClient.execute делает `await _authenticated.future`).
      await client.authenticated.timeout(
        const Duration(seconds: 30),
        onTimeout: () => throw Exception(
          'SSH-авторизация не завершилась за 30 секунд '
          '(${config.sshUser}@${config.ipAddress}:${config.sshPort})',
        ),
      );

      _client = client;
      _log('✅ SSH соединение установлено (авторизация подтверждена)');
    } on SSHAuthFailError catch (e) {
      _client?.close();
      _client = null;
      _log(
        '❌ SSH-авторизация отклонена для ${config.sshUser}@${config.ipAddress}: $e\n'
        'Проверьте: логин и пароль, а также что на сервере разрешён вход '
        'по паролю (PasswordAuthentication yes или '
        'KbdInteractiveAuthentication yes в /etc/ssh/sshd_config). '
        'Если вход только по ключу — пароль не подойдёт.',
        type: DeploymentLogType.error,
      );
      rethrow;
    } on SSHHostkeyError catch (e) {
      _client?.close();
      _client = null;
      _log(
        '❌ ${HostKeyStore.lastMismatch ?? 'Ключ SSH-сервера не прошёл проверку: $e'}',
        type: DeploymentLogType.error,
      );
      rethrow;
    } catch (e) {
      _client?.close();
      _client = null;
      _log(
        '❌ Не удалось подключиться к SSH: $e',
        type: DeploymentLogType.error,
      );
      rethrow;
    }
  }

  /// Возвращает живой клиент, при необходимости переподключаясь.
  ///
  /// Транспорт может умереть между командами (перезапуск сети при WARP,
  /// `systemctl restart`, таймаут провайдера). Новый [SSHClient] обязан
  /// заново пройти авторизацию — это делает [_connectSSH].
  Future<SSHClient> _ensureClient() async {
    final current = _client;
    if (current != null && !current.isClosed) return current;

    final config = _activeConfig;
    if (config == null) {
      throw Exception('SSH соединение не установлено');
    }

    _log(
      '🔄 SSH-соединение разорвано, переподключение...',
      type: DeploymentLogType.warning,
    );
    await _connectSSH(config);

    final restored = _client;
    if (restored == null || restored.isClosed) {
      throw Exception('Не удалось восстановить SSH соединение');
    }
    return restored;
  }

  Future<String> _runCommand(
    String command,
    String password,
    bool isRoot,
  ) async {
    if (_client == null && _activeConfig == null) {
      throw Exception('SSH соединение не установлено');
    }

    // В терминал уходит исходная команда, без sudo-обёртки с паролем.
    _term(command.trimRight(), TerminalLineKind.command);

    try {
      return await _execOnce(command, password, isRoot);
    } catch (e) {
      // Обрыв транспорта лечится переподключением; ошибка доступа — нет.
      final isDisconnect =
          e is SSHStateError ||
          e is SocketException ||
          e is SSHChannelOpenError ||
          (e is! SSHAuthFailError && (_client?.isClosed ?? true));

      if (!isDisconnect) {
        _log('❌ Ошибка выполнения команды: $e', type: DeploymentLogType.error);
        rethrow;
      }

      _log(
        '⚠️ Команда прервана ($e), повтор после переподключения',
        type: DeploymentLogType.warning,
      );
      try {
        await _ensureClient();
        return await _execOnce(command, password, isRoot);
      } catch (retryError) {
        _log(
          '❌ Ошибка выполнения команды: $retryError',
          type: DeploymentLogType.error,
        );
        rethrow;
      }
    }
  }

  /// Безопасная подстановка пароля в shell-команду.
  ///
  /// Оборачивает значение в одинарные кавычки, а каждую одинарную кавычку
  /// внутри заменяет на `'\''` (закрыть строку, экранированная кавычка,
  /// открыть снова). Без этого пароль вида `O'Brien` разрывал команду sudo.
  @visibleForTesting
  static String shellQuote(String value) =>
      "'${value.replaceAll("'", "'\\''")}'";

  /// Одна попытка выполнения команды на уже авторизованном соединении.
  Future<String> _execOnce(String command, String password, bool isRoot) async {
    final client = await _ensureClient();

    return _executeStreaming(
      client,
      ShellScripts.transport(command, sudoPassword: isRoot ? null : password),
    );
  }

  /// Выполняет команду и в реальном времени отправляет строки stdout/stderr
  /// в живой терминал. Возвращает объединённый вывод, как `client.run`.
  Future<String> _executeStreaming(SSHClient client, String command) async {
    final session = await client.execute(command);
    final all = <int>[];

    Future<void> pump(Stream<List<int>> stream, TerminalLineKind kind) {
      return stream
          .map((List<int> chunk) {
            all.addAll(chunk);
            return chunk;
          })
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .forEach((String line) => _term(line, kind));
    }

    await Future.wait(<Future<void>>[
      pump(session.stdout, TerminalLineKind.stdout),
      pump(session.stderr, TerminalLineKind.stderr),
    ]);
    await session.done;
    final code = session.exitCode;
    session.close();
    if (code != 0) {
      throw StateError('Remote command failed (exit $code)');
    }
    return utf8.decode(all, allowMalformed: true);
  }

  /// The cleanup is opt-in via cleanReinstall and runs before any apt install.
  static Future<void> runPreDeploymentCleanup({
    required ServerConfig config,
    required Future<String> Function(String, String, bool) runCommand,
    required void Function(String, DeploymentLogType) onLog,
  }) async {
    if (!config.options.cleanReinstall) return;
    if ([443, 8443, 2053].contains(config.sshPort)) {
      throw StateError(
        'Чистая установка запрещена: SSH использует очищаемый '
        'порт ${config.sshPort}. Измените SSH-порт перед очисткой.',
      );
    }
    onLog(
      '🧹 Проверка и очистка предыдущих компонентов...',
      DeploymentLogType.info,
    );
    final output = await runCommand(
      ShellScripts.generateCleanInstallScript(),
      config.sshPassword,
      config.sshUser == 'root',
    );
    if (!output.split('\n').any((line) => line.trim() == 'MBX_CLEANUP_DONE')) {
      throw StateError('Предварительная очистка не подтвердила завершение');
    }
    for (final line in output.split('\n')) {
      if (line.trim().startsWith('MBX_CLEANUP_WARNING:')) {
        onLog(
          '⚠️ ${line.trim().substring('MBX_CLEANUP_WARNING:'.length).trim()}',
          DeploymentLogType.warning,
        );
      }
    }
    onLog('✅ Старые службы остановлены и очищены', DeploymentLogType.success);
  }

  Future<void> _installXui(String password, bool isRoot) async {
    try {
      final downloadCmd = '''
cd /tmp
rm -f xui_install.sh
curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh -o xui_install.sh
chmod +x xui_install.sh
''';

      await _runCommand(downloadCmd, password, isRoot);
      _log('📥 Скрипт установки загружен');

      // The upstream installer invokes apt-get; recover before running it.
      final installCmd =
          '''
${ShellScripts.aptUnlock}
printf "n\\n" | bash /tmp/xui_install.sh
''';
      await _runCommand(installCmd, password, isRoot);

      _log('✅ 3X-UI установлена успешно');

      await Future.delayed(const Duration(seconds: 2));
      final statusCmd = 'systemctl is-active x-ui';
      final status = await _runCommand(statusCmd, password, isRoot);

      if (status.trim() == 'active') {
        _log('✅ Служба x-ui активна');
      } else {
        throw Exception('Служба x-ui не запущена. Статус: $status');
      }
    } catch (e) {
      _log('❌ Ошибка установки 3X-UI: $e', type: DeploymentLogType.error);
      rethrow;
    }
  }

  /// Генерация пары ключей X25519 для REALITY.
  ///
  /// Разные версии Xray-core печатают результат по-разному:
  ///   * старые:  `Private key: <...>` / `Public key: <...>`
  ///   * новые:   `PrivateKey: <...>` / `Password (PublicKey): <...>` / `Hash32: <...>`
  /// Поэтому парсер понимает оба формата. Если вывод распознать не удалось,
  /// пара генерируется резервным способом через openssl, а если и это
  /// невозможно — в исключение попадает реальный stdout/stderr команды.
  Future<Map<String, String>> _generateRealityKeys(
    String password,
    bool isRoot,
  ) async {
    try {
      // Бинарник ищем гибко: имя зависит от архитектуры
      // (xray-linux-amd64, xray-linux-arm64 и т.д.).
      const script = r'''
XRAY_BIN=$(ls /usr/local/x-ui/bin/xray* 2>/dev/null | head -n 1)
if [ -z "$XRAY_BIN" ]; then
    XRAY_BIN=$(command -v xray 2>/dev/null)
fi
if [ -z "$XRAY_BIN" ]; then
    echo "MBX_NO_XRAY_BINARY"
    exit 0
fi
echo "MBX_BIN_BEGIN"
echo "$XRAY_BIN"
echo "MBX_BIN_END"
MBX_ERR=/tmp/mbx_x25519.err
MBX_OUT=$("$XRAY_BIN" x25519 2>"$MBX_ERR")
echo "MBX_STDOUT_BEGIN"
echo "$MBX_OUT"
echo "MBX_STDOUT_END"
echo "MBX_STDERR_BEGIN"
cat "$MBX_ERR" 2>/dev/null
echo "MBX_STDERR_END"
rm -f "$MBX_ERR"
''';

      final raw = await _runCommand(script, password, isRoot);

      final binPath = _extractBlock(raw, 'MBX_BIN');
      final stdoutText = _extractBlock(raw, 'MBX_STDOUT');
      final stderrText = _extractBlock(raw, 'MBX_STDERR');

      if (binPath.isNotEmpty) {
        _log('🔍 Xray-бинарник: $binPath');
      }

      // Если маркеры не дошли (команда упала раньше) — парсим весь ответ.
      final parsed = parseX25519Output(
        stdoutText.isNotEmpty ? stdoutText : raw,
      );

      if (parsed != null) {
        _log('🔐 Ключи REALITY сгенерированы');
        return <String, String>{
          'privateKey': parsed['privateKey']!,
          'publicKey': parsed['publicKey']!,
          'shortId': _generateShortId(),
        };
      }

      // Резервный путь: openssl есть практически на любом VPS.
      _log(
        '⚠️ Формат вывода "xray x25519" не распознан, пробую openssl...',
        type: DeploymentLogType.warning,
      );
      final fallback = await _generateX25519ViaOpenssl(password, isRoot);
      if (fallback != null) {
        _log('🔐 Ключи REALITY сгенерированы через openssl');
        return <String, String>{
          'privateKey': fallback['privateKey']!,
          'publicKey': fallback['publicKey']!,
          'shortId': _generateShortId(),
        };
      }

      throw Exception(
        'Не удалось извлечь ключи X25519.\n'
        'Бинарник: ${binPath.isEmpty ? "не найден" : binPath}\n'
        '--- stdout ---\n'
        '${stdoutText.isEmpty ? "(пусто)" : stdoutText}\n'
        '--- stderr ---\n'
        '${stderrText.isEmpty ? "(пусто)" : stderrText}\n'
        '--- полный ответ ---\n'
        '${raw.trim().isEmpty ? "(пусто)" : raw.trim()}',
      );
    } catch (e) {
      _log('❌ Ошибка генерации ключей: $e', type: DeploymentLogType.error);
      rethrow;
    }
  }

  /// Разбор вывода `xray x25519` во всех известных форматах.
  /// Возвращает `null`, если ключи найти не удалось.
  @visibleForTesting
  static Map<String, String>? parseX25519Output(String output) {
    // `Private key:` (старый формат) и `PrivateKey:` (новый).
    // `[^:\n]*` пропускает возможные уточнения в скобках перед двоеточием.
    final privateMatch = RegExp(
      r'Private\s*key\s*[^:\n]*:\s*([A-Za-z0-9_\-+=/]+)',
      caseSensitive: false,
    ).firstMatch(output);

    // `Public key:` (старый), `Password:` и `Password (PublicKey):` (новый).
    final publicMatch = RegExp(
      r'(?:Public\s*key|Password)\s*[^:\n]*:\s*([A-Za-z0-9_\-+=/]+)',
      caseSensitive: false,
    ).firstMatch(output);

    if (privateMatch == null || publicMatch == null) return null;

    final privateKey = privateMatch.group(1)!;
    final publicKey = publicMatch.group(1)!;
    if (privateKey.isEmpty || publicKey.isEmpty) return null;

    return <String, String>{'privateKey': privateKey, 'publicKey': publicKey};
  }

  /// Вытаскивает текст между маркерами `<name>_BEGIN` и `<name>_END`.
  String _extractBlock(String source, String name) {
    final match = RegExp('${name}_BEGIN\\s*\\n([\\s\\S]*?)\\n?${name}_END')
        .firstMatch(source);
    return match == null ? '' : match.group(1)!.trim();
  }

  /// Резервная генерация пары X25519 через openssl.
  ///
  /// Сырые 32 байта лежат в конце DER: PKCS#8 для приватного ключа
  /// (48 байт) и SubjectPublicKeyInfo для публичного (44 байта), поэтому
  /// берём последние 32 байта. Кодирование — base64url без паддинга,
  /// как того ждёт REALITY.
  Future<Map<String, String>?> _generateX25519ViaOpenssl(
    String password,
    bool isRoot,
  ) async {
    try {
      const script = r'''
if ! command -v openssl >/dev/null 2>&1; then
    echo "MBX_NO_OPENSSL"
    exit 0
fi
MBX_KEY=/tmp/mbx_x25519.pem
openssl genpkey -algorithm X25519 -out "$MBX_KEY" 2>/dev/null || { echo "MBX_OPENSSL_FAILED"; exit 0; }
MBX_PRIV=$(openssl pkey -in "$MBX_KEY" -outform DER 2>/dev/null | tail -c 32 | base64 | tr -d '\n' | tr -d '=' | tr '+/' '-_')
MBX_PUB=$(openssl pkey -in "$MBX_KEY" -pubout -outform DER 2>/dev/null | tail -c 32 | base64 | tr -d '\n' | tr -d '=' | tr '+/' '-_')
rm -f "$MBX_KEY"
echo "MBX_PRIV_BEGIN"
echo "$MBX_PRIV"
echo "MBX_PRIV_END"
echo "MBX_PUB_BEGIN"
echo "$MBX_PUB"
echo "MBX_PUB_END"
''';

      final raw = await _runCommand(script, password, isRoot);

      if (raw.contains('MBX_NO_OPENSSL')) {
        _log('⚠️ openssl не установлен', type: DeploymentLogType.warning);
        return null;
      }
      if (raw.contains('MBX_OPENSSL_FAILED')) {
        _log(
          '⚠️ openssl не смог сгенерировать X25519',
          type: DeploymentLogType.warning,
        );
        return null;
      }

      final fallbackPrivate = _extractBlock(raw, 'MBX_PRIV');
      final fallbackPublic = _extractBlock(raw, 'MBX_PUB');

      // 32 байта в base64url без паддинга — ровно 43 символа.
      if (fallbackPrivate.length != 43 || fallbackPublic.length != 43) {
        _log(
          '⚠️ openssl вернул ключи неожиданной длины '
          '(${fallbackPrivate.length}/${fallbackPublic.length}, ожидалось 43)',
          type: DeploymentLogType.warning,
        );
        return null;
      }

      return <String, String>{
        'privateKey': fallbackPrivate,
        'publicKey': fallbackPublic,
      };
    } catch (e) {
      _log(
        '⚠️ Резервная генерация не удалась: $e',
        type: DeploymentLogType.warning,
      );
      return null;
    }
  }

  /// Настройка панели 3X-UI.
  ///
  /// В новых версиях (v2.4/v2.5+) установщик сам выставляет случайный
  /// webBasePath и может включить TLS-редирект, из-за чего панель
  /// не отвечает на ожидаемом URL. Поэтому:
  ///  1. останавливаем службу, чтобы `x-ui setting` писал в незанятую базу;
  ///  2. одной командой задаём логин/пароль/порт/webBasePath;
  ///  3. вычищаем из настроек сертификаты, старый путь и 2FA;
  ///  4. перезапускаем службу и ждём, пока порт реально начнёт слушаться.
  Future<void> _configurePanel({
    required String password,
    required bool isRoot,
    required String panelUser,
    required String panelPass,
    required int panelPort,
    required String panelPath,
  }) async {
    try {
      _log('🛑 Остановка x-ui для настройки...');
      await _runCommand(
        'systemctl stop x-ui >/dev/null 2>&1 || true',
        password,
        isRoot,
      );

      // Одна команда setting за один проход — быстрее и без гонок.
      _log('⚙️ Применение настроек панели...');
      await _runCommand(
        '/usr/local/x-ui/x-ui setting '
        '-username $panelUser '
        '-password $panelPass '
        '-port $panelPort '
        '-webBasePath /$panelPath',
        password,
        isRoot,
      );

      // Убираем всё, что может отправить панель на HTTPS или другой путь.
      final resetScript =
          r'''
DB=/etc/x-ui/x-ui.db
if [ -f "$DB" ]; then
    sqlite3 "$DB" "DELETE FROM settings WHERE key IN ('webCertFile', 'webKeyFile', 'webBasePath', 'twoFactorEnable');" 2>/dev/null || true
    # Возвращаем путь, который мы только что задали через x-ui setting.
    sqlite3 "$DB" "INSERT OR REPLACE INTO settings (key, value) VALUES ('webBasePath', '/MBX_PANEL_PATH');" 2>/dev/null || true
    sqlite3 "$DB" "INSERT OR REPLACE INTO settings (key, value) VALUES ('webPort', 'MBX_PANEL_PORT');" 2>/dev/null || true
fi
'''
              .replaceAll('MBX_PANEL_PATH', panelPath)
              .replaceAll('MBX_PANEL_PORT', panelPort.toString());

      await _runCommand(resetScript, password, isRoot);

      _log('🔄 Перезапуск x-ui...');
      await _runCommand(
        'systemctl restart x-ui >/dev/null 2>&1 || true',
        password,
        isRoot,
      );

      await _waitForPanelPort(password, isRoot, panelPort);

      _log('✅ Панель настроена (порт $panelPort, путь /$panelPath)');
    } catch (e) {
      _log('❌ Ошибка настройки панели: $e', type: DeploymentLogType.error);
      rethrow;
    }
  }

  /// Ожидание готовности веб-сервера панели (до 10 секунд).
  /// Возвращает true, если порт начал слушаться.
  Future<bool> _waitForPanelPort(
    String password,
    bool isRoot,
    int panelPort,
  ) async {
    for (int attempt = 1; attempt <= 10; attempt++) {
      try {
        // Код возврата не пробрасывается через _runCommand, поэтому
        // проверяем порт явным echo-маркером.
        final result = await _runCommand(
          ShellScripts.portProbe(panelPort),
          password,
          isRoot,
        );
        if (result.split('\n').any((line) => line.trim() == 'MBX_PORT_OPEN')) {
          _log('✅ Порт $panelPort доступен (попытка $attempt)');
          return true;
        }
      } catch (_) {
        // Игнорируем и пробуем снова.
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }

    _log(
      '⚠️ Порт $panelPort не открылся за 10 секунд',
      type: DeploymentLogType.warning,
    );
    return false;
  }

  /// Получение API-токена панели 3X-UI.
  ///
  /// Порт и webBasePath берутся из самой панели (`x-ui setting -show true`
  /// и таблица settings), а не из предположений — иначе запрос уходит
  /// на несуществующий URL. Пробуются form-urlencoded, JSON и `/login`
  /// с ручным разбором Set-Cookie. Если ничего не сработало, возвращается
  /// пустая строка: развёртывание продолжается через SQLite-фолбэк.
  Future<String> _getApiToken(
    String ip,
    int port,
    String path,
    String username,
    String password,
    String sshPassword,
    bool isRoot,
  ) async {
    // 1. Узнаём реальные порт и путь у самой панели.
    final actual = await _readPanelSettings(sshPassword, isRoot, port, path);
    final actualPort = actual['port'] as int;
    final actualPath = actual['path'] as String;

    _log('📋 Панель: порт $actualPort, путь /$actualPath');

    // 2. Пробуем разные способы авторизации внутри 127.0.0.1.
    for (final basePath in <String>{actualPath, ''}) {
      final base =
          'http://127.0.0.1:$actualPort/'
          '${basePath.isEmpty ? '' : '$basePath/'}';

      final token = await _tryLoginVariants(base, username, password);
      if (token != null) {
        _log('✅ API токен получен');
        return token;
      }
    }

    _log(
      '⚠️ Панель не отдала API токен — переходим на прямой доступ к SQLite',
      type: DeploymentLogType.warning,
    );
    return '';
  }

  /// Читает фактические webPort и webBasePath из базы панели.
  /// При неудаче возвращает переданные значения как есть.
  Future<Map<String, dynamic>> _readPanelSettings(
    String sshPassword,
    bool isRoot,
    int fallbackPort,
    String fallbackPath,
  ) async {
    int port = fallbackPort;
    String path = fallbackPath;

    try {
      const script = r'''
DB=/etc/x-ui/x-ui.db
echo "MBX_PORT_BEGIN"
sqlite3 "$DB" "SELECT value FROM settings WHERE key='webPort';" 2>/dev/null
echo "MBX_PORT_END"
echo "MBX_PATH_BEGIN"
sqlite3 "$DB" "SELECT value FROM settings WHERE key='webBasePath';" 2>/dev/null
echo "MBX_PATH_END"
''';

      final out = await _runCommand(script, sshPassword, isRoot);

      final portRaw = _extractBlock(out, 'MBX_PORT');
      final portValue = int.tryParse(portRaw.trim());
      if (portValue != null && portValue > 0 && portValue < 65536) {
        port = portValue;
      }

      final pathRaw = _extractBlock(out, 'MBX_PATH').trim();
      if (pathRaw.isNotEmpty) {
        // Приводим к виду без обрамляющих слэшей: "a/b".
        path = pathRaw.replaceAll(RegExp(r'^/+|/+$'), '');
      }
    } catch (e) {
      _log(
        '⚠️ Не удалось прочитать настройки панели: $e',
        type: DeploymentLogType.warning,
      );
    }

    return <String, dynamic>{'port': port, 'path': path};
  }

  /// Перебор вариантов авторизации. Возвращает токен или null.
  Future<String?> _tryLoginVariants(
    String base,
    String username,
    String password,
  ) async {
    final form =
        'username=${Uri.encodeQueryComponent(username)}'
        '&password=${Uri.encodeQueryComponent(password)}';
    final asJson = jsonEncode(<String, String>{
      'username': username,
      'password': password,
    });
    final uri = Uri.parse('${base}login');

    // 1) form-urlencoded, токен в теле JSON.
    final a = await _postLogin(
      uri,
      'application/x-www-form-urlencoded',
      form,
      expectJson: true,
    );
    if (a != null) return a;

    // 2) JSON, токен в теле JSON.
    final b = await _postLogin(
      uri,
      'application/json',
      asJson,
      expectJson: true,
    );
    if (b != null) return b;

    // 3) form-urlencoded, сессионная кука вместо токена.
    final c = await _postLogin(
      uri,
      'application/x-www-form-urlencoded',
      form,
      expectJson: false,
    );
    if (c != null) return c;

    // 4) JSON, сессионная кука.
    return _postLogin(uri, 'application/json', asJson, expectJson: false);
  }

  /// Один POST-запрос на вход. Возвращает токен из тела или из Set-Cookie.
  Future<String?> _postLogin(
    Uri uri,
    String contentType,
    String body, {
    required bool expectJson,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);

    try {
      final request = await client.postUrl(uri);
      request.followRedirects = true;
      request.maxRedirects = 3;
      request.headers.set('Content-Type', contentType);
      request.headers.set('Accept', 'application/json, text/plain, */*');
      request.write(body);

      final response = await request.close();
      final responseBody = await response.transform(utf8.decoder).join();

      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }

      // Токен в теле: {"success":true,"obj":"<token>"}
      if (expectJson) {
        final data = _tryDecodeJson(responseBody);
        if (data == null || data['success'] == false) return null;
        final obj = data['obj'];
        return (obj is String && obj.isNotEmpty) ? obj : null;
      }

      // Кука, имя сверяем в нижнем регистре.
      for (final cookie in response.cookies) {
        final name = cookie.name.toLowerCase();
        if ((name == '3x-ui' || name == 'x-ui' || name == 'session') &&
            cookie.value.isNotEmpty) {
          return cookie.value;
        }
      }

      // Ручной разбор заголовка, если HttpClient куку не распознал.
      final rawCookies = response.headers[HttpHeaders.setCookieHeader];
      if (rawCookies != null) {
        final pattern = RegExp(
          r'(?:Set-Cookie:\s*)?(?:^|[,;]\s*)?(3x-ui|x-ui|session)=([^;\r\n]+)',
          caseSensitive: false,
        );
        for (final header in rawCookies) {
          final match = pattern.firstMatch(header);
          if (match != null && match.group(2)!.isNotEmpty) {
            return match.group(2)!;
          }
        }
      }

      return null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Map<String, dynamic>? _tryDecodeJson(String source) {
    try {
      final decoded = jsonDecode(source);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic>? _extraFor(ApiService api) =>
      api.xhttpPadding == null
      ? null
      : xhttpExtraFromSettings({'mode': 'auto', ...api.xhttpPadding!});

  /// Случайная маскировка паддинга XHTTP для одного сервера.
  ///
  /// По умолчанию Xray кладёт мусорные байты в `Referer: ...?x_padding=XXX` —
  /// это известный отпечаток. С xPaddingObfsMode ключ, диапазон и способ
  /// генерации свои у каждого сервера, а сами байты похожи на токен.
  static Map<String, dynamic> randomXhttpPadding([Random? random]) {
    final r = random ?? Random.secure();
    const keys = <String>['_t', 'v', 'ts', 'cb', 'sid', 'rid', 'ref', 'utm_id'];
    final low = 64 + r.nextInt(160); // 64..223
    final high = 900 + r.nextInt(500); // 900..1399
    return <String, dynamic>{
      'xPaddingBytes': '$low-$high',
      'xPaddingObfsMode': true,
      'xPaddingKey': keys[r.nextInt(keys.length)],
      'xPaddingHeader': 'Referer',
      'xPaddingPlacement': 'queryInHeader',
      'xPaddingMethod': 'tokenish',
    };
  }

  /// `extra` для ссылки клиента из xhttpSettings Inbound (как делает 3X-UI):
  /// клиент должен знать те же настройки паддинга, что и сервер.
  /// null — маскировка выключена, ссылка остаётся короткой.
  static Map<String, dynamic>? xhttpExtraFromSettings(
    Map<String, dynamic> xhttp,
  ) {
    if (xhttp['xPaddingObfsMode'] != true) return null;
    final extra = <String, dynamic>{};
    final mode = xhttp['mode'];
    if (mode is String && mode.isNotEmpty) extra['mode'] = mode;
    final bytes = xhttp['xPaddingBytes'];
    if (bytes is String && bytes.isNotEmpty) extra['xPaddingBytes'] = bytes;
    extra['xPaddingObfsMode'] = true;
    for (final field in const [
      'xPaddingKey',
      'xPaddingHeader',
      'xPaddingPlacement',
      'xPaddingMethod',
    ]) {
      final v = xhttp[field];
      if (v is String && v.isNotEmpty) extra[field] = v;
    }
    return extra;
  }

  /// Скрипт: отключает MPTCP (дыра 2026, новый Xray его тоже выключает) и
  /// обновляет ядро Xray в 3X-UI до последнего стабильного релиза.
  /// Если после обновления Xray не слушает [port] — возвращает старое ядро.
  /// Маркеры вывода: MBX_XRAY_UPDATED / _LATEST / _ROLLBACK / _SKIP / _FAIL.
  @visibleForTesting
  static String xrayUpdateScript(int port) {
    const body = r'''
set +e
sysctl -w net.mptcp.enabled=0 >/dev/null 2>&1 && \
  echo 'net.mptcp.enabled=0' > /etc/sysctl.d/99-mbx-mptcp.conf && echo MBX_MPTCP_OFF
case "$(uname -m)" in
  x86_64) ZIP=64; BINARCH=amd64 ;;
  aarch64|arm64) ZIP=arm64-v8a; BINARCH=arm64 ;;
  *) echo "MBX_XRAY_SKIP arch $(uname -m)"; exit 0 ;;
esac
BIN="/usr/local/x-ui/bin/xray-linux-$BINARCH"
[ -x "$BIN" ] || { echo "MBX_XRAY_SKIP no-binary"; exit 0; }
CUR=$("$BIN" version 2>/dev/null | head -1 | awk '{print $2}')
TAG=$(curl -fsSL --max-time 20 https://api.github.com/repos/XTLS/Xray-core/releases/latest \
  | grep -m1 '"tag_name"' | cut -d'"' -f4)
case "$TAG" in v[0-9]*) ;; *) echo "MBX_XRAY_FAIL no-tag $CUR"; exit 0 ;; esac
[ "v$CUR" = "$TAG" ] && { echo "MBX_XRAY_LATEST $CUR"; exit 0; }
TMP=$(mktemp -d)
curl -fsSL --max-time 180 -o "$TMP/x.zip" \
  "https://github.com/XTLS/Xray-core/releases/download/$TAG/Xray-linux-$ZIP.zip" \
  || { echo "MBX_XRAY_FAIL download $CUR"; rm -rf "$TMP"; exit 0; }
unzip -o -q "$TMP/x.zip" xray -d "$TMP" 2>/dev/null \
  || python3 -c "import zipfile,sys;zipfile.ZipFile(sys.argv[1]).extract('xray',sys.argv[2])" "$TMP/x.zip" "$TMP" 2>/dev/null
chmod 755 "$TMP/xray" 2>/dev/null
"$TMP/xray" version >/dev/null 2>&1 || { echo "MBX_XRAY_FAIL bad-binary $CUR"; rm -rf "$TMP"; exit 0; }
cp -f "$BIN" "$BIN.mbx-bak"
install -m 755 "$TMP/xray" "$BIN"
rm -rf "$TMP"
systemctl restart x-ui
ok=0
for i in 1 2 3 4 5 6 7 8 9 10; do
  sleep 2
  ss -ltnH 2>/dev/null | awk '{print $4}' | grep -q ":$PORT\$" && { ok=1; break; }
done
if [ "$ok" = 1 ]; then
  echo "MBX_XRAY_UPDATED $CUR -> $TAG"
else
  cp -f "$BIN.mbx-bak" "$BIN"
  systemctl restart x-ui
  echo "MBX_XRAY_ROLLBACK $CUR (new $TAG did not start)"
fi
true
''';
    return 'PORT=$port\n$body';
  }

  /// Обновление ядра Xray + отключение MPTCP. Ошибки не валят развёртывание.
  Future<void> _updateXrayCore(ServerConfig config, bool isRoot) async {
    _log('⬆️ Проверяю ядро Xray (свежая версия + защита MPTCP)...');
    try {
      final out = await _runCommand(
        xrayUpdateScript(config.vlessPort),
        config.sshPassword,
        isRoot,
      );
      if (out.contains('MBX_MPTCP_OFF')) _log('🔒 MPTCP отключён');
      String tail(String marker) {
        final m = RegExp('$marker(.*)').firstMatch(out);
        return m == null ? '' : m.group(1)!.trim();
      }

      if (out.contains('MBX_XRAY_UPDATED')) {
        _log(
          '✅ Ядро Xray обновлено: ${tail('MBX_XRAY_UPDATED')}',
          type: DeploymentLogType.success,
        );
      } else if (out.contains('MBX_XRAY_LATEST')) {
        _log('✅ Ядро Xray уже последней версии: ${tail('MBX_XRAY_LATEST')}');
      } else if (out.contains('MBX_XRAY_ROLLBACK')) {
        _log(
          '⚠️ Новое ядро Xray не запустилось, вернул прежнее: '
          '${tail('MBX_XRAY_ROLLBACK')}',
          type: DeploymentLogType.warning,
        );
      } else {
        _log(
          '⚠️ Ядро Xray не обновлено (${tail('MBX_XRAY_(?:FAIL|SKIP)')}), '
          'работает версия из 3X-UI',
          type: DeploymentLogType.warning,
        );
      }
    } catch (e) {
      _log(
        '⚠️ Не удалось обновить ядро Xray: $e',
        type: DeploymentLogType.warning,
      );
    }
  }

  /// Подбор маски Reality (SNI). Всё проверяется С САМОГО СЕРВЕРА,
  /// а не с компьютера в России: маска должна быть рядом с VPS.
  ///
  /// 1. Соседи по подсети /24: настоящие сайты с TLS 1.3 + HTTP/2, у которых
  ///    DNS домена указывает именно на этот соседний IP (так отсеиваются
  ///    чужие Reality-серверы, выдающие себя за microsoft.com и т.п.).
  ///    SNI из той же сети не вызывает подозрения «домен не из этой сети».
  /// 2. Иначе — список доменов страны и глобальный безопасный список.
  /// Microsoft/Apple/Google/Cloudflare не используются никогда.
  Future<Map<String, String>> _selectBestSni(
    ServerConfig config,
    bool isRoot,
  ) async {
    _log('🔎 Ищу сайт-маску рядом с сервером (соседи по подсети, ~1 мин)...');
    if (RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(config.ipAddress)) {
      try {
        final out = await _runCommand(
          neighborSniScanScript(config.ipAddress),
          config.sshPassword,
          isRoot,
        );
        final found = parseSniProbe(out);
        if (found.isNotEmpty) {
          for (final e in found.take(5)) {
            _log('  • ${e.key}: ${(e.value * 1000).toStringAsFixed(0)}ms');
          }
          final best = found.first;
          _log(
            '✅ Маска из соседей по подсети: ${best.key}',
            type: DeploymentLogType.success,
          );
          return {
            'sni': best.key,
            'ping': (best.value * 1000).toStringAsFixed(0),
          };
        }
        _log('ℹ️ Подходящих сайтов среди соседей не нашлось');
      } catch (e) {
        _log(
          '⚠️ Сканирование соседей не удалось: $e',
          type: DeploymentLogType.warning,
        );
      }
    }

    final candidates = <String>{
      ...config.location.sniCandidates,
      ...globalSniFallbacks,
    }.where((d) => !isBurnedSni(d)).toList();
    _log('🌐 Проверяю домены-маски с сервера: ${candidates.join(', ')}');
    try {
      final out = await _runCommand(
        sniProbeScript(candidates),
        config.sshPassword,
        isRoot,
      );
      final found = parseSniProbe(out);
      if (found.isNotEmpty) {
        final best = found.first;
        final ms = (best.value * 1000).toStringAsFixed(0);
        _log(
          '✅ Выбран SNI: ${best.key} ($ms ms от сервера)',
          type: DeploymentLogType.success,
        );
        return {'sni': best.key, 'ping': ms};
      }
    } catch (e) {
      _log(
        '⚠️ Проверка с сервера не удалась: $e',
        type: DeploymentLogType.warning,
      );
    }

    // Запасной путь: замер с этого компьютера.
    final local = await _pickFastestSni(candidates);
    if (local != null) return local;

    _log(
      '❌ Ни один домен-маска не прошёл проверку, использую www.samsung.com',
      type: DeploymentLogType.warning,
    );
    return {'sni': 'www.samsung.com', 'ping': '999'};
  }

  /// Общая проверка домена-маски внутри цикла `for d in ...`.
  /// Переменные: d — домен, h — IP соседа (пусто = DNS не сверяем).
  /// Печатает `MBXSNI <домен> <секунды TLS-рукопожатия>`.
  static const String _sniCheckBody = r'''
    case "$d" in *microsoft*|*apple*|*icloud*|*google*|*cloudflare*) continue ;; esac
    if [ -n "$h" ]; then
      getent ahostsv4 "$d" 2>/dev/null | awk '{print $1}' | grep -qx "$h" || continue
    fi
    hdr=$(mktemp)
    meta=$(curl -sS -o /dev/null -D "$hdr" --max-time 6 --tlsv1.3 --http2 -w '%{http_version} %{http_code} %{time_appconnect}' "https://$d/" 2>/dev/null)
    cf=0; grep -qi '^server: *cloudflare' "$hdr" && cf=1
    rm -f "$hdr"
    ver=$(echo "$meta" | awk '{print $1}')
    code=$(echo "$meta" | awk '{print $2}')
    t=$(echo "$meta" | awk '{print $3}')
    [ "$cf" = 0 ] || continue
    [ "$ver" = 2 ] || continue
    case "$code" in 2*|3*) echo "MBXSNI $d $t"; [ -n "$h" ] && break ;; esac''';

  /// Скрипт: ищет среди соседей по /24 настоящие сайты, годные как маска.
  @visibleForTesting
  static String neighborSniScanScript(String ip) {
    if (!RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(ip)) {
      throw ArgumentError('IPv4 expected');
    }
    const head = r'''
set +e
NET="${IP%.*}"
mbx_probe() {
  h="$NET.$1"
  [ "$h" = "$IP" ] && return 0
  out=$(timeout 4 openssl s_client -connect "$h:443" -tls1_3 -alpn h2 </dev/null 2>/dev/null)
  echo "$out" | grep -q 'TLSv1.3' || return 0
  echo "$out" | grep -q 'ALPN protocol: h2' || return 0
  names=$(echo "$out" | openssl x509 -noout -text 2>/dev/null | grep -o 'DNS:[^, ]*' | cut -d: -f2 | grep -v '[*]' | head -5)
  for d in $names; do
''';
    const tail = r'''
  done
  return 0
}
export -f mbx_probe
export IP NET
seq 1 254 | timeout 150 xargs -P 48 -I{} bash -c 'mbx_probe {}'
true
''';
    return "IP='$ip'\n$head$_sniCheckBody\n$tail";
  }

  /// Скрипт: проверяет домены-кандидаты с сервера (TLS 1.3 + HTTP/2,
  /// живой ответ, не Cloudflare).
  @visibleForTesting
  static String sniProbeScript(List<String> domains) {
    final safe = domains
        .where((d) => RegExp(r'^[a-zA-Z0-9.-]{1,253}$').hasMatch(d))
        .join(' ');
    return "set +e\nh=''\nfor d in $safe; do\n$_sniCheckBody\ndone\ntrue\n";
  }

  /// Разбор вывода проверки маски: (домен, секунды), по возрастанию времени,
  /// без дублей и «выжженных» доменов.
  @visibleForTesting
  static List<MapEntry<String, double>> parseSniProbe(String out) {
    final best = <String, double>{};
    for (final raw in out.split('\n')) {
      final p = raw.trim().split(RegExp(r'\s+'));
      if (p.length < 3 || p[0] != 'MBXSNI') continue;
      final domain = p[1].toLowerCase();
      final t = double.tryParse(p[2]);
      if (t == null || t <= 0 || isBurnedSni(domain)) continue;
      if (!RegExp(r'^[a-z0-9.-]{1,253}$').hasMatch(domain)) continue;
      if (!best.containsKey(domain) || t < best[domain]!) best[domain] = t;
    }
    return best.entries.toList()..sort((a, b) => a.value.compareTo(b.value));
  }

  /// Локальный порт nginx в режиме self-steal (Reality отдаёт ему
  /// всё, что пришло без ключа). Не 8443 — он занят резервным Inbound.
  static const int selfStealLocalPort = 9443;

  /// Self-steal: на сервере поднимается настоящий сайт на домене
  /// пользователя с сертификатом Let's Encrypt, Reality маскируется под него.
  /// SNI, DNS, IP и сертификат совпадают — проверке ТСПУ не к чему придраться.
  /// false — что-то не вышло, развёртывание продолжится в обычном режиме.
  Future<bool> _setupSelfSteal(
    String domain,
    ServerConfig config,
    bool isRoot,
  ) async {
    if (!isValidSelfStealDomain(domain)) {
      _log('❌ Некорректный домен: $domain', type: DeploymentLogType.error);
      return false;
    }
    _log('🏠 Self-steal: настраиваю сайт $domain на сервере...');
    try {
      final out = await _runCommand(
        selfStealScript(domain, config.ipAddress),
        config.sshPassword,
        isRoot,
      );
      if (out.contains('MBX_SELFSTEAL_OK')) {
        _log(
          '✅ Self-steal готов: https://$domain отдаёт настоящий сайт',
          type: DeploymentLogType.success,
        );
        return true;
      }
      final dns = RegExp(r'MBX_DNS_MISMATCH(.*)').firstMatch(out);
      if (dns != null) {
        final got = dns.group(1)!.trim();
        _log(
          '❌ Домен $domain указывает на «${got.isEmpty ? 'ничего' : got}», '
          'а должен на ${config.ipAddress}. Создай A-запись у регистратора '
          '(без прокси Cloudflare) и подожди 5–30 минут.',
          type: DeploymentLogType.error,
        );
      } else {
        final tailOut = out.length > 400 ? out.substring(out.length - 400) : out;
        _log(
          '❌ Не удалось настроить сайт для $domain. Вывод: $tailOut',
          type: DeploymentLogType.error,
        );
      }
    } catch (e) {
      _log('❌ Ошибка self-steal: $e', type: DeploymentLogType.error);
    }
    _log(
      '↩️ Продолжаю без self-steal, с подбором маски',
      type: DeploymentLogType.warning,
    );
    return false;
  }

  /// Домен для self-steal: латиница, без «vpn/proxy/xray/vless» и т.п.
  /// (SNI летит открытым текстом — такие слова сами по себе подозрительны).
  static bool isValidSelfStealDomain(String domain) {
    final d = domain.trim().toLowerCase();
    if (!RegExp(r'^(?=.{4,253}$)([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$')
        .hasMatch(d)) {
      return false;
    }
    return true;
  }

  /// Слова в домене, которые выдают VPN (SNI передаётся открытым текстом).
  static bool domainLooksLikeVpn(String domain) {
    final d = domain.toLowerCase();
    return const ['vpn', 'proxy', 'xray', 'vless', 'reality', 'v2ray', 'tunnel']
        .any(d.contains);
  }

  /// Скрипт self-steal: проверка A-записи, nginx + certbot, сайт на
  /// 127.0.0.1:[selfStealLocalPort]. Печатает MBX_SELFSTEAL_OK при успехе.
  @visibleForTesting
  static String selfStealScript(String domain, String ip) {
    if (!isValidSelfStealDomain(domain) ||
        !RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(ip)) {
      throw ArgumentError('invalid domain or IP');
    }
    const body = r'''
set +e
RES=$(getent ahostsv4 "$DOMAIN" | awk '{print $1}' | sort -u | tr '\n' ' ')
echo " $RES " | grep -q " $IP " || { echo "MBX_DNS_MISMATCH $RES"; exit 0; }
__APT_UNLOCK__
apt-get install -y nginx certbot >/dev/null 2>&1 || { echo MBX_APT_FAIL; exit 0; }
mkdir -p /var/www/mbx-site
cat > /var/www/mbx-site/index.html <<'MBX_HTML'
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Notes</title>
<style>body{font-family:Georgia,serif;max-width:640px;margin:60px auto;padding:0 20px;color:#222;line-height:1.6}h1{font-weight:normal}small{color:#888}</style>
</head><body><h1>Notes</h1><p>Small personal notes about photography, travel and books.</p>
<p><small>New posts are coming soon.</small></p></body></html>
MBX_HTML
rm -f /etc/nginx/sites-enabled/default
cat > /etc/nginx/sites-available/mbx-site <<'MBX_NGX'
server {
    listen 80;
    listen [::]:80;
    server_name __DOMAIN__;
    root /var/www/mbx-site;
    location /.well-known/acme-challenge/ { try_files $uri =404; }
    location / { return 301 https://$host$request_uri; }
}
MBX_NGX
sed -i "s/__DOMAIN__/$DOMAIN/" /etc/nginx/sites-available/mbx-site
ln -sf /etc/nginx/sites-available/mbx-site /etc/nginx/sites-enabled/mbx-site
nginx -t >/dev/null 2>&1 && systemctl restart nginx
if [ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
  certbot certonly --webroot -w /var/www/mbx-site -d "$DOMAIN" \
    --non-interactive --agree-tos --register-unsafely-without-email \
    --deploy-hook 'systemctl reload nginx' 2>&1 | tail -5
fi
[ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ] || { echo MBX_CERT_FAIL; exit 0; }
cat >> /etc/nginx/sites-available/mbx-site <<MBX_NGX
server {
    listen 127.0.0.1:$LOCAL_PORT ssl http2;
    server_name $DOMAIN;
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    root /var/www/mbx-site;
    index index.html;
}
MBX_NGX
nginx -t >/dev/null 2>&1 || { echo MBX_NGINX_FAIL; nginx -t 2>&1 | tail -3; exit 0; }
systemctl reload nginx
systemctl enable nginx >/dev/null 2>&1
echo MBX_SELFSTEAL_OK
true
''';
    return "DOMAIN='${domain.trim().toLowerCase()}'\nIP='$ip'\n"
        "LOCAL_PORT=$selfStealLocalPort\n"
        '${body.replaceFirst('__APT_UNLOCK__', ShellScripts.aptUnlock)}';
  }

  /// Панель 3X-UI слушает только 127.0.0.1: сканеры не найдут её на IP.
  /// Вход — через SSH-туннель.
  Future<void> _hidePanelFromInternet(
    ServerConfig config,
    bool isRoot, {
    required int panelPort,
    required String panelPath,
  }) async {
    try {
      _log('🙈 Скрываю панель 3X-UI от интернета...');
      await _runCommand(
        ShellScripts.sql(hidePanelSql),
        config.sshPassword,
        isRoot,
      );
      await _runCommand(
        'systemctl restart x-ui >/dev/null 2>&1 || true',
        config.sshPassword,
        isRoot,
      );
      _log(
        '✅ Панель доступна только через SSH-туннель:\n'
        '   ssh -L $panelPort:127.0.0.1:$panelPort '
        '${config.sshUser}@${config.ipAddress} -p ${config.sshPort}\n'
        '   затем открой http://127.0.0.1:$panelPort/$panelPath',
        type: DeploymentLogType.success,
      );
    } catch (e) {
      _log('⚠️ Не удалось скрыть панель: $e', type: DeploymentLogType.warning);
    }
  }

  /// SQL: панель слушает только localhost (ключ webListen в настройках 3X-UI).
  static const String hidePanelSql =
      "UPDATE settings SET value = '127.0.0.1' WHERE key = 'webListen';\n"
      "INSERT INTO settings (key, value) SELECT 'webListen', '127.0.0.1' "
      "WHERE NOT EXISTS (SELECT 1 FROM settings WHERE key = 'webListen');";

  /// Выбор самого быстрого SNI из списка (null, если все недоступны).
  Future<Map<String, String>?> _pickFastestSni(List<String> candidates) async {
    if (candidates.isEmpty) return null;

    String? bestSni;
    double bestPing = double.infinity;

    for (final candidate in candidates) {
      try {
        final stopwatch = Stopwatch()..start();

        final socket = await SecureSocket.connect(
          candidate,
          443,
          timeout: const Duration(seconds: 3),
          supportedProtocols: ['h2', 'http/1.1'],
        );

        stopwatch.stop();
        socket.destroy();

        final ping = stopwatch.elapsedMilliseconds.toDouble();
        _log('  • $candidate: ${ping.toStringAsFixed(0)}ms');

        if (ping < bestPing) {
          bestPing = ping;
          bestSni = candidate;
        }
      } catch (e) {
        _log('  • $candidate: недоступен');
      }
    }

    if (bestSni == null) {
      return null;
    }

    _log(
      '✅ Выбран SNI: $bestSni (${bestPing.toStringAsFixed(0)}ms)',
      type: DeploymentLogType.success,
    );

    return {'sni': bestSni, 'ping': bestPing.toStringAsFixed(0)};
  }

  /// TCP-only probe with bounded retries; injectable for deterministic tests.
  static Future<bool> probeTcpPort(
    String host,
    int port, {
    Future<void> Function(String, int, Duration)? connect,
    Future<void> Function(Duration)? delay,
  }) async {
    final pause = delay ?? Future<void>.delayed;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        if (connect != null) {
          await connect(host, port, const Duration(seconds: 5));
        } else {
          final socket = await Socket.connect(
            host,
            port,
            timeout: const Duration(seconds: 5),
          );
          socket.destroy();
        }
        return true;
      } catch (_) {
        if (attempt < 2) await pause(const Duration(seconds: 2));
      }
    }
    return false;
  }

  static Future<Map<int, bool>> probeTcpPorts(
    String host,
    List<int> ports, {
    Future<void> Function(String, int, Duration)? connect,
    Future<void> Function(Duration)? delay,
  }) async {
    final entries = await Future.wait(
      ports.toSet().map(
        (port) async => MapEntry(
          port,
          await probeTcpPort(host, port, connect: connect, delay: delay),
        ),
      ),
    );
    return Map.fromEntries(entries);
  }

  static List<int> parseXrayListeningPorts(String output, List<int> expected) {
    return output
        .split('\n')
        .map(
          (line) =>
              RegExp(r'^MBX_XRAY_LISTENING:(\d+)$').firstMatch(line.trim()),
        )
        .whereType<RegExpMatch>()
        .map((m) => int.parse(m.group(1)!))
        .where(expected.contains)
        .toSet()
        .toList()
      ..sort();
  }

  /// Generates a client link shared by deployment and server management.
  static String buildVlessLink({
    required String server,
    required int port,
    required String uuid,
    required String publicKey,
    required String shortId,
    required String sni,
    String fingerprint = 'firefox',
    required String remark,
    String transport = 'tcp',
    String xhttpPath = '/',
    Map<String, dynamic>? xhttpExtra,
  }) {
    final extra = transport == 'xhttp' ? xhttpExtra : null;
    return Uri(
      scheme: 'vless',
      userInfo: uuid,
      host: server,
      port: port,
      queryParameters: {
        'security': 'reality',
        'type': transport,
        // Vision — только для голого TCP; на XHTTP он не работает.
        if (transport == 'tcp') 'flow': 'xtls-rprx-vision',
        if (transport == 'xhttp') 'path': xhttpPath,
        if (transport == 'xhttp') 'mode': 'auto',
        if (extra != null && extra['xPaddingBytes'] is String)
          'x_padding_bytes': extra['xPaddingBytes'] as String,
        if (extra != null) 'extra': jsonEncode(extra),
        'pbk': publicKey,
        'sid': shortId,
        'sni': sni,
        'fp': fingerprint,
      },
      fragment: remark,
    ).toString();
  }

  Future<void> removeXuiFromServer(ServerConfig config) async {
    try {
      _log('🗑️ Удаление 3X-UI с сервера...');

      await _connectSSH(config);
      final isRoot = config.sshUser == 'root';

      final removeScript = '''
systemctl stop x-ui 2>/dev/null || true
systemctl disable x-ui 2>/dev/null || true
rm -rf /usr/local/x-ui
rm -rf /etc/x-ui
rm -f /etc/systemd/system/x-ui.service
systemctl daemon-reload
''';

      await _runCommand(removeScript, config.sshPassword, isRoot);
      _log('✅ 3X-UI полностью удалена', type: DeploymentLogType.success);
    } catch (e) {
      _log('❌ Ошибка удаления: $e', type: DeploymentLogType.error);
      rethrow;
    } finally {
      _client?.close();
      _client = null;
      _activeConfig = null;
    }
  }

  Future<Map<String, dynamic>> checkServerTraffic(
    String ipAddress,
    int port,
  ) async {
    final reachable = await probeTcpPort(ipAddress, port);
    return {
      'verified': false,
      'httpCode': 0,
      'portReachable': reachable,
      'error': reachable ? null : 'TCP-порт недоступен с ПК',
    };
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

  String _generateShortId() {
    final random = Random.secure();
    return List.generate(
      8,
      (_) => random.nextInt(256),
    ).map((e) => e.toRadixString(16).padLeft(2, '0')).join();
  }

  String _generatePassword(int length) {
    const chars =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final random = Random.secure();
    return List.generate(
      length,
      (_) => chars[random.nextInt(chars.length)],
    ).join();
  }

  /// Генерация секретного пути для панели 3X-UI (webBasePath).
  /// Формат: `admin-7a9f2b` — панель невидима для внешних сканеров.
  String _generateRandomPath() {
    final random = Random.secure();
    const words = [
      'admin',
      'panel',
      'manage',
      'console',
      'dashboard',
      'portal',
    ];
    final word = words[random.nextInt(words.length)];
    final suffix = random.nextInt(0xFFFFFF).toRadixString(16).padLeft(6, '0');
    return '$word-$suffix';
  }

  // ============ НОВЫЕ ФУНКЦИИ: Стелс+ и Самолечение ============

  /// Отключает IPv6 с сохранением настройки в sysctl.d.
  Future<void> _disableIpv6IfNeeded(String password, bool isRoot) async {
    _log('🌐 Отключение IPv6 (персистентно через sysctl.d)...');
    await _runCommand(ShellScripts.disableIpv6, password, isRoot);
    _log(
      '✅ IPv6 отключён (sysctl.d/99-disable-ipv6.conf)',
      type: DeploymentLogType.success,
    );
  }

  /// Создание файла подкачки 2GB если его нет или мало
  Future<void> _setupSwapIfNeeded(String password, bool isRoot) async {
    try {
      _log('💾 Проверка файла подкачки...');

      final checkSwap = "free -m | awk '/Swap/{print \$2}'";
      final swapSize = await _runCommand(checkSwap, password, isRoot);
      final swapMb = int.tryParse(swapSize.trim()) ?? 0;

      if (swapMb < 1500) {
        _log('💾 Создание swap 2GB...');

        final output = await _runCommand(
          ShellScripts.setupSwap,
          password,
          isRoot,
        );
        _log(
          output.contains('MBX_SWAP_ALREADY_ACTIVE')
              ? '✅ /swapfile уже подключён; форматирование пропущено'
              : '✅ Swap создан и подключён',
        );
      } else {
        _log('✅ Swap уже настроен (${swapMb}MB)');
      }
    } catch (e) {
      _log('⚠️ Ошибка настройки swap: $e', type: DeploymentLogType.warning);
    }
  }

  /// Установка Cloudflare WARP и настройка WireGuard-outbound «warp» в Xray.
  /// Через WARP идут только ChatGPT / Claude / Netflix / Google,
  /// остальной трафик остаётся на «direct» для максимальной скорости.

  /// Настройка Telegram-бота панели 3X-UI (авто-бэкапы и уведомления).
  /// Прописывает tgBotEnable / tgBotToken / tgBotChatId / tgBotBackup
  /// в таблицу `settings` базы /etc/x-ui/x-ui.db и перезапускает x-ui.
  Future<void> _configureTelegramBot(
    String password,
    bool isRoot,
    String botToken,
    String chatId,
  ) async {
    try {
      _log('📱 Настройка Telegram-бота...');

      await _runCommand(
        WarpService.telegramSql(botToken, chatId),
        password,
        isRoot,
      );
      _log('✅ Telegram-бот настроен (авто-бэкапы включены)');
    } catch (e) {
      _log('⚠️ Ошибка настройки Telegram: $e', type: DeploymentLogType.warning);
    }
  }

  /// Установка сторожевого таймера (Watchdog) с Telegram-уведомлениями
  Future<void> _setupWatchdog(
    String password,
    bool isRoot,
    String serverIp,
    String? botToken,
    String? chatId,
  ) async {
    if (botToken == null || chatId == null) {
      _log('⚠️ Watchdog пропущен: не заданы Telegram токен и Chat ID');
      return;
    }

    try {
      _log('🐕 Установка сторожевого таймера...');

      final watchdogScript =
          '''#!/bin/bash
# MegaBox Watchdog Script (проверка каждые 5 минут через cron)
BOT_TOKEN=${shellQuote(botToken)}
CHAT_ID=${shellQuote(chatId)}
SERVER_IP=${shellQuote(serverIp)}
LOCK=/var/run/mbx-watchdog.lock

send_telegram() {
    curl -s -m 10 -X POST "https://api.telegram.org/bot\${BOT_TOKEN}/sendMessage" \\
         -d chat_id="\${CHAT_ID}" \\
         -d text="\$1" \\
         -d parse_mode="HTML" >/dev/null 2>&1
}

# Защита от параллельного запуска
if [ -e "\$LOCK" ]; then
    exit 0
fi
touch "\$LOCK"
trap 'rm -f "\$LOCK"' EXIT

NEED_RESTART=0

# 1. Проверка процесса Xray
if ! pgrep -f xray-linux >/dev/null 2>&1; then
    NEED_RESTART=1
fi

# 2. Проверка интернета через локальный туннель Cloudflare
if ! curl -m 5 -s https://cp.cloudflare.com/generate_204 >/dev/null 2>&1; then
    NEED_RESTART=1
fi

# Всё в порядке
if [ "\$NEED_RESTART" -eq 0 ]; then
    exit 0
fi

send_telegram "🚨 ВНИМАНИЕ! Сервер \$SERVER_IP потерял связь или служба Xray упала. Произведена попытка авто-перезагрузки."
systemctl restart x-ui >/dev/null 2>&1
sleep 10

OK=1
if ! pgrep -f xray-linux >/dev/null 2>&1; then
    OK=0
fi
if ! curl -m 5 -s https://cp.cloudflare.com/generate_204 >/dev/null 2>&1; then
    OK=0
fi

if [ "\$OK" -eq 1 ]; then
    send_telegram "✅ Сервер \$SERVER_IP восстановил работу в штатном режиме."
    exit 0
fi

send_telegram "⚠️ Сервер \$SERVER_IP: авто-перезапуск службы не помог. Выполняю перезагрузку сервера."
sync
reboot
''';

      // Записываем скрипт через безопасный heredoc
      const scriptPath = '/usr/local/bin/mbx-watchdog.sh';
      final writeCmd =
          "cat > $scriptPath << 'MBX_WATCHDOG_EOF'\n$watchdogScript\nMBX_WATCHDOG_EOF";
      await _runCommand(writeCmd, password, isRoot);
      await _runCommand('chmod 700 $scriptPath', password, isRoot);

      // Регистрируем в cron: каждые 5 минут
      const cronLine =
          '*/5 * * * * /bin/bash /usr/local/bin/mbx-watchdog.sh >/dev/null 2>&1';
      final cronCmd =
          '(crontab -l 2>/dev/null | grep -v "mbx-watchdog.sh"; '
          'echo "$cronLine") | crontab -';
      await _runCommand(cronCmd, password, isRoot);

      _log('✅ Watchdog установлен (проверка каждые 5 минут)');
    } catch (e) {
      _log('⚠️ Ошибка установки Watchdog: $e', type: DeploymentLogType.warning);
    }
  }

  /// Маскировка панели 3X-UI за фейковым сайтом-заглушкой (Decoy Website).
  ///
  /// Устанавливает Caddy, который на портах 80/443 отдаёт статичный
  /// сайт-пустышку «Personal Portfolio / Under Construction».
  /// Панель остаётся доступной только по секретному пути `webBasePath`
  /// (например `/admin-7a9f2b/`), который проксируется на локальный порт панели.
  /// Для внешних сканеров админка становится полностью невидимой.
  Future<void> _setupDecoyWebsite(
    String password,
    bool isRoot, {
    required String serverIp,
    required int panelPort,
    required String panelPath,
  }) async {
    try {
      _log('🥷 Маскировка панели 3X-UI за фейковым сайтом...');

      // Порт, на котором Caddy отдаёт сайт-заглушку и проксирует панель
      const int decoyHttpsPort = 443;

      // 1. Установка Caddy
      // Перед установкой снимаем блокировки apt/dpkg: на медленных VPS
      // фоновый unattended-upgrades может держать менеджер пакетов часами.
      final installCaddy =
          '''
export DEBIAN_FRONTEND=noninteractive
if ! command -v caddy >/dev/null 2>&1; then
${ShellScripts.aptUnlock}
  apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl >/dev/null 2>&1 || true
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null || true
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list 2>/dev/null || true
  apt-get update -qq || true
  apt-get -o DPkg::Lock::Timeout=120 -y install caddy >/dev/null 2>&1 || true
fi
command -v caddy >/dev/null 2>&1 && echo "CADDY_OK" || echo "CADDY_MISSING"
''';
      final caddyCheck = await _runCommand(installCaddy, password, isRoot);

      // 2. Сайт-заглушка
      final decoyHtml = '''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Personal Portfolio — Under Construction</title>
<style>
  html,body{margin:0;padding:0;height:100%;background:#0d1117;color:#e6edf3;
    font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}
  .wrap{height:100%;display:flex;align-items:center;justify-content:center;text-align:center}
  h1{font-size:34px;font-weight:600;margin:0 0 12px;letter-spacing:-.5px}
  p{color:#8b949e;margin:0;font-size:15px}
  .dot{display:inline-block;width:8px;height:8px;border-radius:50%;background:#238636;margin-right:8px}
</style>
</head>
<body>
  <div class="wrap">
    <div>
      <h1>Personal Portfolio</h1>
      <p><span class="dot"></span>Under Construction — coming soon</p>
    </div>
  </div>
</body>
</html>''';

      final decoyScript =
          '''
mkdir -p /var/www/decoy
cat > /var/www/decoy/index.html << 'DECOY_HTML_EOF'
$decoyHtml
DECOY_HTML_EOF
chmod -R 755 /var/www/decoy
''';
      await _runCommand(decoyScript, password, isRoot);

      // 3. Конфигурация Caddy: заглушка на /, панель — на секретном пути
      final caddyfile =
          '''{
    admin off
    auto_https off
}

:$decoyHttpsPort {
    root * /var/www/decoy
    encode gzip
    file_server

    # Секретный путь панели 3X-UI (webBasePath)
    handle_path /$panelPath/* {
        reverse_proxy 127.0.0.1:$panelPort {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
        }
    }

    handle {
        root * /var/www/decoy
        file_server
    }
}
''';

      final caddyWrite =
          '''
cat > /etc/caddy/Caddyfile << 'CADDY_EOF'
$caddyfile
CADDY_EOF
caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1 && echo "CADDY_VALID" || echo "CADDY_INVALID"
''';
      final validate = await _runCommand(caddyWrite, password, isRoot);

      // 4. Запуск Caddy
      await _runCommand(
        'systemctl enable caddy >/dev/null 2>&1 || true; '
        'systemctl restart caddy >/dev/null 2>&1 || true; '
        'systemctl is-active caddy || echo "inactive"',
        password,
        isRoot,
      );

      // 5. Открываем порты в ufw
      await _runCommand(
        'ufw allow 80/tcp >/dev/null 2>&1 || true; '
        'ufw allow 443/tcp >/dev/null 2>&1 || true',
        password,
        isRoot,
      );

      if (caddyCheck.contains('CADDY_MISSING')) {
        _log(
          '⚠️ Caddy не установился — маскировка панели пропущена',
          type: DeploymentLogType.warning,
        );
        return;
      }
      if (validate.contains('CADDY_INVALID')) {
        _log(
          '⚠️ Caddyfile не прошёл валидацию — проверьте конфигурацию',
          type: DeploymentLogType.warning,
        );
        return;
      }

      _log('✅ Панель скрыта за фейковым сайтом (Decoy Website)');
      _log('   Обычный адрес http://$serverIp → сайт-заглушка');
      _log('   Админка доступна только по http://$serverIp/$panelPath');
    } catch (e) {
      _log('⚠️ Ошибка маскировки панели: $e', type: DeploymentLogType.warning);
    }
  }
}
