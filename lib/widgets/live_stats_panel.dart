import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/server_management_service.dart';
import '../theme/app_theme.dart';

/// Живая панель мониторинга VPS: кольцевые индикаторы CPU/RAM/диска,
/// графики за последние минуты, скорость сети и трафик клиентов.
/// Обновляется сама каждые [interval], пока включено автообновление.
class LiveStatsPanel extends StatefulWidget {
  const LiveStatsPanel({
    super.key,
    required this.fetch,
    this.initial,
    this.interval = const Duration(seconds: 5),
    this.onResetTraffic,
    this.onToggleClient,
  });

  final Future<ServerLiveStats> Function() fetch;

  /// Сброс трафика клиента по email (null — кнопка скрыта).
  final Future<void> Function(String email)? onResetTraffic;

  /// Включение/отключение клиента (null — кнопка скрыта).
  final Future<void> Function(String email, bool enable)? onToggleClient;
  final ServerLiveStats? initial;
  final Duration interval;

  @override
  State<LiveStatsPanel> createState() => _LiveStatsPanelState();
}

class _LiveStatsPanelState extends State<LiveStatsPanel> {
  static const _historyLength = 60;

  final List<double> _cpu = <double>[];
  final List<double> _ram = <double>[];
  final List<double> _rxSpeed = <double>[];
  final List<double> _txSpeed = <double>[];

