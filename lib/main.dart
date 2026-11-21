import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'theme/app_theme.dart';
import 'screens/diagnostics_screen.dart';
import 'screens/home_screen.dart';
import 'screens/server_management_screen.dart';

/// true на Windows/Linux/macOS: там своё окно без рамки и кнопки окна.
/// На Android/iOS window_manager не работает и не вызывается.
final bool isDesktop =
    !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

/// Ширина, ниже которой включается телефонная вёрстка.
const double kPhoneBreakpoint = 760;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (!isDesktop) {
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: AppTheme.surface2,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
    );
    runApp(const MegaBoxApp());
    return;
  }

  // Configure window
  await windowManager.ensureInitialized();

  const windowOptions = WindowOptions(
    size: Size(1280, 860),
    minimumSize: Size(1040, 720),
    center: true,
    backgroundColor: Colors.transparent,
    skipTaskbar: false,
    titleBarStyle: TitleBarStyle.hidden,
    windowButtonVisibility: false,
  );

  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });

  runApp(const MegaBoxApp());
}

class MegaBoxApp extends StatelessWidget {
  const MegaBoxApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MegaBox Server Creator',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: const AppShell(),
    );
  }
}

/// Корневой экран: боковое меню слева, своя шапка окна сверху,
/// содержимое вкладок справа (состояние вкладок сохраняется).
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _NavItem {
  const _NavItem(this.icon, this.activeIcon, this.label, this.subtitle);
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final String subtitle;
}

class _AppShellState extends State<AppShell> with WindowListener {
  int _tabIndex = 0;
  bool _maximized = false;

  static const _items = <_NavItem>[
    _NavItem(Icons.rocket_launch_outlined, Icons.rocket_launch, 'Развёртывание',
        'Новый сервер за пару минут'),
    _NavItem(Icons.dns_outlined, Icons.dns, 'Мои серверы',
        'Мониторинг и управление'),
    _NavItem(Icons.health_and_safety_outlined, Icons.health_and_safety,
        'Проверка', 'Диагностика сервера'),
  ];

  @override
  void initState() {
    super.initState();
    if (isDesktop) windowManager.addListener(this);
  }

  @override
  void dispose() {
    if (isDesktop) windowManager.removeListener(this);
    super.dispose();
  }

  static const _pages = <Widget>[
    HomeScreen(),
    ServerManagementScreen(),
    DiagnosticsScreen(),
  ];

