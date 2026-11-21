import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/deployment_log.dart';
import '../theme/app_theme.dart';

class LogTerminal extends StatefulWidget {
  final Stream<DeploymentLog> logStream;

  const LogTerminal({super.key, required this.logStream});

  @override
  State<LogTerminal> createState() => _LogTerminalState();
}

class _LogTerminalState extends State<LogTerminal> {
  final List<DeploymentLog> _logs = [];
  final ScrollController _scrollController = ScrollController();
  StreamSubscription<DeploymentLog>? _subscription;

  @override
  void initState() {
    super.initState();
    _subscription = widget.logStream.listen((log) {
      if (!mounted) return;
      setState(() {
        _logs.add(log);
        if (_logs.length > 5000) _logs.removeAt(0);
      });
      // Auto-scroll to bottom
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        }
      });
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  Color _getLevelColor(DeploymentLogType type) {
    switch (type) {
      case DeploymentLogType.success:
        return AppTheme.success;
      case DeploymentLogType.warning:
        return AppTheme.warning;
      case DeploymentLogType.error:
        return AppTheme.error;
      default:
        return AppTheme.textSecondary;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.surface2,
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        border: Border.all(color: AppTheme.surface4, width: 1),
      ),
      padding: const EdgeInsets.all(AppTheme.spacing16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.terminal,
                color: AppTheme.accentPrimary,
                size: 20,
              ),
              const SizedBox(width: AppTheme.spacing8),
              Expanded(
                child: Text(
                  'Журнал развёртывания',
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
              IconButton(
                tooltip: 'Очистить журнал',
                onPressed: () => setState(_logs.clear),
                icon: const Icon(Icons.delete_outline, size: 18),
              ),
              if (_logs.isNotEmpty)
                IconButton(
                  tooltip: 'Копировать журнал',
                  onPressed: () {
                    final allText = _logs.map((l) => l.message).join('\n');
                    Clipboard.setData(ClipboardData(text: allText));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Журнал скопирован')),
                    );
                  },
                  icon: const Icon(Icons.copy, size: 16),
                  color: AppTheme.textSecondary,
                ),
            ],
          ),
          const SizedBox(height: AppTheme.spacing12),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: AppTheme.surface1,
                borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
              ),
              padding: const EdgeInsets.all(AppTheme.spacing12),
              child: _logs.isEmpty
                  ? Center(
                      child: Text(
                        'Ожидание запуска развёртывания...',
                        style: TextStyle(
                          color: AppTheme.textMuted,
                          fontFamily: 'monospace',
                        ),
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      itemCount: _logs.length,
                      itemBuilder: (context, index) {
                        final log = _logs[index];
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Text(
                            log.message,
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 13,
                              color: _getLevelColor(log.type),
                              height: 1.4,
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