  ServerLiveStats? _stats;
  ServerLiveStats? _prev;
  Timer? _timer;
  bool _auto = true;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.initial != null) _push(widget.initial!);
    _schedule();
    if (widget.initial == null) _tick();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _schedule() {
    _timer?.cancel();
    if (_auto) _timer = Timer.periodic(widget.interval, (_) => _tick());
  }

  Future<void> _tick() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final s = await widget.fetch();
      if (!mounted) return;
      setState(() {
        _push(s);
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Выполнить действие над клиентом и сразу обновить статистику.
  Future<void> _clientAction(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      // Ошибку уже показал экран; статистику всё равно обновим.
    }
    if (mounted) await _tick();
  }

  void _add(List<double> list, double v) {
    list.add(v);
    if (list.length > _historyLength) list.removeAt(0);
  }

  void _push(ServerLiveStats s) {
    _prev = _stats;
    _stats = s;
    _add(_cpu, s.cpuUsage);
    _add(_ram, s.ramPercent);
    final p = _prev;
    if (p != null &&
        p.rxBytes != null &&
        s.rxBytes != null &&
        p.txBytes != null &&
        s.txBytes != null) {
      final secs = s.takenAt.difference(p.takenAt).inMilliseconds / 1000;
      if (secs > 0) {
        _add(_rxSpeed, math.max(0, (s.rxBytes! - p.rxBytes!) / secs));
        _add(_txSpeed, math.max(0, (s.txBytes! - p.txBytes!) / secs));
      }
    }
  }

  /// Телефонная вёрстка строк клиентов.
  bool _narrow = false;

  @override
  Widget build(BuildContext context) {
    _narrow = MediaQuery.sizeOf(context).width < 760;
    final s = _stats;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _header(s),
        const SizedBox(height: 14),
        if (s == null)
          _placeholder()
        else ...<Widget>[
          _responsiveRow(
            children: <Widget>[
              Expanded(
                child: _GaugeCard(
                  label: 'CPU',
                  percent: s.cpuUsage,
                  detail: '${s.cpuCores} ядер · LA ${_firstLoad(s)}',
                  color: AppTheme.accentPrimary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _GaugeCard(
                  label: 'RAM',
                  percent: s.ramPercent,
                  detail:
                      '${s.ramUsedMb.toStringAsFixed(0)} / ${s.ramTotalMb.toStringAsFixed(0)} МБ',
                  color: AppTheme.accentViolet,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _GaugeCard(
                  label: 'Диск',
                  percent: s.diskUsage,
                  detail: s.diskTotalGb > 0
                      ? '${s.diskUsedGb.toStringAsFixed(1)} / ${s.diskTotalGb.toStringAsFixed(1)} ГБ'
                      : '',
                  color: AppTheme.success,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _responsiveRow(
            children: <Widget>[
              Expanded(
                child: _ChartCard(
                  title: 'Нагрузка, %',
                  series: <_Series>[
                    _Series('CPU', _cpu, AppTheme.accentPrimary),
                    _Series('RAM', _ram, AppTheme.accentViolet),
                  ],
                  fixedMax: 100,
                  format: (v) => '${v.toStringAsFixed(0)}%',
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _ChartCard(
                  title: 'Сеть',
                  series: <_Series>[
                    _Series('↓ вход', _rxSpeed, AppTheme.success),
                    _Series('↑ выход', _txSpeed, AppTheme.warning),
                  ],
                  format: (v) => '${formatBytes(v)}/с',
                  emptyText: s.rxBytes == null
                      ? 'Интерфейс не найден'
                      : 'Нужно ещё одно обновление',
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _clientsCard(s),
        ],
      ],
    );
  }

  String _firstLoad(ServerLiveStats s) {
    final parts = s.loadAverage.split(' ');
    return parts.isEmpty || parts.first.isEmpty ? '—' : parts.first;
  }

  Widget _header(ServerLiveStats? s) {
    final chips = <Widget>[
      if (s != null) ...<Widget>[
        _StatusPill(
          ok: s.xuiActive,
          text: s.xuiActive ? '3X-UI работает' : '3X-UI остановлена',
        ),
        _Chip(icon: Icons.people_alt_outlined, text: '${s.activeConnections} соед.'),
        if (s.uptime.isNotEmpty) _Chip(icon: Icons.schedule, text: s.uptime),
      ],
    ];
    if (_narrow) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _headerRow(const <Widget>[]),
          if (chips.isNotEmpty)
            Wrap(spacing: 8, runSpacing: 6, children: chips),
        ],
      );
    }
    return _headerRow(<Widget>[
      for (final c in chips) ...<Widget>[c, const SizedBox(width: 8)],
    ]);
  }

  Widget _headerRow(List<Widget> chips) {
    return Row(
      children: <Widget>[
        const Text(
          'МОНИТОРИНГ',
          style: TextStyle(
            color: AppTheme.textSecondary,
            fontSize: 11,
            letterSpacing: 0.8,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(width: 10),
        ...chips,
        const Spacer(),
        if (_error != null)
          Tooltip(
            message: _error!,
            child: const Icon(Icons.error_outline, color: AppTheme.error, size: 18),
          ),
        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        const Text('Авто', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
        Switch(
          value: _auto,
          onChanged: (v) {
            setState(() => _auto = v);
            _schedule();
          },
        ),
        IconButton(
          tooltip: 'Обновить сейчас',
          onPressed: _loading ? null : _tick,
          icon: const Icon(Icons.refresh, size: 20),
        ),
      ],
    );
  }

  Widget _placeholder() => Container(
    height: 160,
    alignment: Alignment.center,
    decoration: AppTheme.glassCard(),
    child: _error != null
        ? Text('Не удалось получить статистику:\n$_error',
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppTheme.error))
        : const CircularProgressIndicator(),
  );

  Widget _clientsCard(ServerLiveStats s) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: AppTheme.glassCard(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Text('Трафик клиентов',
                  style: TextStyle(fontWeight: FontWeight.w700)),
              const Spacer(),
              Text(
                'Всего: ${formatBytes(s.clients.fold<int>(0, (a, c) => a + c.used).toDouble())}',
                style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (s.clients.isEmpty)
            const Text('Нет данных о клиентах',
                style: TextStyle(color: AppTheme.textMuted, fontSize: 12))
          else
            ...s.clients.map(_clientRow),
        ],
      ),
    );
  }

  /// Ряд карточек: на широком экране в строку, на телефоне — столбиком.
  /// Ожидает детей вида Expanded / SizedBox(width: ...) как в Row.
  Widget _responsiveRow({required List<Widget> children}) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 560) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: children,
          );
        }
        final cards = <Widget>[
          for (final w in children)
            if (w is Expanded) w.child,
        ];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (var i = 0; i < cards.length; i++) ...<Widget>[
              if (i > 0) const SizedBox(height: 10),
              cards[i],
            ],
          ],
        );
      },
    );
  }

  Widget _clientRow(ClientTraffic c) {
    final max = (_stats?.clients.isNotEmpty ?? false)
        ? _stats!.clients.map((e) => e.used).reduce(math.max)
        : 1;
    final limit = c.total > 0 ? c.total : max;
    final frac = limit <= 0 ? 0.0 : (c.used / limit).clamp(0.0, 1.0);
    final expired =
        c.expiryTime > 0 && DateTime.now().millisecondsSinceEpoch > c.expiryTime;
    final color = !c.enabled || expired
        ? AppTheme.textMuted
        : frac > 0.9 && c.total > 0
        ? AppTheme.error
        : AppTheme.accentPrimary;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: <Widget>[
          Icon(
            c.enabled && !expired ? Icons.circle : Icons.block,
            size: 9,
            color: c.enabled && !expired ? AppTheme.success : AppTheme.error,
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: _narrow ? 90 : 150,
            child: Text(c.email,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13)),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: frac,
                minHeight: 6,
                backgroundColor: AppTheme.surface4,
                valueColor: AlwaysStoppedAnimation<Color>(color),
              ),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: _narrow ? 96 : 170,
            child: Text(
              _narrow
                  ? '${formatBytes(c.used.toDouble())}'
                      '${c.total > 0 ? ' / ${formatBytes(c.total.toDouble())}' : ''}'
                  : '↓${formatBytes(c.down.toDouble())}  ↑${formatBytes(c.up.toDouble())}'
                      '${c.total > 0 ? ' / ${formatBytes(c.total.toDouble())}' : ''}',
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontSize: 11,
                fontFamily: 'Consolas',
                color: AppTheme.textSecondary,
              ),
            ),
          ),
          if (widget.onResetTraffic != null || widget.onToggleClient != null)
            PopupMenuButton<String>(
              tooltip: 'Действия с клиентом',
              icon: const Icon(Icons.more_vert, size: 18, color: AppTheme.textSecondary),
              color: AppTheme.surface3,
              onSelected: (v) {
                if (v == 'reset') {
                  _clientAction(() => widget.onResetTraffic!(c.email));
                } else if (v == 'toggle') {
                  _clientAction(() => widget.onToggleClient!(c.email, !c.enabled));
                }
              },
              itemBuilder: (_) => <PopupMenuEntry<String>>[
                if (widget.onResetTraffic != null)
                  const PopupMenuItem<String>(
                    value: 'reset',
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.restart_alt, size: 18),
                      title: Text('Сбросить трафик'),
                    ),
                  ),
                if (widget.onToggleClient != null)
                  PopupMenuItem<String>(
                    value: 'toggle',
                    child: ListTile(
                      dense: true,
                      leading: Icon(
                        c.enabled ? Icons.pause_circle_outline : Icons.play_circle_outline,
                        size: 18,
                      ),
                      title: Text(c.enabled ? 'Отключить клиента' : 'Включить клиента'),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

/// Человекочитаемый размер: 1.2 ГБ, 340 КБ и т.п.
String formatBytes(double b) {
  const units = <String>['Б', 'КБ', 'МБ', 'ГБ', 'ТБ'];
  var v = b;
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v >= 100 || i == 0 ? 0 : 1)} ${units[i]}';
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.ok, required this.text});
  final bool ok;
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = ok ? AppTheme.success : AppTheme.error;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppTheme.radiusPill),
        border: Border.all(color: c.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _PulseDot(color: c, animate: ok),
          const SizedBox(width: 6),
          Text(text, style: TextStyle(fontSize: 11, color: c, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

/// Точка статуса со свечением. Без бесконечной анимации: она мешала бы
/// pumpAndSettle в тестах и зря грузила бы GPU.
class _PulseDot extends StatelessWidget {
  const _PulseDot({required this.color, required this.animate});
  final Color color;
  final bool animate;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: animate
            ? <BoxShadow>[
                BoxShadow(
                  color: color.withValues(alpha: 0.6),
                  blurRadius: 8,
                  spreadRadius: 1,
                ),
              ]
            : null,
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: AppTheme.surface3,
        borderRadius: BorderRadius.circular(AppTheme.radiusPill),
        border: Border.all(color: AppTheme.surface5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 12, color: AppTheme.textSecondary),
          const SizedBox(width: 5),
          Text(text, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
        ],
      ),
    );
  }
}

