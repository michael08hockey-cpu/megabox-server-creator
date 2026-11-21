enum DeploymentLogType { info, success, warning, error }

class DeploymentLog {
  final String message;
  final DeploymentLogType type;
  final DateTime timestamp;

  DeploymentLog({
    required this.message,
    required this.type,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}
