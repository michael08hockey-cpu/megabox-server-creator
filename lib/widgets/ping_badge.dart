import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Замер задержки до сервера: время TCP-рукопожатия с портом VLESS.
/// Не требует SSH и пароля. null — сервер не ответил за [timeout].
Future<int?> tcpPing(
  String host,
  int port, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final sw = Stopwatch()..start();
  try {
    final socket = await Socket.connect(host, port, timeout: timeout);
    sw.stop();
    socket.destroy();
    return sw.elapsedMilliseconds;
  } catch (_) {
    return null;
  }
}

/// Бейдж «42 мс» с цветом по качеству связи. Обновляется каждые [interval].
/// В тестах (FLUTTER_TEST) сеть не трогается.
class PingBadge extends StatefulWidget {
  const PingBadge({
    super.key,
    required this.host,
    required this.port,
    this.interval = const Duration(seconds: 30),
  });

  final String host;
  final int port;
  final Duration interval;

  static final bool _disabled = Platform.environment.containsKey('FLUTTER_TEST');

  @override
  State<PingBadge> createState() => _PingBadgeState();
}

class _PingBadgeState extends State<PingBadge> {
  Timer? _timer;
  int? _ms;
  bool _checked = false;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    if (PingBadge._disabled) return;
    _ping();
    _timer = Timer.periodic(widget.interval, (_) => _ping());
  }

  @override
  void didUpdateWidget(covariant PingBadge old) {
    super.didUpdateWidget(old);
    if (old.host != widget.host || old.port != widget.port) {
      _checked = false;
      if (!PingBadge._disabled) _ping();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _ping() async {
    if (_running) return;
    _running = true;
    final ms = await tcpPing(widget.host, widget.port);
    _running = false;
    if (!mounted) return;
    setState(() {
      _ms = ms;
      _checked = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (PingBadge._disabled) return const SizedBox.shrink();

    final Color color;
    final String text;
    if (!_checked) {
      color = AppTheme.textMuted;
      text = '…';
    } else if (_ms == null) {
      color = AppTheme.error;
      text = 'нет связи';
    } else {
      color = _ms! < 80
          ? AppTheme.success
          : (_ms! < 200 ? AppTheme.warning : AppTheme.error);
      text = '$_ms мс';
    }

    return Tooltip(
      message: 'Задержка до ${widget.host}:${widget.port} (TCP). Нажми, чтобы обновить',
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTheme.radiusPill),
        onTap: _ping,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(AppTheme.radiusPill),
            border: Border.all(color: color.withValues(alpha: 0.4)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.network_ping, size: 11, color: color),
              const SizedBox(width: 4),
              Text(
                text,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