class _GaugeCard extends StatelessWidget {
  const _GaugeCard({
    required this.label,
    required this.percent,
    required this.detail,
    required this.color,
  });

  final String label;
  final double percent;
  final String detail;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final p = percent.clamp(0, 100).toDouble();
    final c = p >= 90 ? AppTheme.error : (p >= 75 ? AppTheme.warning : color);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: AppTheme.glassCard(),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 72,
            height: 72,
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(end: p),
              duration: const Duration(milliseconds: 600),
              curve: Curves.easeOutCubic,
              builder: (_, v, _) => CustomPaint(
                painter: _RingPainter(value: v / 100, color: c),
                child: Center(
                  child: Text(
                    '${v.toStringAsFixed(0)}%',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(
                  detail,
                  style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.value, required this.color});
  final double value;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final r = rect.deflate(5);
    final bg = Paint()
      ..color = AppTheme.surface4
      ..style = PaintingStyle.stroke
      ..strokeWidth = 7
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(r, 0, math.pi * 2, false, bg);
    final fg = Paint()
      ..shader = SweepGradient(
        startAngle: -math.pi / 2,
        endAngle: math.pi * 1.5,
        colors: <Color>[color.withValues(alpha: 0.5), color],
      ).createShader(r)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 7
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(r, -math.pi / 2, math.pi * 2 * value.clamp(0.0, 1.0), false, fg);
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) =>
      old.value != value || old.color != color;
}

class _Series {
  const _Series(this.name, this.values, this.color);
  final String name;
  final List<double> values;
  final Color color;
}

class _ChartCard extends StatelessWidget {
  const _ChartCard({
    required this.title,
    required this.series,
    required this.format,
    this.fixedMax,
    this.emptyText = 'Сбор данных…',
  });

