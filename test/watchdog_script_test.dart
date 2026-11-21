import 'package:flutter_test/flutter_test.dart';

/// Проверка экранирования heredoc-скрипта watchdog:
/// переменные bash должны доходить до сервера как `$VAR`,
/// а значения из Dart — подставляться напрямую.
void main() {
  test('watchdog heredoc escaping produces valid bash', () {
    const botToken = 'TOKEN123';
    const chatId = 'CHAT456';
    const serverIp = '1.2.3.4';

    final watchdogScript =
        '''#!/bin/bash
BOT_TOKEN="$botToken"
CHAT_ID="$chatId"
SERVER_IP="$serverIp"
LOCK=/var/run/mbx-watchdog.lock

send_telegram() {
    curl -s -m 10 -X POST "https://api.telegram.org/bot\${BOT_TOKEN}/sendMessage" \\
         -d chat_id="\${CHAT_ID}" \\
         -d text="\$1" \\
         -d parse_mode="HTML" >/dev/null 2>&1
}

if [ -e "\$LOCK" ]; then
    exit 0
fi
touch "\$LOCK"
trap 'rm -f "\$LOCK"' EXIT

if [ "\$NEED_RESTART" -eq 0 ]; then
    exit 0
fi
send_telegram "Server \$SERVER_IP down"
if [ "\$OK" -eq 1 ]; then
    exit 0
fi
''';

    // Главная проверка: ни одного пере-экранированного `\$` в результате.
    expect(watchdogScript.contains(r'\$'), isFalse);

    // Переменные bash сохранились.
    expect(watchdogScript, contains(r'${BOT_TOKEN}'));
    expect(watchdogScript, contains(r'${CHAT_ID}'));
    expect(watchdogScript, contains(r'-d text="$1"'));
    expect(watchdogScript, contains(r'if [ -e "$LOCK" ]; then'));
    expect(watchdogScript, contains(r'touch "$LOCK"'));
    expect(watchdogScript, contains(r'if [ "$NEED_RESTART" -eq 0 ]; then'));
    expect(watchdogScript, contains(r'Server $SERVER_IP down'));
    expect(watchdogScript, contains(r'if [ "$OK" -eq 1 ]; then'));

    // Значения из Dart подставлены.
    expect(watchdogScript, contains('BOT_TOKEN="TOKEN123"'));
    expect(watchdogScript, contains('CHAT_ID="CHAT456"'));
    expect(watchdogScript, contains('SERVER_IP="1.2.3.4"'));

    // Продолжение строки curl осталось одиночным обратным слэшем.
    expect(watchdogScript, contains('sendMessage" \\\n'));
  });
}
