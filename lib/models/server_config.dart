/// Глобальные резервные маскировочные домены (SNI).
/// Используются, если не нашлось сайта-маски рядом с сервером.
///
/// Без Microsoft, Apple, Google и Cloudflare: в 2026 это самые «выжженные»
/// маски — ТСПУ видит, что их домен отвечает с IP хостинга, и банит сервер.
const List<String> globalSniFallbacks = <String>[
  'www.samsung.com',
  'www.nvidia.com',
  'www.intel.com',
  'www.sony.com',
  'www.dell.com',
  'www.lenovo.com',
  'www.asus.com',
  'www.logitech.com',
];

/// Домены, которые никогда не используем как маску Reality.
const List<String> burnedSniMarkers = <String>[
  'microsoft',
  'apple',
  'icloud',
  'google',
  'cloudflare',
  'windowsupdate',
];

/// true, если домен из «выжженного» списка.
bool isBurnedSni(String domain) {
  final d = domain.toLowerCase();
  return burnedSniMarkers.any(d.contains);
}

/// Резервный порт gRPC/XHTTP, на который переключается трафик,
/// если не найден ни один рабочий SNI.
const int fallbackBackupPort = 8443;

class ServerLocation {
  final String code;
  final String nameRu;
  final String nameEn;
  final String flag;
  final List<String> sniCandidates;
  final String fingerprint;
  final String remarkPrefix;

  const ServerLocation({
    required this.code,
    required this.nameRu,
    required this.nameEn,
    required this.flag,
    required this.sniCandidates,
    required this.fingerprint,
    required this.remarkPrefix,
  });

  static const usa = ServerLocation(
    code: 'US',
    nameRu: 'США',
    nameEn: 'USA',
    flag: '🇺🇸',
    sniCandidates: [
      'www.amd.com',
      'www.nvidia.com',
      'www.intel.com',
      'www.dell.com',
    ],
    fingerprint: 'firefox',
    remarkPrefix: '🇺🇸 USA-MegaBox',
  );

  static const germany = ServerLocation(
    code: 'DE',
    nameRu: 'Германия',
    nameEn: 'Germany',
    flag: '🇩🇪',
    sniCandidates: [
      'www.telekom.de',
      'www.sap.com',
      'www.bosch.com',
      'www.siemens.com',
    ],
    fingerprint: 'firefox',
    remarkPrefix: '🇩🇪 DE-MegaBox',
  );

  static const sweden = ServerLocation(
    code: 'SE',
    nameRu: 'Швеция',
    nameEn: 'Sweden',
    flag: '🇸🇪',
    sniCandidates: [
      'www.ericsson.com',
      'www.volvocars.com',
      'www.ikea.com',
      'www.spotify.com',
    ],
    fingerprint: 'firefox',
    remarkPrefix: '🇸🇪 SE-MegaBox',
  );

  static const poland = ServerLocation(
    code: 'PL',
    nameRu: 'Польша',
    nameEn: 'Poland',
    flag: '🇵🇱',
    sniCandidates: [
      'www.allegro.pl',
      'www.cdprojekt.com',
      'www.orlen.pl',
      'www.samsung.com',
    ],
    fingerprint: 'firefox',
    remarkPrefix: '🇵🇱 PL-MegaBox',
  );

  static const netherlands = ServerLocation(
    code: 'NL',
    nameRu: 'Нидерланды',
    nameEn: 'Netherlands',
    flag: '🇳🇱',
    sniCandidates: [
      'www.booking.com',
      'www.philips.com',
      'www.asml.com',
      'www.samsung.com',
    ],
    fingerprint: 'firefox',
    remarkPrefix: '🇳🇱 NL-MegaBox',
  );

  static const finland = ServerLocation(
    code: 'FI',
    nameRu: 'Финляндия',
    nameEn: 'Finland',
    flag: '🇫🇮',
    sniCandidates: ['www.nokia.com', 'www.finnair.com', 'www.samsung.com'],
    fingerprint: 'firefox',
    remarkPrefix: '🇫🇮 FI-MegaBox',
  );

  static const russia = ServerLocation(
    code: 'RU',
    nameRu: 'РФ / Локальный',
    nameEn: 'Russia / Local',
    flag: '🇷🇺',
    sniCandidates: ['www.gosuslugi.ru', 'vk.com', 'ya.ru', 'www.ozon.ru'],
    fingerprint: 'firefox',
    remarkPrefix: '🇷🇺 RU-MegaBox',
  );

