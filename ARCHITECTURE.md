# 📦 Архитектура MegaBox Server Creator v2.0

## Модульная структура (3 сервиса)

```
lib/services/
├── ssh_service.dart         # SSH + установка 3X-UI (603 строки)
├── xui_routing_helper.dart  # Правила маршрутизации Xray (220 строк)
└── doctor_service.dart      # Диагностика и авто-починка (383 строки)
```

---

## 1. ssh_service.dart — Развертывание сервера

### Ключевые функции:
- `deployServer(ServerConfig)` — главная функция развертывания
- `removeXuiFromServer(ServerConfig)` — удаление панели
- `checkServerTraffic(String, int)` — проверка порта

### Поддержка sudo (не-root):
```dart
// root: прямое выполнение
final result = await _client!.run(command);

// sudo: через временный скрипт
final scriptPath = '/tmp/mbx_cmd_${timestamp}.sh';
await _client!.run('cat > $scriptPath << \'EOFSCRIPT\'\n$command\nEOFSCRIPT');
await _client!.run('chmod +x $scriptPath');
final sudoCommand = "printf '%s\\n' '$password' | sudo -S -p '' bash $scriptPath 2>&1";
final result = await _client!.run(sudoCommand);
```

### Честная установка 3X-UI:
```dart
// Загружаем в /tmp
curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh -o /tmp/xui_install.sh

// Запускаем с автоответом "n" (новая установка)
printf "n\n" | bash /tmp/xui_install.sh
```

### Резервный Inbound (8443) + Ключи для друзей:
```dart
if (config.options.backupInbound) {
  await apiService.addVlessRealityInbound(port: 8443, ...);
}

for (final friendName in config.options.friendNames) {
  await apiService.addClientToInbound(
    uuid: _generateUuid(),
    email: friendName,
    limitIp: config.options.limitIp,
    totalGb: config.options.limitGb * 1073741824,
  );
}

subUrl = 'http://${ip}:2053/panel/sub/${_generateSubId()}';
```

---

## 2. xui_routing_helper.dart — Правила маршрутизации

### Правила:

**🇷🇺 Обход .RU** (по умолчанию включен):
```dart
if (options.bypassRuDomains) {
  rules.add({
    'type': 'field',
    'outboundTag': 'direct',
    'domain': ['domain:ru', 'domain:su', 'domain:xn--p1ai'],
  });
}
```

**🚫 Анти-Торрент**:
```dart
rules.add({'type': 'field', 'protocol': ['bittorrent'], 'outboundTag': 'blocked'});
```

**📛 AdBlock**:
```dart
rules.add({'type': 'field', 'domain': ['geosite:category-ads-all'], 'outboundTag': 'blocked'});
```

**☁️ WARP** (OpenAI, Claude, Netflix):
```dart
rules.add({
  'type': 'field',
  'domain': ['openai.com', 'claude.ai', 'netflix.com'],
  'outboundTag': 'warp',
});
```

### Применение через SQLite:
```dart
sqlite3 /etc/x-ui/x-ui.db "UPDATE settings SET value = '$routingJson' WHERE key = 'xrayTemplateConfig';"
systemctl restart x-ui
```

---

## 3. doctor_service.dart — Авто-Доктор

### Функции:
- `diagnoseAndFix(ServerConfig)` — диагностика + авто-починка
- `getServerStats(ServerConfig)` — CPU, RAM, Диск, Uptime
- `downloadBackup(ServerConfig, path)` — скачать x-ui.db
- `uploadBackup(ServerConfig, path)` — загрузить бэкап на новый сервер
- `createTestFailure(ServerConfig)` — тест сбоя (остановить x-ui)

### Алгоритм диагностики:

1. **Проверка SSH**:
```dart
// Если недоступен -> определяем тип сети
if (ip.startsWith('192.168.') || ip.startsWith('10.')) {
  return '❌ Сервер отключен от локальной сети (проверьте кабель)';
} else {
  return '❌ VPS недоступен (IP заблокирован или сервер выключен)';
}
```

2. **Проверка интернета на сервере**:
```dart
ping -c 1 -W 3 8.8.8.8
// Если нет ответа → проблема с внешним каналом провайдера
```

3. **Авто-починка службы**:
```dart
if (systemctl is-active x-ui != 'active') {
  systemctl restart x-ui
  return '🛠️ ИСПРАВЛЕНО: Служба 3X-UI перезапущена';
}
```

4. **Авто-починка портов**:
```dart
if (!portOpen) {
  ufw allow $port/tcp
  return '🛠️ ИСПРАВЛЕНО: Порт $port добавлен в ufw';
}
```

5. **Проверка SNI**:
```dart
for (final sni in candidates) {
  if (await _checkSniTls(sni)) return sni;
}
return '⚠️ Все SNI недоступны, смените домены';
```

---

## Модели данных

### DeploymentOptions (новые поля):
```dart
final bool cleanReinstall;       // Чистая переустановка
final bool antiTorrent;          // Блокировка торрентов
final bool adBlock;              // Блокировка рекламы
final bool backupInbound;        // Резервный Inbound 8443
final bool bypassRuDomains;      // Обход .RU (true по умолчанию)
final bool cloudflareWarp;       // Маршрутизация через WARP
final String? tgBotToken;        // Токен Telegram-бота
final String? tgBotChatId;       // Chat ID
final List<String> friendNames;  // Имена друзей для ключей
final int limitIp;               // Лимит IP
final int limitGb;               // Лимит GB
```

### DeploymentResult (новые поля):
```dart
final String vlessLink;                  // Основная ссылка
final String? backupVlessLink;           // Резервная ссылка (8443)
final Map<String, String> friendLinks;   // Ссылки друзей
final String? subUrl;                    // Subscription URL
```

---

## Примеры

### Развертывание с друзьями и обходом .RU:
```dart
final config = ServerConfig(
  ipAddress: '1.2.3.4',
  sshUser: 'admin',  // sudo-юзер
  sshPassword: 'pass',
  location: ServerLocation.germany,
  options: DeploymentOptions(
    bypassRuDomains: true,           // Обход .RU
    antiTorrent: true,
    backupInbound: true,             // Резервный Inbound
    friendNames: ['Alice', 'Bob'],   // Ключи для друзей
    limitIp: 2,
    limitGb: 50,
  ),
);

final result = await sshService.deployServer(config);
print('Ссылки: ${result.friendLinks}');
print('Sub URL: ${result.subUrl}');
```

### Диагностика:
```dart
final diagnostic = await doctorService.diagnoseAndFix(config);
for (final fix in diagnostic.fixedIssues) print('✅ $fix');
```

### Миграция:
```dart
await doctorService.downloadBackup(oldConfig, 'backup.db');
await sshService.deployServer(newConfig);
await doctorService.uploadBackup(newConfig, 'backup.db');
```

---

**Версия:** 2.0 | **Дата:** 2026-10-30
