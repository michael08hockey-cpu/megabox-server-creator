import 'package:megabox_server_creator/models/deployment_result.dart';

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:megabox_server_creator/services/ssh_service.dart';
import 'package:megabox_server_creator/services/shell_scripts.dart';

import 'server_history_test.dart' show savedServer;

DeploymentResult makeResult(
  DeploymentResult base,
  List<int> listening,
  Map<int, bool> reachable,
) => DeploymentResult(
  vlessLink: base.vlessLink,
  backupVlessLink: base.backupVlessLink,
  panelUrl: base.panelUrl,
  panelUsername: base.panelUsername,
  panelPassword: base.panelPassword,
  locationFlag: base.locationFlag,
  locationName: base.locationName,
  selectedSni: base.selectedSni,
  sniPing: 0,
  trafficVerified: false,
  httpCode: 0,
  portReachable: reachable[443] ?? false,
  serverListeningPorts: listening,
  portReachability: reachable,
);

void main() {
  test('TCP immediate success does not sleep or retry', () async {
    var calls = 0;
    final reachable = await SSHService.probeTcpPort(
      '192.0.2.1',
      443,
      connect: (host, port, timeout) async {
        calls++;
        expect(host, '192.0.2.1');
        expect(port, 443);
        expect(timeout, const Duration(seconds: 5));
      },
      delay: (_) async => fail('unexpected delay'),
    );
    expect(reachable, isTrue);
    expect(calls, 1);
  });

  test('third attempt succeeds after two 2-second pauses', () async {
    var calls = 0;
    final pauses = <Duration>[];
    final reachable = await SSHService.probeTcpPort(
      '192.0.2.1',
      8443,
      connect: (_, _, timeout) async {
        expect(timeout, const Duration(seconds: 5));
        if (++calls < 3) throw const SocketException('starting');
      },
      delay: (duration) async => pauses.add(duration),
    );
    expect(reachable, isTrue);
    expect(calls, 3);
    expect(pauses, [const Duration(seconds: 2), const Duration(seconds: 2)]);
  });

  test('both ports have independent retries and bounded failure', () async {
    final counts = <int, int>{};
    final result = await SSHService.probeTcpPorts(
      '192.0.2.1',
      [443, 8443],
      connect: (_, port, _) async {
        counts[port] = (counts[port] ?? 0) + 1;
        if (port == 8443) throw const SocketException('provider firewall');
      },
      delay: (_) async {},
    );
    expect(result, {443: true, 8443: false});
    expect(counts, {443: 1, 8443: 3});
  });

  test('real local TCP socket is closed after successful probe', () async {
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = listener.listen((socket) => socket.destroy());
    try {
      expect(await SSHService.probeTcpPort('127.0.0.1', listener.port), isTrue);
    } finally {
      await subscription.cancel();
      await listener.close();
    }
  });

  test(
    'server wait checks Xray ownership and exact ports for ten attempts',
    () {
      final script = ShellScripts.waitForXrayPorts([443, 8443]);
      expect(script, contains('ss -tlnpH'));
      expect(script, contains('for mbx_port in 443 8443; do'));
      expect(script, contains(r'while [ "$mbx_xray_attempt" -le 10 ]'));
      expect(script, contains(r'$4 ~ (":" port "$")'));
      expect(script, contains('xray'));
      expect(script, contains('sleep 1'));
      expect(script, contains(r'MBX_XRAY_LISTENING:$mbx_port'));
      expect(() => ShellScripts.waitForXrayPorts([]), throwsArgumentError);
      expect(() => ShellScripts.waitForXrayPorts([0]), throwsArgumentError);
      expect(
        ShellScripts.waitForXrayPorts([2053]),
        isNot(contains('443 8443')),
      );
    },
  );

  test('listener markers ignore spoofed substrings and unrelated ports', () {
    expect(
      SSHService.parseXrayListeningPorts(
        'MBX_XRAY_LISTENING:8443\r\nMBX_XRAY_LISTENING:443\n'
        'MBX_XRAY_LISTENING:443\nMBX_XRAY_LISTENING:80\n'
        'not MBX_XRAY_LISTENING:443\n',
        [443, 8443],
      ),
      [443, 8443],
    );
  });

  test(
    'ready VPS with failed PC TCP is calm, not falsely traffic-verified',
    () {
      final base = savedServer().toDeploymentResult();
      final result = makeResult(base, [443, 8443], {443: false, 8443: false});
      expect(result.serverReady, isTrue);
      expect(result.readinessBadge, startsWith('Сервер готов'));
      expect(result.trafficVerified, isFalse);
      expect(result.httpCode, 0);
      expect(result.readinessBadge, isNot(contains('Трафик не подтверждён')));
      expect(
        makeResult(base, [443], {443: true, 8443: false}).serverReady,
        isFalse,
      );
    },
  );
}