  static const auto = ServerLocation(
    code: 'AUTO',
    nameRu: 'Авто-определение',
    nameEn: 'Auto GeoIP',
    flag: '🌍',
    sniCandidates: [],
    fingerprint: 'firefox',
    remarkPrefix: '🌍 Auto-MegaBox',
  );

  static const List<ServerLocation> all = [
    usa,
    germany,
    sweden,
    poland,
    netherlands,
    finland,
    russia,
    auto,
  ];

  static ServerLocation? fromCode(String code) {
    try {
      return all.firstWhere((loc) => loc.code == code.toUpperCase());
    } catch (_) {
      return null;
    }
  }
}

class DeploymentOptions {
  final bool cleanReinstall;
  final bool antiTorrent;
  final bool adBlock;
  final bool fail2ban;
  final bool backupInbound;
  final bool bypassRuDomains;
  final bool cloudflareWarp;
  final String? tgBotToken;
  final String? tgBotChatId;
  final List<String> friendNames;
  final int limitIp;
  final int limitGb;

  // Новые опции Стелс+ и Самолечение
  final bool autoSwap; // Авто-создание swap 2GB
  final bool watchdogEnabled; // Сторожевой таймер + Telegram
  final bool decoyWebsite; // Маскировка панели за фейковым сайтом
  final bool temporaryKeys; // Режим временных ключей
  final int? keyExpiryHours; // Срок жизни ключа (null = без ограничений)

  // Защита от блокировок ТСПУ (2026)
  /// Транспорт VLESS: 'xhttp' (по умолчанию) или 'tcp' (старый RAW+Vision,
  /// его ТСПУ блокирует массово с февраля 2026).
  final String transport;

  /// Свой домен для self-steal: Reality маскируется под твой же сайт
  /// на этом сервере. null/пусто — режим выключен.
  final String? selfStealDomain;

  /// Скрыть панель 3X-UI от интернета (слушать только 127.0.0.1).
  /// Открытая панель на IP — явный признак VPN-сервера для сканеров.
  final bool hidePanel;

  /// Маскировка паддинга XHTTP: вместо стандартного `Referer: ...?x_padding=`
  /// (известный отпечаток Xray) — случайные ключ и диапазон на каждый сервер.
  /// Нужны свежие клиенты на ядре Xray (v2rayN, v2rayNG, Happ).
  final bool xhttpObfs;

  /// Обновить ядро Xray до последней стабильной версии (с откатом при сбое)
  /// и отключить уязвимый MPTCP.
  final bool updateXrayCore;

  /// true, если задан домен для self-steal.
  bool get useSelfSteal => (selfStealDomain ?? '').trim().isNotEmpty;

  const DeploymentOptions({
    this.cleanReinstall = true,
    this.antiTorrent = true,
    this.adBlock = false,
    this.fail2ban = false,
    this.backupInbound = false,
    this.bypassRuDomains = true,
    this.cloudflareWarp = false,
    this.tgBotToken,
    this.tgBotChatId,
    this.friendNames = const [],
    this.limitIp = 0,
    this.limitGb = 0,
    // Новые опции по умолчанию включены (кроме decoyWebsite)
    this.autoSwap = true,
    this.watchdogEnabled = true,
    this.decoyWebsite = false,
    this.temporaryKeys = true,
    this.keyExpiryHours,
    this.transport = 'xhttp',
    this.selfStealDomain,
    this.hidePanel = true,
    this.xhttpObfs = true,
    this.updateXrayCore = true,
  });
}

class ServerConfig {
  final String ipAddress;
  final int sshPort;
  final String sshUser;
  final String sshPassword;
  final ServerLocation location;
  final int vlessPort;
  final String remark;
  final DeploymentOptions options;

  ServerConfig({
    required this.ipAddress,
    required this.sshPort,
    required this.sshUser,
    required this.sshPassword,
    required this.location,
    required this.vlessPort,
    required this.remark,
    this.options = const DeploymentOptions(),
  });

  Map<String, dynamic> toJson() => {
    'ipAddress': ipAddress,
    'sshPort': sshPort,
    'sshUser': sshUser,
    'locationCode': location.code,
    'vlessPort': vlessPort,
    'remark': remark,
  };

  factory ServerConfig.fromJson(Map<String, dynamic> json) => ServerConfig(
    ipAddress: json['ipAddress'] as String,
    sshPort: json['sshPort'] as int,
    sshUser: json['sshUser'] as String,
    sshPassword: '',
    location:
        ServerLocation.fromCode(json['locationCode'] as String? ?? 'AUTO') ??
        ServerLocation.auto,
    vlessPort: json['vlessPort'] as int,
    remark: json['remark'] as String,
  );
}
