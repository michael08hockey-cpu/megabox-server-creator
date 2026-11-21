import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'vless_link_card.dart';

import '../models/deployment_result.dart';
import '../theme/app_theme.dart';

class ResultCards extends StatelessWidget {
  final DeploymentResult result;
  final VoidCallback? onClose;

  const ResultCards({super.key, required this.result, this.onClose});

  void _copy(BuildContext context, String text, String message) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _openPanel(BuildContext context) async {
    if (!Platform.isWindows) {
      // На телефоне нет «cmd start»: копируем ссылку, браузер откроет её сам.
      _copy(context, result.panelUrl, 'Ссылка на панель скопирована — вставь её в браузер');
      return;
    }
    await Process.start('cmd', [
      '/c',
      'start',
      '',
      result.panelUrl,
    ], mode: ProcessStartMode.detached);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _vlessCard(context),
        if (result.friendLinks.isNotEmpty) ...[
          const SizedBox(height: AppTheme.spacing16),
          const Text(
            'Ключи друзей',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          for (final entry in result.friendLinks.entries)
            VlessLinkCard(link: entry.value, title: entry.key, backup: false),
          for (final entry in result.friendBackupLinks.entries)
            VlessLinkCard(
              link: entry.value,
              title: '${entry.key} (8443)',
              backup: true,
            ),
        ],
        if (result.subUrl != null) ...[
          const SizedBox(height: AppTheme.spacing16),
          _secretRow(
            context,
            'Подписка',
            result.subUrl!,
            'Ссылка подписки скопирована',
          ),
        ],
        const SizedBox(height: AppTheme.spacing16),
        if (result.panelUrl.isNotEmpty) _panelCard(context),
      ],
    );
  }

  Widget _vlessCard(BuildContext context) {
    final ready = result.serverReady;
    final accent = ready
        ? AppTheme.success
        : result.portReachability.isNotEmpty
        ? AppTheme.warning
        : AppTheme.accentPrimary;
    final badge = result.readinessBadge;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppTheme.surface2,
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        border: Border.all(color: accent, width: 1.5),
      ),
      padding: const EdgeInsets.all(AppTheme.spacing16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(ready ? Icons.verified : Icons.vpn_key, color: accent),
              const SizedBox(width: AppTheme.spacing8),
              const Expanded(
                child: Text(
                  'Готовый VLESS REALITY ключ',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
              ),
              if (onClose != null)
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: onClose,
                  color: AppTheme.textMuted,
                ),
            ],
          ),
          const SizedBox(height: AppTheme.spacing8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(AppTheme.radiusPill),
            ),
            child: Text(
              badge,
              style: TextStyle(
                color: accent,
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(height: AppTheme.spacing12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _chip('${result.locationFlag} ${result.locationName}'),
              _chip('SNI: ${result.selectedSni}'),
              if (result.sniPing > 0)
                _chip('Пинг: ${result.sniPing.toStringAsFixed(1)} мс'),
              for (final entry in result.portReachability.entries)
                _chip(
                  'Порт ${entry.key}: ${entry.value
                      ? "TCP доступен"
                      : result.serverListeningPorts.contains(entry.key)
                      ? "Xray готов на VPS"
                      : "проверка не подтверждена"}',
                ),
            ],
          ),
          const SizedBox(height: AppTheme.spacing16),
          VlessLinkCard(link: result.vlessLink, backup: false),
          if (result.backupVlessLink != null) ...[
            const SizedBox(height: AppTheme.spacing12),
            VlessLinkCard(link: result.backupVlessLink!, backup: true),
          ],
        ],
      ),
    );
  }

  Widget _chip(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: AppTheme.surface4,
        borderRadius: BorderRadius.circular(AppTheme.radiusPill),
      ),
      child: Text(text, style: const TextStyle(fontSize: 12)),
    );
  }

  Widget _panelCard(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppTheme.surface2,
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        border: Border.all(color: AppTheme.accentPrimary, width: 1.5),
      ),
      padding: const EdgeInsets.all(AppTheme.spacing16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.admin_panel_settings, color: AppTheme.accentPrimary),
              SizedBox(width: AppTheme.spacing8),
              Flexible(
                child: Text(
                  'Доступ к веб-панели 3X-UI',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppTheme.spacing16),
          _secretRow(
            context,
            'Ссылка на панель (URL)',
            result.panelUrl,
            'Ссылка панели скопирована',
          ),
          if (result.panelUrl.contains('127.0.0.1'))
            const Padding(
              padding: EdgeInsets.only(bottom: AppTheme.spacing8),
              child: Text(
                '🙈 Панель скрыта от интернета. Сначала открой SSH-туннель '
                '(команда есть в журнале развёртывания), потом жми кнопку.',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: () => _openPanel(context),
              icon: const Icon(Icons.open_in_browser),
              label: const Text('Открыть в браузере'),
            ),
          ),
          const SizedBox(height: AppTheme.spacing8),
          _secretRow(
            context,
            'Логин (Username)',
            result.panelUsername,
            'Логин скопирован',
          ),
          _secretRow(
            context,
            'Пароль (Password)',
            result.panelPassword,
            'Пароль скопирован',
          ),
          const SizedBox(height: AppTheme.spacing8),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () => _copy(
                context,
                result.allPanelData,
                'Данные панели скопированы',
              ),
              icon: const Icon(Icons.note_add_outlined),
              label: const Text(
                'Скопировать все данные панели (URL + Логин + Пароль)',
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _secretRow(
    BuildContext context,
    String label,
    String value,
    String copied,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.surface3,
                    borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
                  ),
                  child: SelectableText(
                    value,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Скопировать',
                onPressed: () => _copy(context, value, copied),
                icon: const Icon(Icons.copy, size: 18),
                color: AppTheme.accentPrimary,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
