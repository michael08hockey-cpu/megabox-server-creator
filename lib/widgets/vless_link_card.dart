import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';

/// Compact, text-only client key card shared by deployment and management.
class VlessLinkCard extends StatelessWidget {
  const VlessLinkCard({super.key, required this.link, this.title, this.backup});

  final String link;
  final String? title;
  final bool? backup;

  @override
  Widget build(BuildContext context) {
    final uri = Uri.tryParse(link);
    final isBackup = backup ?? uri?.port == 8443;
    final parameters = uri?.queryParameters ?? const <String, String>{};
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppTheme.spacing12),
      decoration: BoxDecoration(
        color: AppTheme.surface3,
        borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
        border: Border.all(color: AppTheme.surface4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title ??
                (isBackup
                    ? 'Резервный ключ — порт 8443'
                    : 'Основной ключ — порт ${uri?.port ?? 443}'),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _badge('Порт: ${uri?.port ?? 443}'),
              _badge('SNI: ${parameters['sni'] ?? 'не указан'}'),
              _badge('uTLS: ${parameters['fp'] ?? 'firefox'}'),
              if (parameters['type'] == 'xhttp')
                _badge('Транспорт: XHTTP')
              else
                _badge('Flow: ${parameters['flow'] ?? 'xtls-rprx-vision'}'),
            ],
          ),
          const SizedBox(height: 8),
          SelectableText(
            link,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
              color: AppTheme.textSecondary,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: link));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    isBackup ? 'Резервный ключ скопирован' : 'Ключ скопирован',
                  ),
                  duration: const Duration(seconds: 2),
                ),
              );
            },
            icon: const Icon(Icons.copy, size: 16),
            label: Text(
              isBackup ? 'Копировать резервный ключ' : 'Копировать ключ',
            ),
          ),
        ],
      ),
    );
  }

  Widget _badge(String label) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: AppTheme.surface4,
      borderRadius: BorderRadius.circular(AppTheme.radiusPill),
    ),
    child: Text(label, style: const TextStyle(fontSize: 11)),
  );
}
