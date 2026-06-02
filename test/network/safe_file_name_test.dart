import 'package:flutter_test/flutter_test.dart';
import 'package:quick_drop/network/safe_file_name.dart';

void main() {
  group('SafeFileName', () {
    test('keeps only the basename and replaces unsafe characters', () {
      expect(
        SafeFileName.incoming(r'C:\Users\Karan\bad:file?.txt', isFolder: false),
        'bad_file_.txt',
      );
    });

    test('uses the same safe name for outgoing and incoming metadata', () {
      const rawName = r'C:\Users\Karan\bad:file?.txt';

      expect(
        SafeFileName.forTransfer(rawName, isFolder: false),
        SafeFileName.incoming(rawName, isFolder: false),
      );
    });

    test('uses sensible fallbacks for empty or dot names', () {
      expect(SafeFileName.incoming('   ', isFolder: false), 'SharedFile');
      expect(SafeFileName.incoming('.', isFolder: false), 'SharedFile');
      expect(SafeFileName.incoming('..', isFolder: true), 'SharedFolder');
    });

    test('rejects Windows reserved device names', () {
      expect(SafeFileName.incoming('CON', isFolder: false), 'SharedFile');
      expect(SafeFileName.incoming('nul.txt', isFolder: false), 'SharedFile');
      expect(SafeFileName.incoming('COM1', isFolder: false), 'SharedFile');
      expect(SafeFileName.incoming('LPT9.log', isFolder: false), 'SharedFile');
    });

    test('removes unsafe trailing dots and spaces', () {
      expect(SafeFileName.incoming('photo. ', isFolder: false), 'photo');
      expect(SafeFileName.incoming('folder...', isFolder: true), 'folder');
      expect(SafeFileName.incoming('...', isFolder: false), 'SharedFile');
    });

    test('limits very long names', () {
      final name = '${'a' * 250}.txt';
      expect(SafeFileName.incoming(name, isFolder: false), hasLength(180));
    });

    test('does not leave a trailing dot after length capping', () {
      final name = '${'a' * 179}.txt';
      final sanitized = SafeFileName.incoming(name, isFolder: false);

      expect(sanitized, hasLength(179));
      expect(sanitized.endsWith('.'), isFalse);
    });

    test('falls back if length capping removes the safe part', () {
      final name = '${'.' * 180}safe.txt';

      expect(SafeFileName.incoming(name, isFolder: false), 'SharedFile');
    });
  });
}
