import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/terminal_line.dart';
import '../theme/app_theme.dart';
import '../models/server_config.dart';
import '../models/deployment_history.dart';
import '../services/ssh_service.dart';
import '../services/storage_service.dart';
import '../widgets/log_terminal.dart';
import '../widgets/result_cards.dart';
import '../models/deployment_result.dart';
import '../widgets/client_policy_selector.dart';
import '../widgets/diagnostics_view.dart';

/// Варианты срока жизни гостевого ключа.
class KeyExpiryOption {
  final String label;
  final int? hours;

  const KeyExpiryOption(this.label, this.hours);

  static const List<KeyExpiryOption> all = [
    KeyExpiryOption('Без ограничений', null),
    KeyExpiryOption('24 часа', 24),
    KeyExpiryOption('3 дня', 72),
    KeyExpiryOption('7 дней', 168),
    KeyExpiryOption('30 дней', 720),
  ];
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _formKey = GlobalKey<FormState>();
  final _ipController = TextEditingController();
  final _sshPortController = TextEditingController(text: '22');
  final _sshUserController = TextEditingController(text: 'root');
  final _sshPasswordController = TextEditingController();
  final _vlessPortController = TextEditingController(text: '443');
  final _remarkController = TextEditingController(text: 'VLESS-REALITY');
  final _tgTokenController = TextEditingController();
  final _tgChatIdController = TextEditingController();
  final _friendsController = TextEditingController();
  final _selfStealDomainController = TextEditingController();

  ServerLocation _selectedLocation = ServerLocation.auto;
  bool _isDeploying = false;
  DeploymentResult? _result;

  // ===== Тумблеры «Стелс+ и Самолечение» =====
  bool _autoSwap = true;
  bool _watchdogEnabled = true;
  bool _decoyWebsite = false;
  bool _temporaryKeys = true;

  // ===== Дополнительные опции =====
  bool _bypassRuDomains = true;
  bool _antiTorrent = true;
  bool _adBlock = false;
  bool _backupInbound = false;
  bool _cloudflareWarp = false;

  // ===== Защита от блокировок ТСПУ =====
  bool _useXhttp = true;
  bool _hidePanel = true;
  bool _xhttpObfs = true;
  bool _updateXrayCore = true;

  // ===== Проверка сервера перед установкой =====
  bool _preflight = true;

  /// Телефон: 0 — форма, 1 — журнал и результат.
  int _mobilePane = 0;

  ClientPolicy _policy = const ClientPolicy();

  final SSHService _sshService = SSHService();
  final StorageService _storageService = StorageService();

  // ===== Живой терминал =====
  final _TerminalBuffer _terminalBuffer = _TerminalBuffer();
  StreamSubscription<TerminalLine>? _terminalSub;
  bool _showTerminal = false;

  @override
  void initState() {
    super.initState();
    _terminalSub = _sshService.terminalStream.listen(_terminalBuffer.add);
  }

  @override
  void dispose() {
    _terminalSub?.cancel();
    _terminalBuffer.dispose();
    _ipController.dispose();
    _sshPortController.dispose();
    _sshUserController.dispose();
    _sshPasswordController.dispose();
    _vlessPortController.dispose();
    _selfStealDomainController.dispose();
    _remarkController.dispose();
    _tgTokenController.dispose();
    _tgChatIdController.dispose();
    _friendsController.dispose();
    _sshService.dispose();
    super.dispose();
  }

