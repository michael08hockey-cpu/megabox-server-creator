import 'package:flutter/material.dart';

import '../models/deployment_history.dart';
import '../services/storage_service.dart';
import '../theme/app_theme.dart';
import '../widgets/diagnostics_view.dart';

/// Отдельная вкладка «Проверка»: диагностика любого сервера
/// (нового или из списка «Мои серверы») без развёртывания.
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  final _formKey = GlobalKey<FormState>();
  final _ip = TextEditingController();
  final _sshPort = TextEditingController(text: '22');
  final _user = TextEditingController(text: 'root');
  final _password = TextEditingController();
  final _vlessPort = TextEditingController(text: '443');
  final DiagRunController _controller = DiagRunController();
  List<DeploymentHistory> _saved = <DeploymentHistory>[];

  @override
  void initState() {
    super.initState();
    _loadSaved();
    StorageService.historyRevision.addListener(_loadSaved);
  }

  Future<void> _loadSaved() async {
    try {
      final items = await StorageService().loadHistory();
      if (mounted) setState(() => _saved = items);
    } catch (_) {
      // Список сохранённых серверов — только удобство.
    }
  }

  @override
  void dispose() {
    StorageService.historyRevision.removeListener(_loadSaved);
    _ip.dispose();
    _sshPort.dispose();
    _user.dispose();
    _password.dispose();
    _vlessPort.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _fillFrom(DeploymentHistory item) {
    setState(() {
      _ip.text = item.ipAddress;
      _sshPort.text = '${item.sshPort}';
      _user.text = item.sshUser;
      _password.text = item.sshPassword ?? '';
      _vlessPort.text = '${item.vlessPort}';
    });
  }

  Future<void> _start() async {
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    await _controller.start(
      host: _ip.text.trim(),
      sshPort: int.parse(_sshPort.text.trim()),
      user: _user.text.trim(),
      password: _password.text,
      vlessPort: int.parse(_vlessPort.text.trim()),
    );
  }

  String? _required(String? v) =>
      v == null || v.trim().isEmpty ? 'Обязательно' : null;

  String? _port(String? v) {
    final n = int.tryParse((v ?? '').trim());
    return n == null || n < 1 || n > 65535 ? '1–65535' : null;
  }

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 760;
    final pad = narrow ? 12.0 : 20.0;
    return SingleChildScrollView(
      padding: EdgeInsets.all(pad),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Container(
                padding: EdgeInsets.all(narrow ? 16 : 22),
                decoration: AppTheme.glassCard(),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      const Row(
                        children: <Widget>[
                          Icon(Icons.health_and_safety, color: AppTheme.accentPrimary),
                          SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Диагностика сервера',
                              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'Проверит, не заблокирован ли IP из твоей сети, подходит ли '
                        'пароль, хватает ли памяти и диска, свободен ли порт и есть '
                        'ли у сервера доступ к GitHub. Ничего на сервере не меняет.',
                        style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                      ),
                      if (_saved.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 14),
                        const Text(
                          'Из моих серверов:',
                          style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: <Widget>[
                            for (final item in _saved.take(8))
                              ActionChip(
                                avatar: const Icon(Icons.dns, size: 16),
                                label: Text(
                                  item.remark.isEmpty ? item.ipAddress : item.remark,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                onPressed: _controller.running ? null : () => _fillFrom(item),
                              ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _ip,
                        decoration: const InputDecoration(
                          labelText: 'IP-адрес VPS',
                          prefixIcon: Icon(Icons.dns),
                        ),
                        keyboardType: TextInputType.url,
                        validator: _required,
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: TextFormField(
                              controller: _sshPort,
                              decoration: const InputDecoration(
                                labelText: 'Порт SSH',
                                prefixIcon: Icon(Icons.lan),
                              ),
                              keyboardType: TextInputType.number,
                              validator: _port,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextFormField(
                              controller: _user,
                              decoration: const InputDecoration(
                                labelText: 'Пользователь',
                                prefixIcon: Icon(Icons.person),
                              ),
                              validator: _required,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: <Widget>[
                          Expanded(
                            flex: 2,
                            child: TextFormField(
                              controller: _password,
                              obscureText: true,
                              decoration: const InputDecoration(
                                labelText: 'Пароль SSH',
                                prefixIcon: Icon(Icons.lock),
                              ),
                              validator: _required,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextFormField(
                              controller: _vlessPort,
                              decoration: const InputDecoration(
                                labelText: 'Порт VLESS',
                              ),
                              keyboardType: TextInputType.number,
                              validator: _port,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      ListenableBuilder(
                        listenable: _controller,
                        builder: (context, _) => FilledButton.icon(
                          onPressed: _controller.running ? null : _start,
                          icon: _controller.running
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.play_arrow),
                          label: Text(
                            _controller.running ? 'Проверяю…' : 'Запустить проверку',
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      const DiagVpnNote(),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              DiagResultsColumn(controller: _controller),
            ],
          ),
        ),
      ),
    );
  }
}
