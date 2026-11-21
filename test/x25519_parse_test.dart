import 'package:flutter_test/flutter_test.dart';
import 'package:megabox_server_creator/services/ssh_service.dart';

/// Проверка разбора вывода `xray x25519` в разных версиях Xray-core.
void main() {
  group('parseX25519Output', () {
    test('старый формат: Private key / Public key', () {
      const output = '''
Private key: aGVsbG8td29ybGQtcHJpdmF0ZS1rZXktZXhhbXBsZTEyMw
Public key: aGVsbG8td29ybGQtcHVibGljLWtleS1leGFtcGxlNDU2Nzg
''';

      final parsed = SSHService.parseX25519Output(output);

      expect(parsed, isNotNull);
      expect(
        parsed!['privateKey'],
        'aGVsbG8td29ybGQtcHJpdmF0ZS1rZXktZXhhbXBsZTEyMw',
      );
      expect(
        parsed['publicKey'],
        'aGVsbG8td29ybGQtcHVibGljLWtleS1leGFtcGxlNDU2Nzg',
      );
    });

    test('новый формат: PrivateKey / Password / Hash32', () {
      const output = '''
PrivateKey: UBR3GLhlwLjsiF8MsdC2K1nGBM7B_9kt0E0ZfzJ1VEI
Password: 7mFvQ2nVZ8kXoP1tYrLsWqAeDhGjMnBvCxZkNpQwRtY
Hash32: 9xKpLmNvBcXzAsDfGhJkQwErTyUiOpAsDfGhJkLzXcVb
''';

      final parsed = SSHService.parseX25519Output(output);

      expect(parsed, isNotNull);
      expect(
        parsed!['privateKey'],
        'UBR3GLhlwLjsiF8MsdC2K1nGBM7B_9kt0E0ZfzJ1VEI',
      );
      expect(
        parsed['publicKey'],
        '7mFvQ2nVZ8kXoP1tYrLsWqAeDhGjMnBvCxZkNpQwRtY',
      );
      // Hash32 не должен попасть в публичный ключ.
      expect(parsed['publicKey'], isNot(contains('9xKpLm')));
    });

    test('формат из исходников Xray: Password (PublicKey)', () {
      // См. curve25519.go: fmt.Printf("PrivateKey: %v\nPassword (PublicKey): %v\nHash32: %v\n", ...)
      const output = '''
PrivateKey: UBR3GLhlwLjsiF8MsdC2K1nGBM7B_9kt0E0ZfzJ1VEI
Password (PublicKey): 7mFvQ2nVZ8kXoP1tYrLsWqAeDhGjMnBvCxZkNpQwRtY
Hash32: 9xKpLmNvBcXzAsDfGhJkQwErTyUiOpAsDfGhJkLzXcVb
''';

      final parsed = SSHService.parseX25519Output(output);

      expect(parsed, isNotNull);
      expect(
        parsed!['privateKey'],
        'UBR3GLhlwLjsiF8MsdC2K1nGBM7B_9kt0E0ZfzJ1VEI',
      );
      expect(
        parsed['publicKey'],
        '7mFvQ2nVZ8kXoP1tYrLsWqAeDhGjMnBvCxZkNpQwRtY',
      );
    });

    test('base64url с дефисами и подчёркиваниями сохраняется целиком', () {
      const output = '''
PrivateKey: aB-cD_eF1gH2iJ3kL4mN5oP6qR7sT8uV9wX0yZ1aB2c
Password: zY-xW_vU1tS2rQ3pO4nM5lK6jI7hG8fE9dC0bA1zY2x
''';

      final parsed = SSHService.parseX25519Output(output);

      expect(
        parsed!['privateKey'],
        'aB-cD_eF1gH2iJ3kL4mN5oP6qR7sT8uV9wX0yZ1aB2c',
      );
      expect(
        parsed['publicKey'],
        'zY-xW_vU1tS2rQ3pO4nM5lK6jI7hG8fE9dC0bA1zY2x',
      );
    });

    test('регистр метки не важен', () {
      const output = '''
privatekey: aGVsbG8td29ybGQtcHJpdmF0ZS1rZXktZXhhbXBsZTEyMw
PASSWORD: aGVsbG8td29ybGQtcHVibGljLWtleS1leGFtcGxlNDU2Nzg
''';

      expect(SSHService.parseX25519Output(output), isNotNull);
    });

    test('нераспознанный вывод даёт null', () {
      const output = 'command not found: xray';
      expect(SSHService.parseX25519Output(output), isNull);
    });

    test('пустой вывод даёт null', () {
      expect(SSHService.parseX25519Output(''), isNull);
    });

    test('только приватный ключ без публичного даёт null', () {
      const output = 'PrivateKey: UBR3GLhlwLjsiF8MsdC2K1nGBM7B_9kt0E0ZfzJ1VEI';
      expect(SSHService.parseX25519Output(output), isNull);
    });
  });
}