  /// Телефон: шапка сверху, нижнее меню, без кнопок окна.
  Widget _buildPhone() {
    final item = _items[_tabIndex];
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: <Widget>[
            Container(
              height: 52,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: AppTheme.surface4)),
              ),
              child: Row(
                children: <Widget>[
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      gradient: AppTheme.brandGradient,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: const Icon(Icons.bolt, color: Colors.white, size: 18),
                  ),
                  const SizedBox(width: 10),
                  ShaderMask(
                    shaderCallback: (r) => AppTheme.brandGradient.createShader(r),
                    child: const Text(
                      'MegaBox',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      item.subtitle,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: IndexedStack(index: _tabIndex, children: _pages),
            ),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        backgroundColor: AppTheme.surface2,
        indicatorColor: AppTheme.accentPrimary.withValues(alpha: 0.18),
        selectedIndex: _tabIndex,
        onDestinationSelected: (i) => setState(() => _tabIndex = i),
        destinations: <NavigationDestination>[
          for (final it in _items)
            NavigationDestination(
              icon: Icon(it.icon),
              selectedIcon: Icon(it.activeIcon, color: AppTheme.accentPrimary),
              label: it.label,
            ),
        ],
      ),
    );
  }

  @override
  void onWindowClose() async {
    await windowManager.destroy();
  }

  @override
  void onWindowMaximize() => setState(() => _maximized = true);

  @override
  void onWindowUnmaximize() => setState(() => _maximized = false);

  Future<void> _toggleMaximize() async {
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.sizeOf(context).width < kPhoneBreakpoint) {
      return _buildPhone();
    }
    return Scaffold(
      body: Stack(
        children: <Widget>[
          // Мягкое свечение фона.
          Positioned(
            top: -220,
            right: -160,
            child: IgnorePointer(
              child: Container(
                width: 620,
                height: 620,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: <Color>[
                      AppTheme.accentViolet.withValues(alpha: 0.10),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          ),
          Row(
            children: <Widget>[
              LayoutBuilder(
                builder: (context, _) => _buildSidebar(
                  compact: MediaQuery.sizeOf(context).width < 1400,
                ),
              ),
              Expanded(
                child: Column(
                  children: <Widget>[
                    _buildTitleBar(),
                    Expanded(
                      child: IndexedStack(
                        index: _tabIndex,
                        children: _pages,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSidebar({required bool compact}) {
    if (compact) return _buildCompactSidebar();
    return Container(
      width: 236,
      decoration: const BoxDecoration(
        color: AppTheme.surface2,
        border: Border(right: BorderSide(color: AppTheme.surface4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          GestureDetector(
            behavior: HitTestBehavior.translucent,
            onPanStart: isDesktop ? (_) => windowManager.startDragging() : null,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 20, 18, 24),
              child: Row(
                children: <Widget>[
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      gradient: AppTheme.brandGradient,
                      borderRadius: BorderRadius.circular(11),
                      boxShadow: <BoxShadow>[
                        BoxShadow(
                          color: AppTheme.accentPrimary.withValues(alpha: 0.35),
                          blurRadius: 16,
                        ),
                      ],
                    ),
                    child: const Icon(Icons.bolt, color: Colors.white, size: 22),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      ShaderMask(
                        shaderCallback: (r) => AppTheme.brandGradient.createShader(r),
                        child: const Text(
                          'MegaBox',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                            letterSpacing: -0.3,
                          ),
                        ),
                      ),
                      const Text(
                        'Server Creator',
                        style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              'МЕНЮ',
              style: TextStyle(
                fontSize: 10,
                letterSpacing: 1.2,
                color: AppTheme.textMuted,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          for (var i = 0; i < _items.length; i++) _buildNavTile(i),
          const Spacer(),
          Container(
            margin: const EdgeInsets.all(14),
            padding: const EdgeInsets.all(14),
            decoration: AppTheme.glassCard(radius: AppTheme.radiusMedium),
            child: const Row(
              children: <Widget>[
                Icon(Icons.shield_outlined, size: 18, color: AppTheme.success),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'VLESS · Reality\nКлюч SSH проверяется',
                    style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.only(left: 20, bottom: 14),
            child: Text('v1.2.0', style: TextStyle(fontSize: 10, color: AppTheme.textMuted)),
          ),
        ],
      ),
    );
  }

  /// Узкое меню (только иконки) для окон уже 1400 px,
  /// чтобы форме развёртывания хватало места.
  Widget _buildCompactSidebar() {
    return Container(
      width: 96,
      decoration: const BoxDecoration(
        color: AppTheme.surface2,
        border: Border(right: BorderSide(color: AppTheme.surface4)),
      ),
      child: Column(
        children: <Widget>[
          const SizedBox(height: 18),
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              gradient: AppTheme.brandGradient,
              borderRadius: BorderRadius.circular(11),
            ),
            child: const Icon(Icons.bolt, color: Colors.white, size: 22),
          ),
          const SizedBox(height: 22),
          for (var i = 0; i < _items.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Tooltip(
                message: _items[i].label,
                child: InkWell(
                  borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
                  onTap: () => setState(() => _tabIndex = i),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: 80,
                    height: 60,
                    decoration: BoxDecoration(
                      color: _tabIndex == i
                          ? AppTheme.accentPrimary.withValues(alpha: 0.16)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
                      border: Border.all(
                        color: _tabIndex == i
                            ? AppTheme.accentPrimary.withValues(alpha: 0.4)
                            : Colors.transparent,
                      ),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        Icon(
                          _tabIndex == i ? _items[i].activeIcon : _items[i].icon,
                          size: 20,
                          color: _tabIndex == i
                              ? AppTheme.accentPrimary
                              : AppTheme.textSecondary,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _items[i].label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10,
                            color: _tabIndex == i
                                ? AppTheme.textPrimary
                                : AppTheme.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildNavTile(int index) {
    final item = _items[index];
    final active = _tabIndex == index;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
          onTap: () => setState(() => _tabIndex = index),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            decoration: BoxDecoration(
              gradient: active
                  ? LinearGradient(colors: <Color>[
                      AppTheme.accentPrimary.withValues(alpha: 0.18),
                      AppTheme.accentViolet.withValues(alpha: 0.06),
                    ])
                  : null,
              borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
              border: Border.all(
                color: active
                    ? AppTheme.accentPrimary.withValues(alpha: 0.35)
                    : Colors.transparent,
              ),
            ),
            child: Row(
              children: <Widget>[
                AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  width: 3,
                  height: 26,
                  decoration: BoxDecoration(
                    color: active ? AppTheme.accentPrimary : Colors.transparent,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 10),
                Icon(
                  active ? item.activeIcon : item.icon,
                  size: 20,
                  color: active ? AppTheme.accentPrimary : AppTheme.textSecondary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        item.label,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                          color: active ? AppTheme.textPrimary : AppTheme.textSecondary,
                        ),
                      ),
                      Text(
                        item.subtitle,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 10, color: AppTheme.textMuted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTitleBar() {
    final item = _items[_tabIndex];
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: isDesktop ? (_) => windowManager.startDragging() : null,
      onDoubleTap: isDesktop ? _toggleMaximize : null,
      child: Container(
        height: 46,
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: AppTheme.surface4)),
        ),
        child: Row(
          children: <Widget>[
            const SizedBox(width: 20),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: Text(
                item.subtitle,
                key: ValueKey<int>(_tabIndex),
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ),
            const Spacer(),
            if (isDesktop) ...<Widget>[
              _WindowButton(icon: Icons.remove, onTap: windowManager.minimize),
              _WindowButton(
                icon: _maximized ? Icons.filter_none : Icons.crop_square,
                iconSize: _maximized ? 14 : 16,
                onTap: _toggleMaximize,
              ),
              _WindowButton(
                icon: Icons.close,
                onTap: windowManager.close,
                hoverColor: const Color(0xFFE81123),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _WindowButton extends StatefulWidget {
  const _WindowButton({
    required this.icon,
    required this.onTap,
    this.hoverColor,
    this.iconSize = 16,
  });

  final IconData icon;
  final Future<void> Function() onTap;
  final Color? hoverColor;
  final double iconSize;

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 46,
          height: 46,
          color: _hover
              ? (widget.hoverColor ?? AppTheme.surface4)
              : Colors.transparent,
          child: Icon(
            widget.icon,
            size: widget.iconSize,
            color: _hover && widget.hoverColor != null
                ? Colors.white
                : AppTheme.textSecondary,
          ),
        ),
      ),
    );
  }
}
