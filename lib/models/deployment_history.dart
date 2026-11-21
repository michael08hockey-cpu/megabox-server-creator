import 'deployment_result.dart';
import 'server_config.dart';

/// Полностью сохранённые данные развёрнутого сервера.
///
/// Хранится в SharedPreferences без шифрования: это локальный кэш
/// пользователя, а не защищённое хранилище секретов.
class DeploymentHistory {
  final String id;
  final DateTime timestamp;
  final String ipAddress;
  final int vlessPort;
  final String remark;
  final String shareLink;
  final String sni;

  /// Резервная VLESS-ссылка на порт 8443.
  final String? backupShareLink;

  /// Полная ссылка на веб-панель 3X-UI (с секретным путём).
  final String? panelUrl;

  /// Логин и пароль панели 3X-UI.
  final String? panelUsername;
  final String? panelPassword;

  /// Реквизиты для переподключения по SSH.
  final int sshPort;
  final String sshUser;
  final String? sshPassword;

  /// Локация и отпечаток TLS.
  final String locationFlag;
  final String locationName;
  final String locationCode;
  final String? subUrl;
  final String fingerprint;

  /// Ссылки на ключи друзей, созданных при развёртывании.
  final Map<String, String> friendLinks;
  final Map<String, String> friendBackupLinks;

  DeploymentHistory({
    required this.id,
    required this.timestamp,
    required this.ipAddress,
    required this.vlessPort,
    required this.remark,
    required this.shareLink,
    required this.sni,
    this.backupShareLink,
    this.panelUrl,
    this.panelUsername,
    this.panelPassword,
    this.sshPort = 22,
    this.sshUser = 'root',
    this.sshPassword,
    this.locationFlag = '',
    this.locationName = '',
    this.locationCode = 'AUTO',
    this.subUrl,
    this.fingerprint = 'firefox',
    this.friendLinks = const {},
    this.friendBackupLinks = const {},
  });

  /// Captures the actual deployment output, never reconstructs panel secrets.
  factory DeploymentHistory.fromDeployment(
    ServerConfig config,
    DeploymentResult result,
  ) {
    final now = DateTime.now();
    return DeploymentHistory(
      id: now.microsecondsSinceEpoch.toString(),
      timestamp: now,
      ipAddress: config.ipAddress,
      vlessPort: config.vlessPort,
      remark: config.remark,
      shareLink: result.vlessLink,
      sni: result.selectedSni,
      backupShareLink: result.backupVlessLink,
      panelUrl: result.panelUrl,
      panelUsername: result.panelUsername,
      panelPassword: result.panelPassword,
      sshPort: config.sshPort,
      sshUser: config.sshUser,
      sshPassword: config.sshPassword,
      locationCode: config.location.code,
      locationFlag: result.locationFlag,
      locationName: result.locationName,
      fingerprint: config.location.fingerprint,
      friendLinks: result.friendLinks,
      friendBackupLinks: result.friendBackupLinks,
      subUrl: result.subUrl,
    );
  }

  ServerConfig toServerConfig({String? password}) => ServerConfig(
    ipAddress: ipAddress,
    sshPort: sshPort,
    sshUser: sshUser,
    sshPassword: password ?? sshPassword ?? '',
    location: ServerLocation.fromCode(locationCode) ?? ServerLocation.auto,
    vlessPort: vlessPort,
    remark: remark,
  );

  DeploymentResult toDeploymentResult() => DeploymentResult(
    vlessLink: shareLink,
    backupVlessLink: backupShareLink,
    panelUrl: panelUrl ?? '',
    panelUsername: panelUsername ?? '',
    panelPassword: panelPassword ?? '',
    locationFlag: locationFlag,
    locationName: locationName,
    selectedSni: sni,
    sniPing: 0,
    trafficVerified: false,
    httpCode: 0,
    portReachable: false,
    friendLinks: friendLinks,
    friendBackupLinks: friendBackupLinks,
    subUrl: subUrl,
  );

  /// Запись создана до появления полного набора полей в хранилище.
  bool get isLegacy => panelUrl == null;

  /// Есть ли сохранённый SSH-пароль для автоматического переподключения.
  bool get hasSavedSshPassword =>
      sshPassword != null && sshPassword!.isNotEmpty;

  /// Данные панели для копирования одним блоком.
  String get allPanelData {
    final url = panelUrl ?? '';
    final user = panelUsername ?? '';
    final pass = panelPassword ?? '';
    return 'Панель 3X-UI\nURL: $url\nЛогин: $user\nПароль: $pass';
  }

