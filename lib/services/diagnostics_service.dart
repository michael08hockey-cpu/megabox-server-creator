import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';

import 'host_key_store.dart';
import 'remote_executor.dart';

/// Итог одной проверки.
enum DiagStatus { ok, info, warn, fail }

/// Одна строка отчёта диагностики.
class DiagCheck {
  const DiagCheck({
    required this.id,
    required this.title,
    required this.status,
    required this.detail,
    this.hint,
  });

  final String id;
  final String title;
  final DiagStatus status;
  final String detail;

  /// Что делать, если проверка не прошла.
  final String? hint;

  @override
  String toString() => '[$status] $title: $detail';
}

/// Полный отчёт диагностики сервера.
class DiagReport {
  DiagReport(this.checks, {DateTime? at}) : at = at ?? DateTime.now();

  final List<DiagCheck> checks;
  final DateTime at;

  bool get hasFail => checks.any((c) => c.status == DiagStatus.fail);
  bool get hasWarn => checks.any((c) => c.status == DiagStatus.warn);

  DiagStatus get overall => hasFail
      ? DiagStatus.fail
      : (hasWarn ? DiagStatus.warn : DiagStatus.ok);

  /// Короткий вердикт для шапки отчёта.
  String get verdict => switch (overall) {
    DiagStatus.fail => 'Есть серьёзные проблемы — настраивать пока не стоит',
    DiagStatus.warn => 'Можно настраивать, но есть замечания',
    _ => 'Сервер готов к настройке',
  };

  List<DiagCheck> get problems =>
      checks.where((c) => c.status == DiagStatus.fail).toList();
}

/// Результат TCP-проверки порта с устройства пользователя.
enum PortState { open, refused, timeout, unreachable, error }

class PortProbe {
  const PortProbe(this.state, {this.ms, this.message});
  final PortState state;
  final int? ms;
  final String? message;
}

/// Диагностика сервера перед настройкой.
///
/// Делает две вещи:
/// 1. С устройства пользователя (из его сети, обычно из РФ) проверяет,
///    отвечает ли сервер по SSH и по порту VLESS. Если сервер молчит,
///    его IP, скорее всего, уже заблокирован, и настраивать его бесполезно.
/// 2. По SSH одним скриптом собирает состояние сервера: ОС, память, диск,
///    занятость порта, старую установку x-ui, время, доступ в интернет.
class ServerDiagnostics {
  ServerDiagnostics({
    Future<PortProbe> Function(String host, int port)? probe,
    Future<SSHClient> Function(String host, int port, String user, String password)? connect,
    Future<String> Function(SSHClient client, String script, String? sudoPassword)? runScript,
    DateTime Function()? now,
  }) : _probe = probe ?? probePort,
       _connect = connect ?? _defaultConnect,
       _runScript = runScript ?? _defaultRun,
       _now = now ?? DateTime.now;

  final Future<PortProbe> Function(String, int) _probe;
  final Future<SSHClient> Function(String, int, String, String) _connect;
  final Future<String> Function(SSHClient, String, String?) _runScript;
  final DateTime Function() _now;

  // ---------------------------------------------------------------------
  // Проверка порта с устройства
  // ---------------------------------------------------------------------

  /// Коды «соединение отклонено»: Linux/Android, Windows, macOS.
  static const _refusedCodes = <int>{111, 10061, 61};

  /// Коды таймаута: Linux/Android, Windows, macOS.
  static const _timeoutCodes = <int>{110, 10060, 60};

  /// Коды «сеть/хост недоступны».
  static const _unreachableCodes = <int>{101, 113, 10051, 10065, 51, 65};

  /// TCP-проверка порта: отличает «закрыт, но хост живой» (RST)
  /// от «пакеты пропадают» (таймаут) — второе типично для блокировки.
  static Future<PortProbe> probePort(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final sw = Stopwatch()..start();
    try {
      final socket = await Socket.connect(host, port, timeout: timeout);
      sw.stop();
      socket.destroy();
      return PortProbe(PortState.open, ms: sw.elapsedMilliseconds);
    } on SocketException catch (e) {
      sw.stop();
      return classifySocketError(
        e.osError?.errorCode,
        e.message,
        elapsed: sw.elapsed,
        timeout: timeout,
      );
    } catch (e) {
      return PortProbe(PortState.error, message: '$e');
    }
  }

