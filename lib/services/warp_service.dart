import 'shell_scripts.dart';

/// Uses the supported desktop client, not undocumented registration endpoints.
class WarpService {
  static const failureWarning =
      '⚠️ Не удалось установить/настроить WARP, продолжаем с прямой маршрутизацией без WARP';
  static const proxyPort = 40000;
  static final installScript =
      r'''
set -e
set -o pipefail
export DEBIAN_FRONTEND=noninteractive
if ! command -v warp-cli >/dev/null 2>&1; then
''' +
      ShellScripts.aptUnlock +
      r'''
  # Remove stale sources before updating or installing prerequisites.
  rm -f /etc/apt/sources.list.d/cloudflare*.list
  apt-get -o DPkg::Lock::Timeout=120 update
  apt-get -o DPkg::Lock::Timeout=120 -y install curl gnupg ca-certificates
  mkdir -p /usr/share/keyrings
  curl -fsSL --connect-timeout 15 --max-time 60 https://pkg.cloudflareclient.com/pubkey.gpg |
    gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
  chmod 644 /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
  . /etc/os-release
  mbx_warp_installed=0
  mbx_warp_tried=' '
  for mbx_codename in "${VERSION_CODENAME:-}" jammy bookworm; do
    [ -n "$mbx_codename" ] || continue
    case "$mbx_warp_tried" in *" $mbx_codename "*) continue ;; esac
    mbx_warp_tried="$mbx_warp_tried$mbx_codename "
    printf 'deb [arch=%s signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ %s main\n' "$(dpkg --print-architecture)" "$mbx_codename" > /etc/apt/sources.list.d/cloudflare-client.list
    # Both operations must succeed; set -e must not stop the fallback loop.
    if apt-get -o DPkg::Lock::Timeout=120 update &&
       apt-get -o DPkg::Lock::Timeout=120 -y install cloudflare-warp; then
      mbx_warp_installed=1
      break
    fi
    echo "WARP repository $mbx_codename failed; trying fallback" >&2
  done
  if [ "$mbx_warp_installed" -ne 1 ]; then
    rm -f /etc/apt/sources.list.d/cloudflare-client.list
    echo 'Unable to install Cloudflare WARP from supported repositories' >&2
    exit 1
  fi
fi
systemctl enable --now warp-svc
if ! warp-cli --accept-tos registration show >/dev/null 2>&1; then
  warp-cli --accept-tos registration new
fi
warp-cli --accept-tos mode proxy
warp-cli --accept-tos proxy port 40000
warp-cli --accept-tos connect
for i in $(seq 1 15); do
  if curl -fsS --max-time 5 --proxy socks5h://127.0.0.1:40000 https://www.cloudflare.com/cdn-cgi/trace | grep -q '^warp=on$'; then
    echo MBX_WARP_READY
    exit 0
  fi
  sleep 2
done
echo 'WARP local proxy is not ready' >&2
exit 1
''';

  static Map<String, dynamic> outbound() => {
    'tag': 'warp',
    'protocol': 'socks',
    'settings': {
      'servers': [
        {'address': '127.0.0.1', 'port': proxyPort},
      ],
    },
  };

  static Future<void> configure({
    required String sshPassword,
    required bool isRoot,
    required Future<String> Function(String, String, bool) runCommand,
  }) async {
    final output = await runCommand(installScript, sshPassword, isRoot);
    if (!output.split('\n').any((line) => line.trim() == 'MBX_WARP_READY')) {
      throw StateError('Cloudflare WARP local proxy did not become ready');
    }
  }

  static String telegramSql(String token, String chatId) {
    final values = {
      'tgBotToken': token,
      'tgBotChatId': chatId,
      'tgBotEnable': 'true',
      'tgBotBackup': 'true',
      'tgBotRunTime': '00:00',
      'tgBotBackupCron': '0 0 3 * *',
    };
    String sqlQuote(String value) => "'${value.replaceAll("'", "''")}'";
    return ShellScripts.sql(
      'BEGIN IMMEDIATE;\n${values.entries.map((e) => 'INSERT OR REPLACE INTO settings (key, value) VALUES (${sqlQuote(e.key)}, ${sqlQuote(e.value)});').join('\n')}\nCOMMIT;',
    );
  }
}
