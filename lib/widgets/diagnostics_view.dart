import 'package:flutter/material.dart';

import '../services/diagnostics_service.dart';
import '../theme/app_theme.dart';

Color diagColor(DiagStatus s) => switch (s) {
  DiagStatus.ok => AppTheme.success,
  DiagStatus.info => AppTheme.accentPrimary,
  DiagStatus.warn => AppTheme.warning,
  DiagStatus.fail => AppTheme.error,
};

IconData diagIcon(DiagStatus s) => switch (s) {
  DiagStatus.ok => Icons.check_circle,
  DiagStatus.info => Icons.info,
  DiagStatus.warn => Icons.warning_amber_rounded,
  DiagStatus.fail => Icons.cancel,
};

/// Состояние одного прогона диагностики (общий для окна и экрана).
class DiagRunController extends ChangeNotifier {
  DiagRunController({ServerDiagnostics? service})
    : _service = service ?? ServerDiagnostics();

  final ServerDiagnostics _service;
  final List<DiagCheck> checks = <DiagCheck>[];
  String stage = '';
  bool running = false;
  DiagReport? report;
  bool _disposed = false;

  Future<DiagReport?> start({
    required String host,
    required int sshPort,
    required String user,
    required String password,
    required int vlessPort,
  }) async {
    if (running) return null;
    checks.clear();
    report = null;
    running = true;
    stage = 'Запуск…';
    _notify();
    try {
      final r = await _service.run(
        host: host,
        sshPort: sshPort,
        user: user,
        password: password,
        vlessPort: vlessPort,
        onCheck: (c) {
          checks.add(c);
          _notify();
        },
        onProgress: (s) {
          stage = s;
          _notify();
        },
      );
      report = r;
      return r;
    } catch (e) {
      final failed = DiagReport(<DiagCheck>[
        ...checks,
        DiagCheck(
          id: 'error',
          title: 'Диагностика',
          status: DiagStatus.fail,
          detail: 'Ошибка: $e',
        ),
      ]);
      report = failed;
      return failed;
    } finally {
      running = false;
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Строка одной проверки.
class DiagCheckTile extends StatelessWidget {
  const DiagCheckTile({super.key, required this.check});
  final DiagCheck check;

  @override
  Widget build(BuildContext context) {
    final color = diagColor(check.status);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppTheme.surface3,
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        border: Border.all(
          color: check.status == DiagStatus.ok
              ? AppTheme.surface4
              : color.withValues(alpha: 0.45),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(diagIcon(check.status), size: 18, color: color),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  check.title,
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                ),
                const SizedBox(height: 2),
                Text(
                  check.detail,
                  style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                ),
                if (check.hint != null) ...<Widget>[
                  const SizedBox(height: 4),
                  Text(
                    check.hint!,
                    style: TextStyle(fontSize: 12, color: color, height: 1.35),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Плашка с итогом.
class DiagVerdictBanner extends StatelessWidget {
  const DiagVerdictBanner({super.key, required this.report});
  final DiagReport report;

  @override
  Widget build(BuildContext context) {
    final color = diagColor(report.overall);
    final fails = report.checks.where((c) => c.status == DiagStatus.fail).length;
    final warns = report.checks.where((c) => c.status == DiagStatus.warn).length;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: <Widget>[
          Icon(diagIcon(report.overall), color: color, size: 26),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  report.verdict,
                  style: TextStyle(fontWeight: FontWeight.w700, color: color),
                ),
                if (fails + warns > 0)
                  Text(
                    [
                      if (fails > 0) 'проблем: $fails',
                      if (warns > 0) 'замечаний: $warns',
                    ].join(' · '),
                    style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Живой список результатов (без собственной прокрутки).
class DiagResultsColumn extends StatelessWidget {
  const DiagResultsColumn({super.key, required this.controller});
  final DiagRunController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final c = controller;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (c.report != null && !c.running) ...<Widget>[
              DiagVerdictBanner(report: c.report!),
              const SizedBox(height: 12),
            ],
            if (c.running)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  children: <Widget>[
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        c.stage,
                        style: const TextStyle(color: AppTheme.textSecondary),
                      ),
                    ),
                  ],
                ),
              ),
            // Сначала проблемы, потом всё остальное.
            for (final check in _sorted(c.checks)) DiagCheckTile(check: check),
          ],
        );
      },
    );
  }

  static List<DiagCheck> _sorted(List<DiagCheck> checks) {
    int rank(DiagStatus s) => switch (s) {
      DiagStatus.fail => 0,
      DiagStatus.warn => 1,
      DiagStatus.info => 2,
      DiagStatus.ok => 3,
    };
    final indexed = checks.asMap().entries.toList()
      ..sort((a, b) {
        final r = rank(a.value.status).compareTo(rank(b.value.status));
        return r != 0 ? r : a.key.compareTo(b.key);
      });
    return indexed.map((e) => e.value).toList();
  }
}

/// Предупреждение: проверка с включённым VPN покажет не то.
class DiagVpnNote extends StatelessWidget {
  const DiagVpnNote({super.key});

