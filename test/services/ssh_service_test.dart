import 'package:flutter_test/flutter_test.dart';
import 'package:megabox_server_creator/services/ssh_service.dart';

void main() {
  group('SSHService', () {
    late SSHService sshService;

    setUp(() {
      sshService = SSHService();
    });

    tearDown(() {
      sshService.dispose();
    });

    test('shellQuote handles single quotes correctly', () {
      // Test the static shellQuote method for shell injection prevention
      final input = "O'Brien";
      final quoted = SSHService.shellQuote(input);
      // Should escape the single quote as '\'
      expect(quoted.contains("'\\''"), true);
      expect(quoted, equals("'O'\\''Brien'"));
    });

    test('shellQuote escapes multiple single quotes', () {
      final input = "It's O'Brien's";
      final quoted = SSHService.shellQuote(input);
      expect(quoted.contains("'\\''"), true);
      // Should have multiple escapes
      expect(quoted.split("'\\''").length, greaterThan(1));
    });

    test('shellQuote handles strings without quotes', () {
      final input = 'normalpassword123';
      final quoted = SSHService.shellQuote(input);
      expect(quoted, equals("'normalpassword123'"));
    });

    test('logStream is a broadcast stream', () {
      expect(sshService.logStream.isBroadcast, true);
    });

    test('terminalStream is a broadcast stream', () {
      expect(sshService.terminalStream.isBroadcast, true);
    });

    test('dispose closes controllers', () async {
      sshService.dispose();
      // Adding to closed stream should not throw
      expect(() {
        sshService.logStream.listen((_) {});
      }, returnsNormally);
    });
  });
}
