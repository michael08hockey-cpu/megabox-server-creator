class DeploymentResult {
  final String vlessLink;
  final String? backupVlessLink;
  final String panelUrl;
  final String panelUsername;
  final String panelPassword;
  final String locationFlag;
  final String locationName;
  final String selectedSni;
  final double sniPing;
  final bool trafficVerified;
  final int httpCode;
  final String? trafficError;
  final bool portReachable;
  final List<int> serverListeningPorts;
  final Map<int, bool> portReachability;
  final Map<String, String> friendLinks;
  final Map<String, String> friendBackupLinks;
  final String? subUrl;

  DeploymentResult({
    required this.vlessLink,
    this.backupVlessLink,
    required this.panelUrl,
    required this.panelUsername,
    required this.panelPassword,
    required this.locationFlag,
    required this.locationName,
    required this.selectedSni,
    required this.sniPing,
    required this.trafficVerified,
    required this.httpCode,
    required this.portReachable,
    this.serverListeningPorts = const [],
    this.portReachability = const {},
    this.trafficError,
    this.friendLinks = const {},
    this.friendBackupLinks = const {},
    this.subUrl,
  });

  String get allPanelData =>
      'Панель 3X-UI\nURL: $panelUrl\nЛогин: $panelUsername\nПароль: $panelPassword';

  /// TCP-доступность не доказывает прохождение VLESS/Reality-трафика.
  bool get serverReady =>
      portReachability.isNotEmpty &&
      portReachability.keys.every(serverListeningPorts.contains);

  String get readinessBadge {
    if (serverReady) {
      return allPortsReachable
          ? 'Сервер готов: Xray слушает порты, TCP-доступность подтверждена'
          : 'Сервер готов: Xray слушает порты; TCP-проверка с этой сети не прошла';
    }
    if (portReachability.isNotEmpty) {
      return 'Ожидание Xray: готовность всех портов на VPS не подтверждена';
    }
    return 'Сохранённые ключи — подключитесь по SSH для проверки сервера';
  }

  bool get allPortsReachable =>
      portReachability.isNotEmpty &&
      portReachability.values.every((reachable) => reachable);
}