  @override
  Widget build(BuildContext context) {
    return const Text(
      'Проверяй с выключенным VPN: иначе доступность сервера проверится '
      'через VPN, а не из твоей сети.',
      style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
    );
  }
}

/// Окно проверки перед развёртыванием.
/// Возвращает true, если можно (или пользователь решил) продолжать.
Future<bool> showPreflightSheet(
  BuildContext context, {
  required String host,
  required int sshPort,
  required String user,
  required String password,
  required int vlessPort,
  ServerDiagnostics? service,
}) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    isDismissible: false,
    enableDrag: false,
    backgroundColor: AppTheme.surface2,
    constraints: const BoxConstraints(maxWidth: 720),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppTheme.radiusLarge)),
    ),
    builder: (ctx) => _PreflightSheet(
      host: host,
      sshPort: sshPort,
      user: user,
      password: password,
      vlessPort: vlessPort,
      service: service,
    ),
  );
  return result ?? false;
}

class _PreflightSheet extends StatefulWidget {
  const _PreflightSheet({
    required this.host,
    required this.sshPort,
    required this.user,
    required this.password,
    required this.vlessPort,
    this.service,
  });

  final String host;
  final int sshPort;
  final String user;
  final String password;
  final int vlessPort;
  final ServerDiagnostics? service;

  @override
  State<_PreflightSheet> createState() => _PreflightSheetState();
}

class _PreflightSheetState extends State<_PreflightSheet> {
  late final DiagRunController _controller =
      DiagRunController(service: widget.service);

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final report = await _controller.start(
      host: widget.host,
      sshPort: widget.sshPort,
      user: widget.user,
      password: widget.password,
      vlessPort: widget.vlessPort,
    );
    // Всё зелёное — не заставляем нажимать кнопку.
    if (report != null && report.overall == DiagStatus.ok) {
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      if (mounted) Navigator.of(context).pop(true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height * 0.85;
    return SafeArea(
      child: SizedBox(
        height: height,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  const Icon(Icons.health_and_safety, color: AppTheme.accentPrimary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Проверка сервера ${widget.host}',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              const DiagVpnNote(),
              const SizedBox(height: 12),
              Expanded(
                child: SingleChildScrollView(
                  child: DiagResultsColumn(controller: _controller),
                ),
              ),
              const SizedBox(height: 10),
              ListenableBuilder(
                listenable: _controller,
                builder: (context, _) {
                  final done = !_controller.running && _controller.report != null;
                  final fail = _controller.report?.hasFail ?? false;
                  return Row(
                    children: <Widget>[
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.of(context).pop(false),
                          child: const Text('Отмена'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton(
                          style: fail
                              ? FilledButton.styleFrom(backgroundColor: AppTheme.error)
                              : null,
                          onPressed: done ? () => Navigator.of(context).pop(true) : null,
                          child: Text(
                            fail ? 'Всё равно развернуть' : 'Развернуть',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