  /// Разбор ошибки сокета (вынесен отдельно ради тестов).
  static PortProbe classifySocketError(
    int? code,
    String message, {
    required Duration elapsed,
    required Duration timeout,
  }) {
    final lower = message.toLowerCase();
    if (code != null && _refusedCodes.contains(code) ||
        lower.contains('refused')) {
      return PortProbe(PortState.refused, ms: elapsed.inMilliseconds, message: message);
    }
    if (code != null && _timeoutCodes.contains(code) ||
        lower.contains('timed out') ||
        elapsed >= timeout - const Duration(milliseconds: 200)) {
      return PortProbe(PortState.timeout, message: message);
    }
    if (code != null && _unreachableCodes.contains(code) ||
        lower.contains('unreachable')) {
      return PortProbe(PortState.unreachable, message: message);
    }
    return PortProbe(PortState.error, message: message);
  }

  /// Оценка доступности сервера из сети пользователя.
  static List<DiagCheck> reachabilityChecks({
    required PortProbe ssh,
    required PortProbe vless,
    required int sshPort,
    required int vlessPort,
  }) {
    final checks = <DiagCheck>[];

    switch (ssh.state) {
      case PortState.open:
        checks.add(DiagCheck(
          id: 'reach_ssh',
          title: 'Связь с сервером из твоей сети',
          status: (ssh.ms ?? 0) > 400 ? DiagStatus.warn : DiagStatus.ok,
          detail: 'SSH-порт $sshPort отвечает, ${ssh.ms} мс',
          hint: (ssh.ms ?? 0) > 400
              ? 'Очень большая задержка: VPN через этот сервер будет медленным'
              : null,
        ));
      case PortState.refused:
        checks.add(DiagCheck(
          id: 'reach_ssh',
          title: 'Связь с сервером из твоей сети',
          status: DiagStatus.fail,
          detail: 'Сервер доступен, но порт $sshPort закрыт',
          hint: 'Проверь порт SSH в панели хостинга (обычно 22)',
        ));
      case PortState.timeout:
        checks.add(const DiagCheck(
          id: 'reach_ssh',
          title: 'Связь с сервером из твоей сети',
          status: DiagStatus.fail,
          detail: 'Сервер не отвечает: пакеты пропадают',
          hint: 'Если сервер включён в панели хостинга, его IP, скорее всего, '
              'уже заблокирован в РФ. Возьми другой сервер (новый IP)',
        ));
      case PortState.unreachable:
      case PortState.error:
        checks.add(DiagCheck(
          id: 'reach_ssh',
          title: 'Связь с сервером из твоей сети',
          status: DiagStatus.fail,
          detail: 'Не удалось подключиться: ${ssh.message ?? 'сеть недоступна'}',
          hint: 'Проверь IP-адрес и интернет на устройстве',
        ));
    }

    // Порт VLESS имеет смысл оценивать, только если хост вообще живой.
    if (ssh.state == PortState.open || ssh.state == PortState.refused) {
      switch (vless.state) {
        case PortState.open:
          checks.add(DiagCheck(
            id: 'reach_vless',
            title: 'Порт $vlessPort из твоей сети',
            status: DiagStatus.ok,
            detail: 'Отвечает, ${vless.ms} мс',
          ));
        case PortState.refused:
          checks.add(DiagCheck(
            id: 'reach_vless',
            title: 'Порт $vlessPort из твоей сети',
            status: DiagStatus.ok,
            detail: 'Доходит до сервера (порт пока свободен — до установки так и должно быть)',
          ));
        case PortState.timeout:
          checks.add(DiagCheck(
            id: 'reach_vless',
            title: 'Порт $vlessPort из твоей сети',
            status: DiagStatus.warn,
            detail: 'SSH проходит, а порт $vlessPort молчит',
            hint: 'Так бывает при фаерволе на сервере или блокировке порта по пути. '
                'Если ниже фаервол выключен — похоже на фильтрацию, VPN может не работать',
          ));
        case PortState.unreachable:
        case PortState.error:
          checks.add(DiagCheck(
            id: 'reach_vless',
            title: 'Порт $vlessPort из твоей сети',
            status: DiagStatus.warn,
            detail: 'Не удалось проверить: ${vless.message ?? 'ошибка'}',
          ));
      }
    }
    return checks;
  }