  /// Сводка всех ключей: основной, резервный и ключи друзей.
  List<String> get allLinks => <String>[
    shareLink,
    if (backupShareLink != null && backupShareLink!.isNotEmpty)
      backupShareLink!,
    ...friendLinks.values,
    ...friendBackupLinks.values,
  ];

  Map<String, dynamic> toJson() => {
    'id': id,
    'timestamp': timestamp.toIso8601String(),
    'ipAddress': ipAddress,
    'vlessPort': vlessPort,
    'remark': remark,
    'shareLink': shareLink,
    'sni': sni,
    'backupShareLink': backupShareLink,
    'panelUrl': panelUrl,
    'panelUsername': panelUsername,
    'panelPassword': panelPassword,
    'sshPort': sshPort,
    'sshUser': sshUser,
    'sshPassword': sshPassword,
    'locationFlag': locationFlag,
    'locationName': locationName,
    'locationCode': locationCode,
    'subUrl': subUrl,
    'fingerprint': fingerprint,
    'friendLinks': friendLinks,
    'friendBackupLinks': friendBackupLinks,
  };

  factory DeploymentHistory.fromJson(Map<String, dynamic> json) {
    return DeploymentHistory(
      id: json['id'] as String,
      timestamp: DateTime.parse(json['timestamp'] as String),
      ipAddress: json['ipAddress'] as String,
      vlessPort: (json['vlessPort'] as num).toInt(),
      remark: json['remark'] as String? ?? '',
      shareLink: json['shareLink'] as String? ?? '',
      sni: json['sni'] as String? ?? '',
      backupShareLink: json['backupShareLink'] as String?,
      panelUrl: json['panelUrl'] as String?,
      panelUsername: json['panelUsername'] as String?,
      panelPassword: json['panelPassword'] as String?,
      sshPort: (json['sshPort'] as num?)?.toInt() ?? 22,
      sshUser: json['sshUser'] as String? ?? 'root',
      sshPassword: json['sshPassword'] as String?,
      locationFlag: json['locationFlag'] as String? ?? '',
      locationName: json['locationName'] as String? ?? '',
      locationCode: json['locationCode'] as String? ?? 'AUTO',
      subUrl: json['subUrl'] as String?,
      fingerprint: json['fingerprint'] as String? ?? 'firefox',
      friendLinks: _stringMap(json['friendLinks']),
      friendBackupLinks: _stringMap(json['friendBackupLinks']),
    );
  }

  static Map<String, String> _stringMap(Object? raw) {
    if (raw is! Map) return const <String, String>{};
    return raw.map((key, value) => MapEntry<String, String>('$key', '$value'));
  }

  /// Копия записи с обновлёнными данными развёртывания.
  DeploymentHistory copyWith({
    String? id,
    DateTime? timestamp,
    String? shareLink,
    String? sni,
    String? backupShareLink,
    String? panelUrl,
    String? panelUsername,
    String? panelPassword,
    int? sshPort,
    String? sshUser,
    String? sshPassword,
    String? locationFlag,
    String? locationName,
    String? fingerprint,
    Map<String, String>? friendLinks,
    Map<String, String>? friendBackupLinks,
  }) {
    return DeploymentHistory(
      id: id ?? this.id,
      timestamp: timestamp ?? this.timestamp,
      ipAddress: ipAddress,
      vlessPort: vlessPort,
      remark: remark,
      shareLink: shareLink ?? this.shareLink,
      sni: sni ?? this.sni,
      backupShareLink: backupShareLink ?? this.backupShareLink,
      panelUrl: panelUrl ?? this.panelUrl,
      panelUsername: panelUsername ?? this.panelUsername,
      panelPassword: panelPassword ?? this.panelPassword,
      sshPort: sshPort ?? this.sshPort,
      sshUser: sshUser ?? this.sshUser,
      sshPassword: sshPassword ?? this.sshPassword,
      locationFlag: locationFlag ?? this.locationFlag,
      locationName: locationName ?? this.locationName,
      locationCode: locationCode,
      subUrl: subUrl,
      fingerprint: fingerprint ?? this.fingerprint,
      friendLinks: friendLinks ?? this.friendLinks,
      friendBackupLinks: friendBackupLinks ?? this.friendBackupLinks,
    );
  }
}