  final String title;
  final List<_Series> series;
  final String Function(double) format;
  final double? fixedMax;
  final String emptyText;

  @override
  Widget build(BuildContext context) {
    final hasData = series.any((s) => s.values.length >= 2);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      decoration: AppTheme.glassCard(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
              const Spacer(),
              for (final s in series) ...<Widget>[
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(color: s.color, shape: BoxShape.circle),
                ),
                const SizedBox(width: 4),
                Text(
                  '${s.name} ${s.values.isEmpty ? '—' : format(s.values.last)}',
                  style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
                ),
                const SizedBox(width: 10),
              ],
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 110,
            child: hasData
                ? CustomPaint(
                    painter: _SparkPainter(series: series, fixedMax: fixedMax),
                  )
                : Center(
                    child: Text(emptyText,
                        style: const TextStyle(color: AppTheme.textMuted, fontSize: 12)),
                  ),
          ),
        ],
      ),
    );
  }
}

class _SparkPainter extends CustomPainter {
  _SparkPainter({required this.series, this.fixedMax});
  final List<_Series> series;
  final double? fixedMax;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = AppTheme.surface4
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }

    var maxV = fixedMax ?? 0;
    if (fixedMax == null) {
      for (final s in series) {
        for (final v in s.values) {
          maxV = math.max(maxV, v);
        }
      }
      maxV = maxV <= 0 ? 1 : maxV * 1.15;
    }

    for (final s in series) {
      if (s.values.length < 2) continue;
      const slots = 59;
      final step = size.width / slots;
      final start = slots - (s.values.length - 1);
      final path = Path();
      for (var i = 0; i < s.values.length; i++) {
        final x = (start + i) * step;
        final y = size.height - (s.values[i] / maxV).clamp(0.0, 1.0) * size.height;
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      final fill = Path.from(path)
        ..lineTo(size.width, size.height)
        ..lineTo(start * step, size.height)
        ..close();
      canvas.drawPath(
        fill,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[s.color.withValues(alpha: 0.28), s.color.withValues(alpha: 0)],
          ).createShader(Offset.zero & size),
      );
      canvas.drawPath(
        path,
        Paint()
          ..color = s.color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeJoin = StrokeJoin.round,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SparkPainter old) => true;
}