  // ---------------------------------------------------------------------
  // Скрипт на сервере
  // ---------------------------------------------------------------------

  /// Скрипт сбора состояния. Печатает строки key=value и всегда
  /// завершается кодом 0. Порт VLESS передаётся числом, без кавычек.
  static String preflightScript(int vlessPort) {
    if (vlessPort < 1 || vlessPort > 65535) {
      throw ArgumentError.value(vlessPort, 'vlessPort');
    }
    return '''
export LC_ALL=C
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:\$PATH
MBX_PORT=$vlessPort
''' r'''
kv() { printf '%s=%s\n' "$1" "$(printf '%s' "$2" | tr -d '\r\n' | cut -c1-200)"; }
if [ -r /etc/os-release ]; then . /etc/os-release; fi
kv os_id "${ID:-unknown}"
kv os_ver "${VERSION_ID:-}"
kv os_name "${PRETTY_NAME:-}"
kv arch "$(uname -m 2>/dev/null)"
kv kernel "$(uname -r 2>/dev/null)"
kv virt "$(systemd-detect-virt 2>/dev/null || echo unknown)"
kv cpus "$(nproc 2>/dev/null || echo 1)"
kv ram_mb "$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)"
kv swap_mb "$(awk '/^SwapTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)"
kv disk_free_mb "$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}')"
kv load "$(cut -d' ' -f1 /proc/loadavg 2>/dev/null)"
kv uid "$(id -u)"
kv epoch "$(date +%s)"
kv ntp "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo unknown)"
if command -v apt-get >/dev/null 2>&1; then kv pkg apt
elif command -v dnf >/dev/null 2>&1; then kv pkg dnf
elif command -v yum >/dev/null 2>&1; then kv pkg yum
else kv pkg none; fi
if command -v ss >/dev/null 2>&1; then
  L=$(ss -Hltnp "sport = :$MBX_PORT" 2>/dev/null | head -n1)
  if [ -n "$L" ]; then
    kv port_busy 1
    kv port_proc "$(printf '%s' "$L" | grep -o 'users:(("[^"]*' | head -n1 | sed 's/users:(("//')"
  else
    kv port_busy 0
  fi
else
  kv port_busy unknown
fi
if [ -x /usr/local/x-ui/x-ui ] || [ -f /etc/x-ui/x-ui.db ]; then kv xui installed; else kv xui none; fi
kv xui_active "$(systemctl is-active x-ui 2>/dev/null || echo inactive)"
if getent ahostsv4 github.com >/dev/null 2>&1; then kv dns ok; else kv dns fail; fi
if command -v curl >/dev/null 2>&1; then
  kv net_github "$(curl -sS -m 8 -o /dev/null -w '%{http_code}' https://github.com 2>/dev/null || true)"
  kv net_raw "$(curl -sS -m 8 -o /dev/null -w '%{http_code}' https://raw.githubusercontent.com 2>/dev/null || true)"
  G=$(curl -sS -m 6 https://ipinfo.io/json 2>/dev/null || true)
  kv geo_ip "$(printf '%s' "$G" | sed -n 's/.*"ip": *"\([^"]*\)".*/\1/p' | head -n1)"
  kv geo_country "$(printf '%s' "$G" | sed -n 's/.*"country": *"\([^"]*\)".*/\1/p' | head -n1)"
  kv geo_org "$(printf '%s' "$G" | sed -n 's/.*"org": *"\([^"]*\)".*/\1/p' | head -n1)"
else
  kv net_github nocurl
fi
if pgrep -x 'apt|apt-get|dpkg|unattended-upgr' >/dev/null 2>&1; then kv apt_busy 1; else kv apt_busy 0; fi
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then kv firewall ufw
elif systemctl is-active firewalld >/dev/null 2>&1; then kv firewall firewalld
else kv firewall none; fi
kv bbr "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
if ip -6 addr show scope global 2>/dev/null | grep -q inet6; then kv ipv6 1; else kv ipv6 0; fi
echo MBX_DIAG_DONE
true
''';
  }

