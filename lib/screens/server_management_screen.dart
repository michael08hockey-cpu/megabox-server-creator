import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import '../models/server_config.dart';
import '../models/deployment_history.dart';
import '../services/server_management_service.dart';
import '../services/storage_service.dart';
import '../widgets/client_policy_selector.dart';
import '../widgets/diagnostics_view.dart';
import '../widgets/live_stats_panel.dart';
import '../widgets/ping_badge.dart';
import '../widgets/result_cards.dart';

import '../widgets/vless_link_card.dart';

/// Экран «Мои серверы»: живой SSH-мониторинг, бэкап базы
/// и переезд на новый VPS в 1 клик.
class ServerManagementScreen extends StatefulWidget {
  const ServerManagementScreen({super.key, this.service});
  final ServerManagementService? service;

  @override
  State<ServerManagementScreen> createState() => _ServerManagementScreenState();
}

class _ServerManagementScreenState extends State<ServerManagementScreen> {
  final StorageService _storageService = StorageService();
  late final ServerManagementService _service;

  List<DeploymentHistory> _history = <DeploymentHistory>[];
  DeploymentHistory? _selected;
  ServerLiveStats? _stats;
  String _password = '';
  bool _busy = false;
  bool _connected = false;
  bool get _isRoot => _selected?.sshUser == 'root';
  String _lastLink = '';
  List<String> _portLinks = <String>[];

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? ServerManagementService();
    StorageService.historyRevision.addListener(_loadHistory);
    _loadHistory();
  }

  @override
  void dispose() {
    StorageService.historyRevision.removeListener(_loadHistory);
    _service.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    final List<DeploymentHistory> items = await _storageService.loadHistory();
    if (mounted) {
      setState(() {
        _history = items;
        if (_selected != null) {
          final matches = items.where((item) => item.id == _selected!.id);
          if (matches.isEmpty) {
            _clearSelection();
          } else {
            _selected = matches.first;
          }
        }
      });
    }
  }

  void _clearSelection() {
    _service.disconnect();
    _selected = null;
    _connected = false;
    _stats = null;
    _password = '';
    _lastLink = '';
    _portLinks = [];
  }

  void _selectServer(DeploymentHistory item) {
    setState(() {
      _clearSelection();
      _selected = item;
    });
  }

  Future<void> _deleteLocalServer(DeploymentHistory item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      animationStyle: AnimationStyle.noAnimation,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить сервер из списка?'),
        content: Text(
          'Удалить локальную запись ${item.ipAddress}? '
          'Панель и ключи на VPS не будут удалены.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Удалить из списка'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _storageService.removeDeployment(item.id);
      await _loadHistory();
      _toast('Запись сервера удалена');
    } catch (e) {
      _toast('Ошибка удаления: $e', isError: true);
    }
  }

  Future<void> _clearLocalHistory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      animationStyle: AnimationStyle.noAnimation,
      builder: (ctx) => AlertDialog(
        title: const Text('Очистить список серверов?'),
        content: const Text(
          'Все локальные записи будут удалены. Сами VPS не изменятся.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Очистить список'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _storageService.clearHistory();
      await _loadHistory();
      _toast('Список серверов очищен');
    } catch (e) {
      _toast('Ошибка очистки: $e', isError: true);
    }
  }

  void _toast(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? AppTheme.error : AppTheme.surface4,
      ),
    );
  }

  ServerConfig _configFor(DeploymentHistory item, String password) {
    return item.toServerConfig(password: password);
  }

  /// Подключение к серверу и снятие живой статистики.
  Future<void> _connect(DeploymentHistory item) async {
    final String? password = item.hasSavedSshPassword
        ? item.sshPassword
        : await _askPassword(item.ipAddress);
    if (password == null || password.isEmpty || !mounted) return;

    setState(() {
      _busy = true;
      _connected = false;
      _selected = item;
      _password = password;
      _stats = null;
      _lastLink = '';
      _portLinks = [];
    });

    try {
      await _service.connectSSH(_configFor(item, password));
      final ServerLiveStats stats = await _service.getServerStats(
        password,
        _isRoot,
      );
      if (mounted) {
        setState(() {
          _stats = stats;
          _connected = true;
          _busy = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        _toast('❌ Ошибка подключения: $e', isError: true);
      }
    }
  }

  Future<String?> _askPassword(String ip) async {
    final TextEditingController controller = TextEditingController();
    final String? result = await showDialog<String>(
      context: context,
      animationStyle: AnimationStyle.noAnimation,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: AppTheme.surface3,
        title: Text('Подключение к $ip'),
        content: TextField(
          controller: controller,
          obscureText: true,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'SSH пароль',
            prefixIcon: Icon(Icons.key, color: AppTheme.accentPrimary),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Подключиться'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  Future<String?> _askText({
    required String title,
    required String label,
    String initial = '',
  }) async {
    final TextEditingController controller = TextEditingController(
      text: initial,
    );
    final String? result = await showDialog<String>(
      context: context,
      animationStyle: AnimationStyle.noAnimation,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: AppTheme.surface3,
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: label),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  /// Диалог выбора срока действия и лимита трафика.
  Future<ClientPolicy?> _askPolicy() async {
    ClientPolicy policy = const ClientPolicy();
    final formKey = GlobalKey<FormState>();
    final bool? saved = await showDialog<bool>(
      context: context,
      animationStyle: AnimationStyle.noAnimation,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx, StateSetter setInner) => AlertDialog(
          backgroundColor: AppTheme.surface3,
          title: const Text('Срок и лимит клиента'),
          content: Form(
            key: formKey,
            child: SizedBox(
              width: 360,
              child: SingleChildScrollView(
                child: ClientPolicySelector(
                  value: policy,
                  onChanged: (value) => setInner(() => policy = value),
                ),
              ),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () {
                if (formKey.currentState!.validate()) Navigator.pop(ctx, true);
              },
              child: const Text('Создать'),
            ),
          ],
        ),
      ),
    );
    if (saved != true) return null;
    return policy;
  }

  Future<void> _refreshStats() async {
    if (_selected == null) return;
    setState(() => _busy = true);
    try {
      final ServerLiveStats stats = await _service.getServerStats(
        _password,
        _isRoot,
      );
      if (mounted) setState(() => _stats = stats);
      _toast('✅ Данные обновлены');
    } catch (e) {
      if (mounted) _toast('❌ $e', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resetClientTraffic(String email) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Сбросить трафик?'),
        content: Text(
          'Счётчики трафика клиента «$email» обнулятся, '
          'x-ui перезапустится (клиенты переподключатся за пару секунд).',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Сбросить'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _service.resetClientTraffic(_password, _isRoot, email);
      _toast('✅ Трафик «$email» сброшен');
    } catch (e) {
      if (mounted) _toast('❌ $e', isError: true);
      rethrow;
    }
  }

  Future<void> _toggleClient(String email, bool enable) async {
    try {
      await _service.setClientEnabled(_password, _isRoot, email, enable);
      _toast(enable ? '▶️ Клиент «$email» включён' : '⏸️ Клиент «$email» отключён');
    } catch (e) {
      if (mounted) _toast('❌ $e', isError: true);
      rethrow;
    }
  }

  Future<void> _restartXray() async {
    if (_selected == null) return;
    setState(() => _busy = true);
    try {
      await _service.restartXray(_password, _isRoot);
      _toast('✅ Xray перезапущен');
      await Future<void>.delayed(const Duration(seconds: 2));
      final ServerLiveStats stats = await _service.getServerStats(
        _password,
        _isRoot,
      );
      if (mounted) setState(() => _stats = stats);
    } catch (e) {
      if (mounted) _toast('❌ $e', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _changeSni() async {
    final DeploymentHistory? item = _selected;
    if (item == null) return;
    final String? sni = await _askText(
      title: 'Новый маскировочный домен',
      label: 'SNI (например, www.microsoft.com)',
      initial: item.sni,
    );
    if (sni == null || sni.trim().isEmpty) return;

    setState(() => _busy = true);
    try {
      await _service.changeSni(_password, _isRoot, sni.trim());
      final links = await _service.getServerLinks(
        _password,
        _isRoot,
        item.ipAddress,
      );
      final main = links.where(
        (link) => Uri.parse(link).port == item.vlessPort,
      );
      final backup = links.where(
        (link) => Uri.parse(link).port == 8443 && item.vlessPort != 8443,
      );
      await _storageService.addDeployment(
        item.copyWith(
          sni: sni.trim(),
          shareLink: main.isEmpty ? item.shareLink : main.first,
          backupShareLink: backup.isEmpty ? item.backupShareLink : backup.first,
        ),
      );
      _toast('✅ SNI изменён на ${sni.trim()}');
    } catch (e) {
      if (mounted) _toast('❌ $e', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showServerLinks() async {
    if (_selected == null) return;
    setState(() => _busy = true);
    try {
      final links = await _service.getServerLinks(
        _password,
        _isRoot,
        _selected!.ipAddress,
      );
      if (mounted) {
        setState(() {
          _portLinks = links;
          _lastLink = links.join('\n');
        });
      }
    } catch (e) {
      _toast('❌ $e', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addFriend() async {
    final DeploymentHistory? item = _selected;
    if (item == null) return;
    final String? name = await _askText(
      title: 'Новый ключ',
      label: 'Имя друга (например, friend-ivan)',
      initial: 'friend',
    );
    if (name == null || name.trim().isEmpty) return;

    final ClientPolicy? policy = await _askPolicy();
    if (policy == null) return;

    setState(() => _busy = true);
    try {
      final links = await _service.addFriendKeys(
        _password,
        _isRoot,
        item.ipAddress,
        name.trim(),
        policy: policy,
      );
      final link = links.join('\n');
      await Clipboard.setData(ClipboardData(text: link));
      if (mounted) {
        setState(() {
          _lastLink = link;
          _portLinks = links;
        });
      }
      _toast('✅ Ключ создан и скопирован (${links.length})');
    } catch (e) {
      if (mounted) _toast('❌ $e', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Диагностика сохранённого сервера: доступность из сети пользователя
  /// и состояние VPS. Ничего на сервере не меняет.
  Future<void> _runDiagnostics() async {
    final DeploymentHistory? item = _selected;
    if (item == null) return;
    String password = _password.isNotEmpty ? _password : (item.sshPassword ?? '');
    if (password.isEmpty) {
      final entered = await _askPassword(item.ipAddress);
      if (entered == null || entered.isEmpty || !mounted) return;
      password = entered;
    }
    if (!mounted) return;
    final controller = DiagRunController();
    controller.start(
      host: item.ipAddress,
      sshPort: item.sshPort,
      user: item.sshUser,
      password: password,
      vlessPort: item.vlessPort,
    );
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.surface2,
      constraints: const BoxConstraints(maxWidth: 720),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppTheme.radiusLarge)),
      ),
      builder: (ctx) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(ctx).height * 0.85,
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
                        'Диагностика ${item.ipAddress}',
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Закрыть',
                      onPressed: () => Navigator.of(ctx).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const DiagVpnNote(),
                const SizedBox(height: 12),
                Expanded(
                  child: SingleChildScrollView(
                    child: DiagResultsColumn(controller: controller),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    // Прогон мог ещё идти: контроллер сам перестанет уведомлять после dispose.
    controller.dispose();
  }

  Future<void> _downloadBackup() async {
    if (_selected == null) return;
    setState(() => _busy = true);
    try {
      final String localPath =
          '${Directory.systemTemp.path}${Platform.pathSeparator}x-ui-backup-'
          '${DateTime.now().millisecondsSinceEpoch}.db';
      await _service.downloadBackup(_password, _isRoot, localPath);
      _toast('✅ Бэкап сохранён: $localPath');
    } catch (e) {
      if (mounted) _toast('❌ $e', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _migrate() async {
    final DeploymentHistory? item = _selected;
    if (item == null) return;

    final _MigrationForm? form = await _askMigration();
    if (form == null) return;

    setState(() => _busy = true);
    try {
      final List<String> links = await _service.migrateServer(
        oldPassword: _password,
        newIp: form.ip,
        newPort: form.port,
        newUser: form.login,
        newPassword: form.password,
      );
      final String joined = links.join('\n');
      await Clipboard.setData(ClipboardData(text: joined));
      if (mounted) {
        setState(() {
          _lastLink = joined;
          _portLinks = links;
        });
      }
      _toast('✅ Переезд завершён, ссылки скопированы (${links.length})');
    } catch (e) {
      if (mounted) _toast('❌ $e', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _removeXui() async {
    final DeploymentHistory? item = _selected;
    if (item == null) return;
    final bool? ok = await showDialog<bool>(
      context: context,
      animationStyle: AnimationStyle.noAnimation,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: AppTheme.surface3,
        title: const Text('Удалить панель 3X-UI?'),
        content: Text(
          'Сервер ${item.ipAddress} будет полностью очищен от 3X-UI '
          'и Xray. Действие необратимо.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _busy = true);
    try {
      await _service.removeXui(_password, _isRoot);
      if (mounted) {
        setState(() {
          _stats = null;
          _selected = null;
        });
      }
      _toast('✅ 3X-UI удалён');
      await _loadHistory();
    } catch (e) {
      if (mounted) _toast('❌ $e', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<_MigrationForm?> _askMigration() async {
    final TextEditingController ip = TextEditingController();
    final TextEditingController port = TextEditingController(text: '22');
    final TextEditingController login = TextEditingController(text: 'root');
    final TextEditingController pass = TextEditingController();

    final bool? ok = await showDialog<bool>(
      context: context,
      animationStyle: AnimationStyle.noAnimation,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: AppTheme.surface3,
        title: const Text('Переезд на новый VPS'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextField(
                controller: ip,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'IP нового сервера',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: port,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'SSH порт'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: login,
                decoration: const InputDecoration(labelText: 'Логин'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: pass,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Пароль'),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Переехать'),
          ),
        ],
      ),
    );

    _MigrationForm? form;
    if (ok == true && ip.text.trim().isNotEmpty) {
      form = _MigrationForm(
        ip: ip.text.trim(),
        port: int.tryParse(port.text.trim()) ?? 22,
        login: login.text.trim().isEmpty ? 'root' : login.text.trim(),
        password: pass.text,
      );
    }
    ip.dispose();
    port.dispose();
    login.dispose();
    pass.dispose();
    return form;
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.sizeOf(context).width < 760) {
      // Телефон: сначала список, по нажатию — панель сервера с кнопкой «Назад».
      return PopScope(
        canPop: _selected == null,
        onPopInvokedWithResult: (bool didPop, Object? _) {
          if (!didPop && _selected != null && !_busy) {
            setState(_clearSelection);
          }
        },
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: _selected == null
              ? _buildServerList()
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: _busy ? null : () => setState(_clearSelection),
                        icon: const Icon(Icons.arrow_back, size: 18),
                        label: const Text('Все серверы'),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Expanded(child: _buildDashboard()),
                  ],
                ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(flex: 2, child: _buildServerList()),
          const SizedBox(width: 20),
          Expanded(flex: 3, child: _buildDashboard()),
        ],
      ),
    );
  }

  Widget _buildServerList() {
    return Container(
      decoration: AppTheme.glassCard(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 10),
            child: Row(
              children: <Widget>[
                const Icon(Icons.dns, size: 18, color: AppTheme.accentPrimary),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Мои серверы',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                  ),
                ),
                IconButton(
                  tooltip: 'Очистить список серверов',
                  onPressed: _busy || _history.isEmpty
                      ? null
                      : _clearLocalHistory,
                  icon: const Icon(Icons.delete_sweep, size: 18),
                ),
                IconButton(
                  tooltip: 'Обновить список',
                  onPressed: _loadHistory,
                  icon: const Icon(Icons.refresh, size: 18),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _history.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'Пока нет развёрнутых серверов.\n'
                        'Разверните первый на вкладке «Развёртывание».',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: AppTheme.textSecondary),
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(10),
                    itemCount: _history.length,
                    separatorBuilder: (BuildContext _, int _) =>
                        const SizedBox(height: 8),
                    itemBuilder: (BuildContext ctx, int i) =>
                        _buildServerTile(_history[i]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildServerTile(DeploymentHistory item) {
    final bool isSelected = _selected != null && _selected!.id == item.id;
    return Material(
      color: isSelected ? AppTheme.surface4 : AppTheme.surface3,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: _busy ? null : () => _selectServer(item),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(
                    Icons.circle,
                    size: 9,
                    color: isSelected
                        ? AppTheme.success
                        : AppTheme.textSecondary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      item.remark.isEmpty ? item.ipAddress : item.remark,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    key: ValueKey('delete-server-${item.id}'),
                    tooltip: 'Удалить сервер из списка',
                    onPressed: _busy ? null : () => _deleteLocalServer(item),
                    icon: const Icon(Icons.delete_outline, size: 18),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      '${item.ipAddress}:${item.vlessPort}',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 12,
                        fontFamily: 'Consolas',
                      ),
                    ),
                  ),
                  PingBadge(host: item.ipAddress, port: item.vlessPort),
                ],
              ),
              if (item.sni.isNotEmpty) ...<Widget>[
                const SizedBox(height: 2),
                Text(
                  'SNI: ${item.sni}',
                  style: const TextStyle(
                    color: AppTheme.textMuted,
                    fontSize: 11,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _actionButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color? color,
  }) {
    return SizedBox(
      height: 44,
      child: ElevatedButton.icon(
        style: ElevatedButton.styleFrom(
          backgroundColor: color ?? AppTheme.surface4,
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 14),
        ),
        onPressed: _busy || !_connected ? null : onTap,
        icon: Icon(icon, size: 18),
        label: Text(label, style: const TextStyle(fontSize: 13)),
      ),
    );
  }

  Widget _buildDashboard() {
    final DeploymentHistory? item = _selected;
    if (item == null) {
      return Container(
        decoration: AppTheme.glassCard(),
        child: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.dashboard_customize,
                size: 44,
                color: AppTheme.textMuted,
              ),
              SizedBox(height: 14),
              Text(
                'Выберите сервер слева',
                style: TextStyle(color: AppTheme.textSecondary),
              ),
            ],
          ),
        ),
      );
    }

    final ServerLiveStats? s = _stats;
    return Container(
      decoration: AppTheme.glassCard(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 10, 12),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        item.remark.isEmpty ? item.ipAddress : item.remark,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${item.ipAddress} · порт ${item.vlessPort}',
                        style: const TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: 12,
                          fontFamily: 'Consolas',
                        ),
                      ),
                    ],
                  ),
                ),
                if (_busy)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                IconButton(
                  tooltip: 'Обновить статистику',
                  onPressed: _busy || !_connected ? null : _refreshStats,
                  icon: const Icon(Icons.sync),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(18),
              child: _buildDashboardBody(s),
            ),
          ),
        ],
      ),
    );
  }

  /// Карточка ссылки для конкретного порта: текст и кнопка копирования.
  Widget _buildPortLinkCard(String link) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: VlessLinkCard(link: link),
  );

  Widget _buildDashboardBody(ServerLiveStats? s) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ResultCards(result: _selected!.toDeploymentResult()),
        const SizedBox(height: 16),
        if (_selected!.panelUrl == null)
          const Text(
            'Старая запись: данные панели не были сохранены. '
            'Они появятся после нового развёртывания.',
          ),
        SelectableText(
          'SSH: ${_selected!.sshUser}@${_selected!.ipAddress}:${_selected!.sshPort}',
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          children: <Widget>[
            FilledButton.icon(
              onPressed: _busy ? null : () => _connect(_selected!),
              icon: const Icon(Icons.link),
              label: Text(
                _connected ? 'Переподключиться по SSH' : 'Подключиться по SSH',
              ),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _runDiagnostics,
              icon: const Icon(Icons.health_and_safety_outlined),
              label: const Text('Диагностика'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          'Пароли и ключи сохранены локально без шифрования.',
          style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
        ),
        const SizedBox(height: 16),
        if (!_connected)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 28),
            decoration: AppTheme.glassCard(),
            child: const Center(
              child: Text(
                'Подключитесь по SSH для живой статистики и управления клиентами.',
                style: TextStyle(color: AppTheme.textSecondary),
              ),
            ),
          )
        else
          LiveStatsPanel(
            key: ValueKey<String>('stats-${_selected!.ipAddress}-${_selected!.sshPort}'),
            initial: s,
            fetch: () => _service.getServerStats(_password, _isRoot),
            onResetTraffic: _resetClientTraffic,
            onToggleClient: _toggleClient,
          ),
        const SizedBox(height: 22),
        const Text(
          'ДЕЙСТВИЯ',
          style: TextStyle(
            color: AppTheme.textSecondary,
            fontSize: 11,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: <Widget>[
            _actionButton(
              icon: Icons.restart_alt,
              label: 'Перезапустить Xray',
              onTap: _restartXray,
            ),
            _actionButton(
              icon: Icons.public,
              label: 'Сменить SNI',
              onTap: _changeSni,
            ),
            _actionButton(
              icon: Icons.person_add,
              label: 'Создать ключ клиента',
              onTap: _addFriend,
            ),
            _actionButton(
              icon: Icons.download,
              label: 'Скачать бэкап БД',
              onTap: _downloadBackup,
            ),
            _actionButton(
              icon: Icons.swap_horiz,
              label: 'Переезд на новый VPS',
              onTap: _migrate,
            ),
            _actionButton(
              icon: Icons.link,
              label: 'Ссылки (443 / 8443)',
              onTap: _showServerLinks,
            ),
            _actionButton(
              icon: Icons.delete_forever,
              label: 'Удалить 3X-UI',
              onTap: _removeXui,
              color: AppTheme.error,
            ),
          ],
        ),
        if (_portLinks.isNotEmpty) ...<Widget>[
          const SizedBox(height: 20),
          Text(
            '🔗 ССЫЛКИ ПО ПОРТАМ (443 / 8443)',
            style: TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 11,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 8),
          ..._portLinks.map(_buildPortLinkCard),
        ],
        if (_lastLink.isNotEmpty) ...<Widget>[
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppTheme.surface3,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.surface4),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  'ПОСЛЕДНИЕ КЛЮЧИ (скопированы в буфер обмена)',
                  style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 11,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: 8),
                SelectableText(
                  _lastLink,
                  style: const TextStyle(
                    fontSize: 12,
                    fontFamily: 'Consolas',
                    color: AppTheme.accentPrimary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// Данные формы переезда на новый VPS.
class _MigrationForm {
  const _MigrationForm({
    required this.ip,
    required this.port,
    required this.login,
    required this.password,
  });

  final String ip;
  final int port;
  final String login;
  final String password;
}
