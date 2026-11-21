import 'package:flutter_test/flutter_test.dart';
import 'package:megabox_server_creator/services/diagnostics_service.dart';

DiagCheck byId(List<DiagCheck> checks, String id) =>
    checks.firstWhere((c) => c.id == id);

const healthy = '''
os_id=ubuntu
os_ver=24.04
os_name=Ubuntu 24.04.1 LTS
arch=x86_64
kernel=6.8.0
virt=kvm
cpus=2
ram_mb=1980
swap_mb=0
disk_free_mb=20480
load=0.05
uid=0
epoch=1700000000
ntp=yes
pkg=apt
port_busy=0
xui=none
xui_active=inactive
dns=ok
net_github=200
net_raw=301
geo_ip=192.0.2.10
geo_country=US
geo_org=AS210644 AEZA GROUP
apt_busy=0
firewall=none
bbr=cubic
ipv6=1
MBX_DIAG_DONE
''';

void main() {
  final deviceTime = DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000);

  group('parsePreflight', () {
    test('healthy Ubuntu server has no warnings or failures', () {
      final checks = ServerDiagnostics.parsePreflight(
        healthy,
        vlessPort: 443,
        deviceTime: deviceTime,
      );
      final report = DiagReport(checks);
      expect(report.hasFail, isFalse);
      expect(report.hasWarn, isFalse);
      expect(report.overall, DiagStatus.ok);
      expect(byId(checks, 'geo').detail, contains('AEZA'));
      expect(byId(checks, 'bbr').detail, contains('будет включён BBR'));
    });

    test('tiny RAM, full disk and no GitHub are failures', () {
      final out = healthy
          .replaceFirst('ram_mb=1980', 'ram_mb=256')
          .replaceFirst('disk_free_mb=20480', 'disk_free_mb=600')
          .replaceFirst('net_github=200', 'net_github=000');
      final checks = ServerDiagnostics.parsePreflight(
        out,
        vlessPort: 443,
        deviceTime: deviceTime,
      );
      expect(byId(checks, 'ram').status, DiagStatus.fail);
      expect(byId(checks, 'disk').status, DiagStatus.fail);
      expect(byId(checks, 'net').status, DiagStatus.fail);
      expect(DiagReport(checks).problems.length, 3);
    });

    test('small RAM without swap is only a warning', () {
      final out = healthy.replaceFirst('ram_mb=1980', 'ram_mb=700');
      final checks = ServerDiagnostics.parsePreflight(
        out,
        vlessPort: 443,
        deviceTime: deviceTime,
      );
      expect(byId(checks, 'ram').status, DiagStatus.warn);
    });

    test('port taken by nginx warns, taken by xray is info', () {
      final nginx = healthy.replaceFirst(
        'port_busy=0',
        'port_busy=1\nport_proc=nginx',
      );
      final xray = healthy.replaceFirst(
        'port_busy=0',
        'port_busy=1\nport_proc=xray-linux-amd64',
      );
      expect(
        byId(ServerDiagnostics.parsePreflight(nginx, vlessPort: 443), 'port').status,
        DiagStatus.warn,
      );
      expect(
        byId(ServerDiagnostics.parsePreflight(xray, vlessPort: 443), 'port').status,
        DiagStatus.info,
      );
    });

    test('clock skew over 90 seconds warns', () {
      final checks = ServerDiagnostics.parsePreflight(
        healthy,
        vlessPort: 443,
        deviceTime: deviceTime.add(const Duration(minutes: 5)),
      );
      expect(byId(checks, 'time').status, DiagStatus.warn);
      expect(byId(checks, 'time').detail, contains('300'));
    });

    test('containers, odd CPU, old OS and missing sudo are flagged', () {
      final out = healthy
          .replaceFirst('virt=kvm', 'virt=openvz')
          .replaceFirst('arch=x86_64', 'arch=mips')
          .replaceFirst('os_ver=24.04', 'os_ver=18.04');
      final checks = ServerDiagnostics.parsePreflight(
        out,
        vlessPort: 443,
        sudoOk: false,
      );
      expect(byId(checks, 'virt').status, DiagStatus.warn);
      expect(byId(checks, 'arch').status, DiagStatus.fail);
      expect(byId(checks, 'os').status, DiagStatus.warn);
      expect(byId(checks, 'root').status, DiagStatus.fail);
    });

    test('existing 3X-UI and firewalld are reported', () {
      final out = healthy
          .replaceFirst('xui=none', 'xui=installed')
          .replaceFirst('xui_active=inactive', 'xui_active=active')
          .replaceFirst('firewall=none', 'firewall=firewalld');
      final checks = ServerDiagnostics.parsePreflight(out, vlessPort: 8443);
      expect(byId(checks, 'xui').status, DiagStatus.info);
      expect(byId(checks, 'xui').detail, contains('работает'));
      expect(byId(checks, 'firewall').status, DiagStatus.warn);
      expect(byId(checks, 'firewall').hint, contains('8443'));
    });

    test('truncated output is flagged and does not crash', () {
      final checks = ServerDiagnostics.parsePreflight(
        'os_id=ubuntu\nos_ver=22.04\n',
        vlessPort: 443,
      );
      expect(byId(checks, 'script').status, DiagStatus.warn);
    });

    test('script embeds only a numeric port', () {
      final script = ServerDiagnostics.preflightScript(2053);
      expect(script, contains('MBX_PORT=2053'));
      expect(script, contains('MBX_DIAG_DONE'));
      expect(() => ServerDiagnostics.preflightScript(0), throwsArgumentError);
      expect(() => ServerDiagnostics.preflightScript(70000), throwsArgumentError);
    });
  });

  group('reachability', () {
    const t = Duration(seconds: 5);

    test('socket errors are classified per platform', () {
      expect(
        ServerDiagnostics.classifySocketError(111, 'Connection refused',
                elapsed: const Duration(milliseconds: 40), timeout: t)
            .state,
        PortState.refused,
      );
      expect(
        ServerDiagnostics.classifySocketError(10061, 'Подключение не установлено',
                elapsed: const Duration(milliseconds: 40), timeout: t)
            .state,
        PortState.refused,
      );
      expect(
        ServerDiagnostics.classifySocketError(null, 'Connection timed out',
                elapsed: t, timeout: t)
            .state,
        PortState.timeout,
      );
      expect(
        ServerDiagnostics.classifySocketError(10060, 'x',
                elapsed: const Duration(seconds: 1), timeout: t)
            .state,
        PortState.timeout,
      );
      expect(
        ServerDiagnostics.classifySocketError(101, 'Network is unreachable',
                elapsed: const Duration(milliseconds: 5), timeout: t)
            .state,
        PortState.unreachable,
      );
    });

    test('silent SSH port means likely blocked IP and skips VLESS check', () {
      final checks = ServerDiagnostics.reachabilityChecks(
        ssh: const PortProbe(PortState.timeout),
        vless: const PortProbe(PortState.timeout),
        sshPort: 22,
        vlessPort: 443,
      );
      expect(checks.length, 1);
      expect(checks.single.status, DiagStatus.fail);
      expect(checks.single.hint, contains('заблокирован'));
    });

    test('refused VLESS port before install is fine, silent one warns', () {
      final ok = ServerDiagnostics.reachabilityChecks(
        ssh: const PortProbe(PortState.open, ms: 40),
        vless: const PortProbe(PortState.refused, ms: 40),
        sshPort: 22,
        vlessPort: 443,
      );
      expect(DiagReport(ok).overall, DiagStatus.ok);
      final silent = ServerDiagnostics.reachabilityChecks(
        ssh: const PortProbe(PortState.open, ms: 40),
        vless: const PortProbe(PortState.timeout),
        sshPort: 22,
        vlessPort: 443,
      );
      expect(byId(silent, 'reach_vless').status, DiagStatus.warn);
    });
  });

  group('run', () {
    test('stops after an unreachable SSH port without connecting', () async {
      var connected = false;
      final diag = ServerDiagnostics(
        probe: (h, p) async => const PortProbe(PortState.timeout),
        connect: (h, p, u, pw) async {
          connected = true;
          throw StateError('must not connect');
        },
      );
      final stages = <String>[];
      final report = await diag.run(
        host: '1.2.3.4',
        sshPort: 22,
        user: 'root',
        password: 'x',
        vlessPort: 443,
        onProgress: stages.add,
      );
      expect(connected, isFalse);
      expect(report.hasFail, isTrue);
      expect(stages, isNotEmpty);
    });
  });
}