  /// Разбор строк key=value в словарь.
  static Map<String, String> parseKv(String output) {
    final map = <String, String>{};
    for (final raw in output.split('\n')) {
      final line = raw.trim();
      final i = line.indexOf('=');
      if (i <= 0) continue;
      final key = line.substring(0, i);
      if (!RegExp(r'^[a-z_0-9]+$').hasMatch(key)) continue;
      map[key] = line.substring(i + 1);
    }
    return map;
  }

  static int? _int(String? v) => v == null ? null : int.tryParse(v.trim());

  /// Сравнение версий вида «22.04» >= «20.04».
  static bool _versionAtLeast(String version, int major, [int minor = 0]) {
    final parts = version.split('.');
    final ma = int.tryParse(parts.first) ?? 0;
    final mi = parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0;
    return ma > major || (ma == major && mi >= minor);
  }

  /// Превращает вывод [preflightScript] в список проверок.
  static List<DiagCheck> parsePreflight(
    String output, {
    required int vlessPort,
    DateTime? deviceTime,
    bool sudoOk = true,
  }) {
    final kv = parseKv(output);
    final checks = <DiagCheck>[];

    if (!output.contains('MBX_DIAG_DONE')) {
      checks.add(const DiagCheck(
        id: 'script',
        title: 'Скрипт проверки',
        status: DiagStatus.warn,
        detail: 'Скрипт отработал не полностью, часть данных может отсутствовать',
      ));
    }

    // --- ОС ---
    final osId = (kv['os_id'] ?? 'unknown').toLowerCase();
    final osVer = kv['os_ver'] ?? '';
    final osName = (kv['os_name'] ?? '').isEmpty ? '$osId $osVer' : kv['os_name']!;
    final pkg = kv['pkg'] ?? 'none';
    if (pkg == 'none') {
      checks.add(DiagCheck(
        id: 'os',
        title: 'Операционная система',
        status: DiagStatus.fail,
        detail: '$osName — нет менеджера пакетов',
        hint: 'Переустанови сервер на Ubuntu 22.04/24.04 в панели хостинга',
      ));
    } else if (osId == 'ubuntu') {
      final good = _versionAtLeast(osVer, 20, 4);
      checks.add(DiagCheck(
        id: 'os',
        title: 'Операционная система',
        status: good ? DiagStatus.ok : DiagStatus.warn,
        detail: osName,
        hint: good ? null : 'Старая Ubuntu. Лучше переустановить на 22.04 или 24.04',
      ));
    } else if (osId == 'debian') {
      final good = _versionAtLeast(osVer, 11);
      checks.add(DiagCheck(
        id: 'os',
        title: 'Операционная система',
        status: good ? DiagStatus.ok : DiagStatus.warn,
        detail: osName,
        hint: good ? null : 'Старый Debian. Лучше Debian 12 или Ubuntu 24.04',
      ));
    } else {
      checks.add(DiagCheck(
        id: 'os',
        title: 'Операционная система',
        status: DiagStatus.warn,
        detail: osName,
        hint: 'Приложение рассчитано на Ubuntu/Debian. Надёжнее переустановить на Ubuntu 24.04',
      ));
    }

    // --- Архитектура ---
    final arch = kv['arch'] ?? '';
    const goodArch = {'x86_64', 'amd64', 'aarch64', 'arm64'};
    checks.add(DiagCheck(
      id: 'arch',
      title: 'Процессор',
      status: goodArch.contains(arch) ? DiagStatus.ok : DiagStatus.fail,
      detail: '${arch.isEmpty ? 'неизвестно' : arch}, ядер: ${kv['cpus'] ?? '?'}',
      hint: goodArch.contains(arch) ? null : '3X-UI поддерживает только x86_64 и arm64',
    ));

    // --- Виртуализация ---
    final virt = (kv['virt'] ?? 'unknown').toLowerCase();
    final container = const {'openvz', 'lxc', 'lxc-libvirt', 'docker', 'podman', 'systemd-nspawn'}.contains(virt);
    checks.add(DiagCheck(
      id: 'virt',
      title: 'Виртуализация',
      status: container ? DiagStatus.warn : DiagStatus.ok,
      detail: virt == 'none' ? 'выделенный сервер' : virt,
      hint: container
          ? 'Контейнер ($virt): не работают swap, BBR и часть настроек ядра. Лучше KVM'
          : null,
    ));

    // --- Память ---
    final ram = _int(kv['ram_mb']);
    final swap = _int(kv['swap_mb']) ?? 0;
    if (ram != null) {
      final DiagStatus st;
      String? hint;
      if (ram < 400) {
        st = DiagStatus.fail;
        hint = 'Меньше 400 МБ: Xray и панель могут не запуститься. Нужен тариф от 512 МБ';
      } else if (ram < 900 && swap < 256) {
        st = DiagStatus.warn;
        hint = 'Памяти мало — при настройке будет создан файл подкачки (swap)';
      } else {
        st = DiagStatus.ok;
      }
      checks.add(DiagCheck(
        id: 'ram',
        title: 'Оперативная память',
        status: st,
        detail: '$ram МБ${swap > 0 ? ' + swap $swap МБ' : ''}',
        hint: hint,
      ));
    }

    // --- Диск ---
    final disk = _int(kv['disk_free_mb']);
    if (disk != null) {
      final st = disk < 1024
          ? DiagStatus.fail
          : (disk < 2500 ? DiagStatus.warn : DiagStatus.ok);
      checks.add(DiagCheck(
        id: 'disk',
        title: 'Свободное место',
        status: st,
        detail: disk >= 1024
            ? '${(disk / 1024).toStringAsFixed(1)} ГБ'
            : '$disk МБ',
        hint: st == DiagStatus.fail
            ? 'Меньше 1 ГБ — установка не поместится. Почисти диск или смени тариф'
            : (st == DiagStatus.warn ? 'Места впритык, логи могут забить диск' : null),
      ));
    }

    // --- Права ---
    final uid = _int(kv['uid']);
    if (uid != 0 || !sudoOk) {
      checks.add(const DiagCheck(
        id: 'root',
        title: 'Права администратора',
        status: DiagStatus.fail,
        detail: 'Нет прав root/sudo',
        hint: 'Войди под root или под пользователем с sudo и правильным паролем',
      ));
    } else {
      checks.add(const DiagCheck(
        id: 'root',
        title: 'Права администратора',
        status: DiagStatus.ok,
        detail: 'Есть',
      ));
    }

    // --- Время ---
    final epoch = _int(kv['epoch']);
    final ntp = (kv['ntp'] ?? 'unknown').toLowerCase();
    if (epoch != null && deviceTime != null) {
      final skew = (epoch - deviceTime.millisecondsSinceEpoch ~/ 1000).abs();
      final DiagStatus st;
      if (skew > 90) {
        st = DiagStatus.warn;
      } else {
        st = DiagStatus.ok;
      }
      checks.add(DiagCheck(
        id: 'time',
        title: 'Часы сервера',
        status: st,
        detail: skew <= 2
            ? 'Точные${ntp == 'yes' ? ' (синхронизация включена)' : ''}'
            : 'Расходятся с устройством на $skew сек',
        hint: st == DiagStatus.warn
            ? 'Сбитые часы ломают TLS и Reality. При настройке будет включена синхронизация времени'
            : null,
      ));
    }

    // --- Порт VLESS ---
    final busy = kv['port_busy'];
    final proc = (kv['port_proc'] ?? '').toLowerCase();
    if (busy == '1') {
      final ours = proc.contains('xray') || proc.contains('x-ui');
      checks.add(DiagCheck(
        id: 'port',
        title: 'Порт $vlessPort на сервере',
        status: ours ? DiagStatus.info : DiagStatus.warn,
        detail: 'Занят: ${proc.isEmpty ? 'неизвестная программа' : proc}',
        hint: ours
            ? 'Это старый Xray/3X-UI — при настройке он будет переустановлен'
            : 'Порт занят другой программой. Её придётся остановить, или выбери другой порт VLESS',
      ));
    } else if (busy == '0') {
      checks.add(DiagCheck(
        id: 'port',
        title: 'Порт $vlessPort на сервере',
        status: DiagStatus.ok,
        detail: 'Свободен',
      ));
    }

    // --- Старая установка ---
    if (kv['xui'] == 'installed') {
      checks.add(DiagCheck(
        id: 'xui',
        title: '3X-UI',
        status: DiagStatus.info,
        detail: 'Уже установлена (${kv['xui_active'] == 'active' ? 'работает' : 'остановлена'})',
        hint: 'При развёртывании будет чистая переустановка, старые ключи перестанут работать',
      ));
    } else {
      checks.add(const DiagCheck(
        id: 'xui',
        title: '3X-UI',
        status: DiagStatus.ok,
        detail: 'Не установлена — чистый сервер',
      ));
    }

    // --- Интернет на сервере ---
    final dnsOk = kv['dns'] == 'ok';
    final gh = kv['net_github'] ?? '';
    final raw = kv['net_raw'] ?? '';
    bool reached(String code) {
      final n = int.tryParse(code);
      return n != null && n > 0 && n < 600;
    }
    if (!dnsOk) {
      checks.add(const DiagCheck(
        id: 'net',
        title: 'Интернет на сервере',
        status: DiagStatus.fail,
        detail: 'Не работает DNS',
        hint: 'Сервер не может найти github.com. Пропиши DNS 1.1.1.1 в /etc/resolv.conf или напиши в поддержку хостинга',
      ));
    } else if (gh == 'nocurl') {
      checks.add(const DiagCheck(
        id: 'net',
        title: 'Интернет на сервере',
        status: DiagStatus.info,
        detail: 'curl не установлен — проверить не удалось (поставится при настройке)',
      ));
    } else if (reached(gh) && reached(raw)) {
      checks.add(const DiagCheck(
        id: 'net',
        title: 'Интернет на сервере',
        status: DiagStatus.ok,
        detail: 'GitHub доступен',
      ));
    } else {
      checks.add(DiagCheck(
        id: 'net',
        title: 'Интернет на сервере',
        status: DiagStatus.fail,
        detail: reached(gh) ? 'raw.githubusercontent.com недоступен' : 'GitHub недоступен',
        hint: 'Без доступа к GitHub не скачать 3X-UI и Xray. Напиши в поддержку хостинга',
      ));
    }

    // --- Менеджер пакетов занят ---
    if (kv['apt_busy'] == '1') {
      checks.add(const DiagCheck(
        id: 'apt',
        title: 'Автообновление системы',
        status: DiagStatus.info,
        detail: 'Сейчас идёт установка обновлений',
        hint: 'Ничего страшного: приложение подождёт его окончания',
      ));
    }

    // --- Фаервол ---
    final fw = kv['firewall'] ?? 'none';
    if (fw == 'ufw') {
      checks.add(const DiagCheck(
        id: 'firewall',
        title: 'Фаервол',
        status: DiagStatus.info,
        detail: 'ufw включён',
        hint: 'Приложение само откроет нужные порты',
      ));
    } else if (fw == 'firewalld') {
      checks.add(DiagCheck(
        id: 'firewall',
        title: 'Фаервол',
        status: DiagStatus.warn,
        detail: 'firewalld включён',
        hint: 'Приложение не настраивает firewalld: открой порт $vlessPort вручную '
            '(firewall-cmd --permanent --add-port=$vlessPort/tcp && firewall-cmd --reload)',
      ));
    } else {
      checks.add(const DiagCheck(
        id: 'firewall',
        title: 'Фаервол',
        status: DiagStatus.ok,
        detail: 'Выключен',
      ));
    }

    // --- Сеть сервера (справочно) ---
    final org = kv['geo_org'] ?? '';
    final country = kv['geo_country'] ?? '';
    final ip = kv['geo_ip'] ?? '';
    if (org.isNotEmpty || country.isNotEmpty) {
      checks.add(DiagCheck(
        id: 'geo',
        title: 'Сеть сервера',
        status: DiagStatus.info,
        detail: [ip, country, org].where((s) => s.isNotEmpty).join(' · '),
      ));
    }

    final bbr = kv['bbr'] ?? '';
    if (bbr.isNotEmpty) {
      checks.add(DiagCheck(
        id: 'bbr',
        title: 'Ускорение TCP (BBR)',
        status: DiagStatus.info,
        detail: bbr == 'bbr' ? 'Включено' : 'Сейчас $bbr — при настройке будет включён BBR',
      ));
    }

    return checks;
  }

