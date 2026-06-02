import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quick_drop/network/session_crypto.dart';

void main() {
  group('TransferSessionCrypto', () {
    test('derives the same file key from the same transfer context', () async {
      final sharedSecret = SecretKey(List<int>.generate(32, (i) => i + 1));
      final senderPublicKey = base64Encode(List<int>.generate(32, (i) => i));
      final receiverPublicKey =
          base64Encode(List<int>.generate(32, (i) => 255 - i));

      final first = await TransferSessionCrypto.deriveFileKey(
        sharedSecret: sharedSecret,
        senderPublicKeyBase64: senderPublicKey,
        receiverPublicKeyBase64: receiverPublicKey,
        fileName: 'photo.jpg',
        fileSize: 12345,
        isFolder: false,
      );
      final second = await TransferSessionCrypto.deriveFileKey(
        sharedSecret: sharedSecret,
        senderPublicKeyBase64: senderPublicKey,
        receiverPublicKeyBase64: receiverPublicKey,
        fileName: 'photo.jpg',
        fileSize: 12345,
        isFolder: false,
      );

      expect(second, orderedEquals(first));
      expect(first.length, 32);
    });

    test('derives a different key when transfer metadata changes', () async {
      final sharedSecret = SecretKey(List<int>.generate(32, (i) => i + 1));
      final senderPublicKey = base64Encode(List<int>.generate(32, (i) => i));
      final receiverPublicKey =
          base64Encode(List<int>.generate(32, (i) => 255 - i));

      final fileKey = await TransferSessionCrypto.deriveFileKey(
        sharedSecret: sharedSecret,
        senderPublicKeyBase64: senderPublicKey,
        receiverPublicKeyBase64: receiverPublicKey,
        fileName: 'photo.jpg',
        fileSize: 12345,
        isFolder: false,
      );
      final renamedFileKey = await TransferSessionCrypto.deriveFileKey(
        sharedSecret: sharedSecret,
        senderPublicKeyBase64: senderPublicKey,
        receiverPublicKeyBase64: receiverPublicKey,
        fileName: 'photo-copy.jpg',
        fileSize: 12345,
        isFolder: false,
      );

      expect(renamedFileKey, isNot(orderedEquals(fileKey)));
    });

    test('derives a separate upload token from the file key', () async {
      final sharedSecret = SecretKey(List<int>.generate(32, (i) => i + 1));
      final senderPublicKey = base64Encode(List<int>.generate(32, (i) => i));
      final receiverPublicKey =
          base64Encode(List<int>.generate(32, (i) => 255 - i));

      final fileKey = await TransferSessionCrypto.deriveFileKey(
        sharedSecret: sharedSecret,
        senderPublicKeyBase64: senderPublicKey,
        receiverPublicKeyBase64: receiverPublicKey,
        fileName: 'photo.jpg',
        fileSize: 12345,
        isFolder: false,
      );
      final uploadToken = await TransferSessionCrypto.deriveUploadToken(
        sharedSecret: sharedSecret,
        senderPublicKeyBase64: senderPublicKey,
        receiverPublicKeyBase64: receiverPublicKey,
        fileName: 'photo.jpg',
        fileSize: 12345,
        isFolder: false,
      );
      final secondUploadToken = await TransferSessionCrypto.deriveUploadToken(
        sharedSecret: sharedSecret,
        senderPublicKeyBase64: senderPublicKey,
        receiverPublicKeyBase64: receiverPublicKey,
        fileName: 'photo.jpg',
        fileSize: 12345,
        isFolder: false,
      );

      expect(uploadToken, secondUploadToken);
      expect(uploadToken, isNot(base64Encode(fileKey)));
    });

    test('compares upload tokens without early length shortcuts', () {
      expect(TransferSessionCrypto.constantTimeEquals('abc', 'abc'), isTrue);
      expect(TransferSessionCrypto.constantTimeEquals('abc', 'abd'), isFalse);
      expect(TransferSessionCrypto.constantTimeEquals('abc', 'ab'), isFalse);
      expect(TransferSessionCrypto.constantTimeEquals('', ''), isTrue);
    });
  });
}