  List<String> _parseFriends() {
    return _friendsController.text
        .split(RegExp(r'[\n,;]'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  Future<void> _startDeployment() async {
    if (!_formKey.currentState!.validate()) return;

    final token = _tgTokenController.text.trim();
    final chatId = _tgChatIdController.text.trim();
    if ((token.isEmpty) != (chatId.isEmpty)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Заполните оба поля Telegram-бота: Bot Token и Chat ID (или оставьте пустыми)',
          ),
          backgroundColor: AppTheme.warning,
        ),
      );
      return;
    }

    if (_preflight) {
      final go = await showPreflightSheet(
        context,
        host: _ipController.text.trim(),
        sshPort: int.parse(_sshPortController.text.trim()),
        user: _sshUserController.text.trim(),
        password: _sshPasswordController.text,
        vlessPort: int.parse(_vlessPortController.text.trim()),
      );
      if (!go || !mounted) return;
    }

    setState(() {
      _isDeploying = true;
      _result = null;
      _mobilePane = 1;
    });

    try {
      final config = ServerConfig(
        ipAddress: _ipController.text.trim(),
        sshPort: int.parse(_sshPortController.text),
        sshUser: _sshUserController.text.trim(),
        sshPassword: _sshPasswordController.text,
        location: _selectedLocation,
        vlessPort: int.parse(_vlessPortController.text),
        remark: _remarkController.text.trim(),
        options: DeploymentOptions(
          cleanReinstall: true,
          antiTorrent: _antiTorrent,
          adBlock: _adBlock,
          fail2ban: false,
          backupInbound: _backupInbound,
          bypassRuDomains: _bypassRuDomains,
          cloudflareWarp: _cloudflareWarp,
          tgBotToken: token.isEmpty ? null : token,
          tgBotChatId: chatId.isEmpty ? null : chatId,
          friendNames: _parseFriends(),
          limitIp: 0,
          limitGb: _policy.trafficGb,
          autoSwap: _autoSwap,
          watchdogEnabled: _watchdogEnabled,
          decoyWebsite: _decoyWebsite,
          temporaryKeys: _temporaryKeys,
          keyExpiryHours: _temporaryKeys ? _policy.hours : null,
          transport: _useXhttp ? 'xhttp' : 'tcp',
          hidePanel: _hidePanel,
          xhttpObfs: _xhttpObfs,
          updateXrayCore: _updateXrayCore,
          selfStealDomain: _selfStealDomainController.text.trim().isEmpty
              ? null
              : _selfStealDomainController.text.trim().toLowerCase(),
        ),
      );

      final result = await _sshService.deployServer(config);

      if (mounted) setState(() => _result = result);
      final history = DeploymentHistory.fromDeployment(config, result);
      try {
        await _storageService.addDeployment(history);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Сервер развёрнут, но данные не сохранены: $e. '
                'Скопируйте ключи и данные панели из карточек.',
              ),
              backgroundColor: AppTheme.warning,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Ошибка развёртывания: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isDeploying = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 760;
    if (narrow) {
      // Телефон: форма и журнал — две страницы с переключателем сверху.
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
              child: SizedBox(
                width: double.infinity,
                child: SegmentedButton<int>(
                  segments: <ButtonSegment<int>>[
                    const ButtonSegment<int>(
                      value: 0,
                      icon: Icon(Icons.tune, size: 16),
                      label: Text('Настройка'),
                    ),
                    ButtonSegment<int>(
                      value: 1,
                      icon: Icon(
                        _result != null ? Icons.vpn_key : Icons.list_alt,
                        size: 16,
                      ),
                      label: Text(_result != null ? 'Ключи' : 'Журнал'),
                    ),
                  ],
                  selected: <int>{_mobilePane},
                  onSelectionChanged: (Set<int> v) =>
                      setState(() => _mobilePane = v.first),
                ),
              ),
            ),
            Expanded(
              child: IndexedStack(
                index: _mobilePane,
                children: [
                  _buildFormPanel(compact: true),
                  _buildRightPanel(compact: true),
                ],
              ),
            ),
          ],
        ),
      );
    }
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Row(
        children: [
          Expanded(flex: 2, child: _buildFormPanel()),
          Expanded(flex: 3, child: _buildRightPanel()),
        ],
      ),
    );
  }

  Widget _buildFormPanel({bool compact = false}) {
    return Container(
      margin: compact
          ? const EdgeInsets.fromLTRB(12, 10, 12, 12)
          : const EdgeInsets.fromLTRB(20, 20, 10, 20),
      padding: EdgeInsets.all(compact ? AppTheme.spacing16 : AppTheme.spacing24),
      decoration: AppTheme.glassCard(),
      child: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      gradient: AppTheme.brandGradient,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.dns_rounded, color: Colors.white),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Настройка сервера',
                          style: Theme.of(context).textTheme.displayMedium,
                        ),
                        const Text(
                          'IP, пароль — и через пару минут готовая VLESS-ссылка',
                          style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppTheme.spacing24),
              _buildTextField(
                controller: _ipController,
                label: 'IP-адрес VPS',
                hint: '1.2.3.4',
                icon: Icons.dns,
                validator: (v) => v == null || v.isEmpty ? 'Обязательно' : null,
              ),
              const SizedBox(height: AppTheme.spacing16),
              Row(
                children: [
                  Expanded(
                    child: _buildTextField(
                      controller: _sshPortController,
                      label: 'Порт SSH',
                      icon: Icons.lan,
                      keyboardType: TextInputType.number,
                      validator: (v) =>
                          v == null || v.isEmpty ? 'Обязательно' : null,
                    ),
                  ),
                  const SizedBox(width: AppTheme.spacing12),
                  Expanded(
                    child: _buildTextField(
                      controller: _sshUserController,
                      label: 'Пользователь SSH',
                      icon: Icons.person,
                      validator: (v) =>
                          v == null || v.isEmpty ? 'Обязательно' : null,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppTheme.spacing16),
              _buildTextField(
                controller: _sshPasswordController,
                label: 'Пароль SSH',
                icon: Icons.lock,
                obscureText: true,
                validator: (v) => v == null || v.isEmpty ? 'Обязательно' : null,
              ),
              const SizedBox(height: AppTheme.spacing24),
              const Divider(height: 1),
              const SizedBox(height: AppTheme.spacing24),
              Text(
                'Страна и VLESS REALITY',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: AppTheme.spacing8),
              Text(
                'Маска (SNI) подберётся с самого сервера: настоящий сайт '
                'по соседству в той же сети',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: AppTheme.textMuted),
              ),
              const SizedBox(height: AppTheme.spacing12),
              _buildLocationPicker(),
              const SizedBox(height: AppTheme.spacing16),
              Row(
                children: [
                  Expanded(
                    child: _buildTextField(
                      controller: _vlessPortController,
                      label: 'Порт VLESS',
                      icon: Icons.power,
                      keyboardType: TextInputType.number,
                      validator: (v) =>
                          v == null || v.isEmpty ? 'Обязательно' : null,
                    ),
                  ),
                  const SizedBox(width: AppTheme.spacing12),
                  Expanded(
                    child: _buildTextField(
                      controller: _remarkController,
                      label: 'Название',
                      icon: Icons.label,
                      validator: (v) =>
                          v == null || v.isEmpty ? 'Обязательно' : null,
                    ),
                  ),
                ],
              ),

              const SizedBox(height: AppTheme.spacing24),
              const Divider(height: 1),
              const SizedBox(height: AppTheme.spacing24),
              Text(
                '🛡️ Защита от блокировок (ТСПУ)',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: AppTheme.spacing12),
              _buildToggle(
                '🚀 Транспорт XHTTP вместо TCP',
                'TCP+Reality ТСПУ блокирует массово с 2026. XHTTP пока проходит',
                _useXhttp,
                (v) => setState(() => _useXhttp = v),
              ),
              if (_useXhttp)
                _buildToggle(
                  '🎭 Маскировка XHTTP-трафика',
                  'Убирает известный «почерк» Xray в запросах. '
                  'Клиенты: свежие v2rayN, v2rayNG, Happ',
                  _xhttpObfs,
                  (v) => setState(() => _xhttpObfs = v),
                ),
              _buildToggle(
                '⬆️ Свежее ядро Xray + защита MPTCP',
                'Ставит последнюю версию Xray (откат, если не запустится) '
                'и закрывает уязвимость MPTCP',
                _updateXrayCore,
                (v) => setState(() => _updateXrayCore = v),
              ),
              _buildToggle(
                '🙈 Скрыть панель 3X-UI от интернета',
                'Открытая панель на IP выдаёт VPN-сервер сканерам. '
                'Вход в панель — через SSH-туннель',
                _hidePanel,
                (v) => setState(() => _hidePanel = v),
              ),
              _buildTextField(
                controller: _selfStealDomainController,
                label: 'Свой домен для self-steal (необязательно)',
                hint: 'например photo.lena-notes.com',
                icon: Icons.language,
                validator: (v) {
                  final d = (v ?? '').trim().toLowerCase();
                  if (d.isEmpty) return null;
                  if (!SSHService.isValidSelfStealDomain(d)) {
                    return 'Некорректный домен';
                  }
                  if (SSHService.domainLooksLikeVpn(d)) {
                    return 'Без слов vpn, proxy, xray и т.п. — SNI виден ТСПУ';
                  }
                  return null;
                },
              ),
              const SizedBox(height: AppTheme.spacing8),
              Text(
                'Лучшая защита: Reality маскируется под твой же сайт. '
                'Купи домен и сделай A-запись на IP сервера (без Cloudflare-прокси) — '
                'сайт и сертификат приложение настроит само.',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: AppTheme.textMuted),
              ),

              const SizedBox(height: AppTheme.spacing24),
              const Divider(height: 1),
              const SizedBox(height: AppTheme.spacing24),
              Text(
                '🥷 Стелс+ и Самолечение',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: AppTheme.spacing12),
              _buildToggle(
                '💾 Авто-создание файла подкачки (Swap 2 GB)',
                'Спасает слабые VPS от падений по нехватке RAM',
                _autoSwap,
                (v) => setState(() => _autoSwap = v),
              ),
              _buildToggle(
                '🐕 Автономный сторожевой таймер (Watchdog + Telegram Alerts)',
                'Автоматический перезапуск сервера при зависании и отправка алярмов в Telegram',
                _watchdogEnabled,
                (v) => setState(() => _watchdogEnabled = v),
              ),
              _buildToggle(
                '🥷 Спрятать панель 3X-UI за фейковым сайтом (Decoy Website)',
                'Маскировка админки под пустой сайт-заглушку',
                _decoyWebsite,
                (v) => setState(() => _decoyWebsite = v),
              ),
              _buildToggle(
                '⏱ Режим временных гостевых ключей',
                'Возможность указывать срок жизни создаваемых ключей в часах/днях',
                _temporaryKeys,
                (v) => setState(() => _temporaryKeys = v),
              ),

              const SizedBox(height: AppTheme.spacing24),
              const Divider(height: 1),
              const SizedBox(height: AppTheme.spacing24),
              Text(
                '🌐 Маршрутизация и обход блокировок',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: AppTheme.spacing12),
              _buildToggle(
                '🛡 Подключить Cloudflare WARP (для ChatGPT, Claude, Netflix, Google)',
                'Домены openai.com, chatgpt.com, claude.ai, anthropic.com, netflix.com идут через WARP, остальное — напрямую',
                _cloudflareWarp,
                (v) => setState(() => _cloudflareWarp = v),
              ),
              _buildToggle(
                '🇷🇺 Обход .RU доменов',
                'Российские сайты идут напрямую без прокси',
                _bypassRuDomains,
                (v) => setState(() => _bypassRuDomains = v),
              ),
              _buildToggle(
                '🧲 Анти-Торрент (блокировка bittorrent)',
                'Торренты через сервер — тысячи соединений и жалобы хостеру',
                _antiTorrent,
                (v) => setState(() => _antiTorrent = v),
              ),
              _buildToggle(
                '🚫 AdBlock (геосит category-ads-all)',
                'Блокирует рекламные домены',
                _adBlock,
                (v) => setState(() => _adBlock = v),
              ),
              _buildToggle(
                '🔁 Резервный Inbound на порту 8443',
                'Не рекомендуется: Reality не на 443 повышает риск бана IP',
                _backupInbound,
                (v) => setState(() => _backupInbound = v),
              ),

              const SizedBox(height: AppTheme.spacing24),
              const Divider(height: 1),
              const SizedBox(height: AppTheme.spacing24),
              Text(
                '👥 Гостевые ключи',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: AppTheme.spacing8),
              Text(
                'Имена друзей через запятую или с новой строки',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: AppTheme.textMuted),
              ),
              const SizedBox(height: AppTheme.spacing12),
              _buildTextField(
                controller: _friendsController,
                label: 'Имена друзей (email)',
                hint: 'ivan, petr, alex',
                icon: Icons.groups,
              ),
              const SizedBox(height: AppTheme.spacing16),
              _buildExpiryDropdown(),
              if (_temporaryKeys && _policy.hours == null)
                Padding(
                  padding: const EdgeInsets.only(top: AppTheme.spacing8),
                  child: Text(
                    '⚠️ Выбран режим «Без ограничений» — ключи будут бессрочными',
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: AppTheme.warning),
                  ),
                ),

              const SizedBox(height: AppTheme.spacing24),
              const Divider(height: 1),
              const SizedBox(height: AppTheme.spacing24),
              Text(
                '📱 Telegram-бот панели 3X-UI',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: AppTheme.spacing8),
              Text(
                'Необязательно. Нужен для авто-бэкапов и алярмов Watchdog',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: AppTheme.textMuted),
              ),
              const SizedBox(height: AppTheme.spacing12),
              _buildTextField(
                controller: _tgTokenController,
                label: 'Bot Token',
                hint: '123456789:AA...',
                icon: Icons.smart_button_outlined,
              ),
              const SizedBox(height: AppTheme.spacing12),
              _buildTextField(
                controller: _tgChatIdController,
                label: 'Telegram Chat ID',
                hint: '-1001234567890',
                icon: Icons.chat_outlined,
              ),

              const SizedBox(height: AppTheme.spacing24),
              _buildToggle(
                '🩺 Проверить сервер перед установкой',
                'Связь из твоей сети (не забанен ли IP), пароль, память, диск, порт, доступ к GitHub',
                _preflight,
                (v) => setState(() => _preflight = v),
              ),
              const SizedBox(height: AppTheme.spacing16),
              Container(
                width: double.infinity,
                height: 56,
                decoration: BoxDecoration(
                  gradient: _isDeploying ? null : AppTheme.brandGradient,
                  color: _isDeploying ? AppTheme.surface4 : null,
                  borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
                  boxShadow: _isDeploying
                      ? null
                      : [
                          BoxShadow(
                            color: AppTheme.accentPrimary.withValues(alpha: 0.35),
                            blurRadius: 20,
                            offset: const Offset(0, 6),
                          ),
                        ],
                ),
                child: ElevatedButton.icon(
                  onPressed: _isDeploying ? null : _startDeployment,
                  icon: _isDeploying
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation(
                              AppTheme.surface1,
                            ),
                          ),
                        )
                      : const Icon(Icons.rocket_launch),
                  label: Text(
                    _isDeploying ? 'Развёртывание...' : 'Развернуть сервер',
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.transparent,
                    disabledBackgroundColor: Colors.transparent,
                    shadowColor: Colors.transparent,
                    foregroundColor: Colors.white,
                    disabledForegroundColor: AppTheme.textSecondary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
                    ),
                    textStyle: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildToggle(
    String title,
    String subtitle,
    bool value,
    ValueChanged<bool> onChanged,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTheme.spacing12),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
          onTap: _isDeploying ? null : () => onChanged(!value),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(
              horizontal: AppTheme.spacing12,
              vertical: AppTheme.spacing8,
            ),
            decoration: BoxDecoration(
              color: value
                  ? AppTheme.accentPrimary.withValues(alpha: 0.07)
                  : AppTheme.surface3,
              borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
              border: Border.all(
                color: value
                    ? AppTheme.accentPrimary.withValues(alpha: 0.5)
                    : AppTheme.surface4,
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: value
                              ? AppTheme.textPrimary
                              : AppTheme.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(color: AppTheme.textMuted),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: AppTheme.spacing12),
                Switch(
                  value: value,
                  onChanged: _isDeploying ? null : onChanged,
                  activeThumbColor: AppTheme.accentPrimary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildExpiryDropdown() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Срок действия и лимит трафика',
          style: Theme.of(context).textTheme.labelLarge,
        ),
        const SizedBox(height: AppTheme.spacing8),
        ClientPolicySelector(
          value: _policy,
          onChanged: _isDeploying
              ? (_) {}
              : (value) => setState(() {
                  _policy = value;
                  _temporaryKeys = true;
                }),
        ),
      ],
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    String? hint,
    bool obscureText = false,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: controller,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(icon, color: AppTheme.textMuted),
      ),
      obscureText: obscureText,
      keyboardType: keyboardType,
      validator: validator,
      enabled: !_isDeploying,
    );
  }

  Widget _buildLocationPicker() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: ServerLocation.all.map((loc) {
        final selected = loc.code == _selectedLocation.code;
        return InkWell(
          onTap: _isDeploying
              ? null
              : () => setState(() => _selectedLocation = loc),
          borderRadius: BorderRadius.circular(AppTheme.radiusPill),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: selected
                  ? AppTheme.accentPrimary.withValues(alpha: 0.18)
                  : AppTheme.surface3,
              borderRadius: BorderRadius.circular(AppTheme.radiusPill),
              border: Border.all(
                color: selected ? AppTheme.accentPrimary : AppTheme.surface5,
              ),
            ),
            child: Text(
              '${loc.flag}  ${loc.nameRu}',
              style: TextStyle(
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? AppTheme.accentPrimary : AppTheme.textPrimary,
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildRightPanel({bool compact = false}) {
    return Container(
      margin: compact
          ? const EdgeInsets.fromLTRB(12, 10, 12, 12)
          : const EdgeInsets.fromLTRB(10, 20, 20, 20),
      padding: EdgeInsets.all(compact ? AppTheme.spacing12 : AppTheme.spacing16),
      decoration: AppTheme.glassCard(),
      child: Column(
        children: [
          SegmentedButton<bool>(
            segments: <ButtonSegment<bool>>[
              ButtonSegment<bool>(
                value: false,
                icon: const Icon(Icons.list_alt, size: 16),
                label: Text(compact ? 'Журнал' : 'Журнал развёртывания'),
              ),
              ButtonSegment<bool>(
                value: true,
                icon: const Icon(Icons.terminal, size: 16),
                label: Text(compact ? 'Терминал' : 'Живой терминал'),
              ),
            ],
            selected: <bool>{_showTerminal},
            onSelectionChanged: (Set<bool> value) =>
                setState(() => _showTerminal = value.first),
          ),
          const SizedBox(height: AppTheme.spacing8),
          Expanded(
            flex: _result == null ? 1 : (compact ? 1 : 2),
            // Оба экрана остаются смонтированными, чтобы не терять записи.
            child: IndexedStack(
              index: _showTerminal ? 1 : 0,
              children: [
                LogTerminal(logStream: _sshService.logStream),
                _LiveTerminal(buffer: _terminalBuffer),
              ],
            ),
          ),
          if (_result != null) ...[
            const SizedBox(height: AppTheme.spacing12),
            Expanded(
              flex: compact ? 4 : 3,
              child: SingleChildScrollView(
                child: ResultCards(
                  result: _result!,
                  onClose: () => setState(() => _result = null),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Буфер строк живого терминала (с ограничением размера).
class _TerminalBuffer extends ChangeNotifier {
  static const int _maxLines = 5000;
  final List<TerminalLine> lines = <TerminalLine>[];

  void add(TerminalLine line) {
    lines.add(line);
    if (lines.length > _maxLines) {
      lines.removeRange(0, lines.length - _maxLines);
    }
    notifyListeners();
  }

  void clear() {
    lines.clear();
    notifyListeners();
  }
}

/// Чёрный моноширинный терминал с автоскроллом: SSH-команды и ответы сервера.
class _LiveTerminal extends StatefulWidget {
  final _TerminalBuffer buffer;

  const _LiveTerminal({required this.buffer});

  @override
  State<_LiveTerminal> createState() => _LiveTerminalState();
}

class _LiveTerminalState extends State<_LiveTerminal> {
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.buffer.addListener(_scrollToEnd);
  }

  @override
  void dispose() {
    widget.buffer.removeListener(_scrollToEnd);
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  Color _colorFor(TerminalLineKind kind) {
    switch (kind) {
      case TerminalLineKind.command:
        return AppTheme.success;
      case TerminalLineKind.stderr:
        return AppTheme.error;
      case TerminalLineKind.info:
        return AppTheme.textMuted;
      case TerminalLineKind.stdout:
        return const Color(0xFFD4D4D4);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        border: Border.all(color: AppTheme.surface4),
      ),
      padding: const EdgeInsets.all(AppTheme.spacing12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.terminal, color: AppTheme.success, size: 18),
              const SizedBox(width: AppTheme.spacing8),
              const Text(
                'Живой терминал',
                style: TextStyle(
                  color: Colors.white,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Копировать',
                icon: const Icon(Icons.copy, size: 16, color: Colors.white70),
                onPressed: () {
                  final text = widget.buffer.lines
                      .map((TerminalLine l) => l.toPlainText())
                      .join('\n');
                  Clipboard.setData(ClipboardData(text: text));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Терминал скопирован')),
                  );
                },
              ),
              IconButton(
                tooltip: 'Очистить',
                icon: const Icon(
                  Icons.delete_outline,
                  size: 18,
                  color: Colors.white70,
                ),
                onPressed: widget.buffer.clear,
              ),
            ],
          ),
          const SizedBox(height: AppTheme.spacing8),
          Expanded(
            child: ListenableBuilder(
              listenable: widget.buffer,
              builder: (BuildContext context, Widget? _) {
                final lines = widget.buffer.lines;
                if (lines.isEmpty) {
                  return const Center(
                    child: Text(
                      'Здесь появятся SSH-команды и ответы сервера...',
                      style: TextStyle(
                        color: AppTheme.textMuted,
                        fontFamily: 'monospace',
                      ),
                    ),
                  );
                }
                return ListView.builder(
                  controller: _scroll,
                  itemCount: lines.length,
                  itemBuilder: (BuildContext context, int index) {
                    final line = lines[index];
                    return SelectableText(
                      line.kind == TerminalLineKind.command
                          ? '\$ ${line.text}'
                          : line.text,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12.5,
                        height: 1.35,
                        color: _colorFor(line.kind),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