  // ---------------------------------------------------------------------
  // Полный прогон
  // ---------------------------------------------------------------------

  /// Запускает всю диагностику. [onCheck] вызывается для каждой готовой
  /// проверки (для живого отображения), [onProgress] — для текста этапа.
  Future<DiagReport> run({
    required String host,
    required int sshPort,
    required String user,
    required String password,
    required int vlessPort,
    void Function(DiagCheck check)? onCheck,
    void Function(String stage)? onProgress,
  }) async {
    final checks = <DiagCheck>[];
    void add(DiagCheck c) {
      checks.add(c);
      onCheck?.call(c);
    }

    // 1. Доступность из сети пользователя.
    onProgress?.call('Проверяю связь с сервером из твоей сети…');
    final results = await Future.wait([
      _probe(host, sshPort),
      _probe(host, vlessPort),
    ]);
    final reach = reachabilityChecks(
      ssh: results[0],
      vless: results[1],
      sshPort: sshPort,
      vlessPort: vlessPort,
    );
    reach.forEach(add);
    if (results[0].state != PortState.open) {
      return DiagReport(checks, at: _now());
    }

    // 2. SSH-вход.
    onProgress?.call('Вхожу по SSH…');
    SSHClient? client;
    final sw = Stopwatch()..start();
    try {
      client = await _connect(host, sshPort, user, password);
      add(DiagCheck(
        id: 'auth',
        title: 'Вход по SSH',
        status: DiagStatus.ok,
        detail: 'Логин и пароль подошли (${sw.elapsedMilliseconds} мс)',
      ));
    } on SSHAuthFailError {
      add(const DiagCheck(
        id: 'auth',
        title: 'Вход по SSH',
        status: DiagStatus.fail,
        detail: 'Неверный логин или пароль',
        hint: 'Проверь пароль в письме или панели хостинга. Если вход только по ключу — пароль не подойдёт',
      ));
      return DiagReport(checks, at: _now());
    } on SSHHostkeyError {
      add(DiagCheck(
        id: 'auth',
        title: 'Вход по SSH',
        status: DiagStatus.fail,
        detail: HostKeyStore.lastMismatch ?? 'Ключ сервера изменился',
        hint: 'Если ты переустанавливал сервер — это нормально, сбрось сохранённый ключ в «Моих серверах»',
      ));
      return DiagReport(checks, at: _now());
    } catch (e) {
      add(DiagCheck(
        id: 'auth',
        title: 'Вход по SSH',
        status: DiagStatus.fail,
        detail: 'Не удалось войти: $e',
      ));
      return DiagReport(checks, at: _now());
    }

    // 3. Скрипт состояния.
    onProgress?.call('Смотрю, что внутри сервера…');
    try {
      final isRoot = user == 'root';
      final script = preflightScript(vlessPort);
      String output;
      var sudoOk = true;
      if (isRoot) {
        output = await _runScript(client, script, null);
      } else {
        try {
          output = await _runScript(client, script, password);
        } catch (_) {
          // sudo не сработал — соберём что можем без него.
          sudoOk = false;
          output = await _runScript(client, script, null);
        }
      }
      parsePreflight(
        output,
        vlessPort: vlessPort,
        deviceTime: _now(),
        sudoOk: sudoOk,
      ).forEach(add);
    } catch (e) {
      add(DiagCheck(
        id: 'script',
        title: 'Проверка сервера',
        status: DiagStatus.fail,
        detail: 'Не удалось выполнить проверку: $e',
      ));
    } finally {
      client.close();
    }

    onProgress?.call('Готово');
    return DiagReport(checks, at: _now());
  }

  static Future<SSHClient> _defaultConnect(
    String host,
    int port,
    String user,
    String password,
  ) async {
    final socket = await SSHSocket.connect(
      host,
      port,
      timeout: const Duration(seconds: 10),
    );
    final client = SSHClient(
      socket,
      username: user,
      onPasswordRequest: () => password,
      onVerifyHostKey: HostKeyStore.verifier(host, port),
      onUserInfoRequest: (SSHUserInfoRequest request) =>
          request.prompts.map((SSHUserInfoPrompt _) => password).toList(),
    );
    try {
      await client.authenticated.timeout(const Duration(seconds: 20));
    } catch (_) {
      client.close();
      rethrow;
    }
    return client;
  }

  static Future<String> _defaultRun(
    SSHClient client,
    String script,
    String? sudoPassword,
  ) =>
      RemoteExecutor.run(client, script, sudoPassword: sudoPassword)
          .timeout(const Duration(seconds: 60));
}
