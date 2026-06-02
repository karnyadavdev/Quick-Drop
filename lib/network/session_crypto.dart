import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

class TransferSessionCrypto {
  static final Hkdf _kdf = Hkdf(
    hmac: Hmac.sha256(),
    outputLength: 32,
  );

  static Future<Uint8List> deriveFileKey({
    required SecretKey sharedSecret,
    required String senderPublicKeyBase64,
    required String receiverPublicKeyBase64,
    required String fileName,
    required int fileSize,
    required bool isFolder,
  }) async {
    return _deriveBytes(
      sharedSecret: sharedSecret,
      senderPublicKeyBase64: senderPublicKeyBase64,
      receiverPublicKeyBase64: receiverPublicKeyBase64,
      fileName: fileName,
      fileSize: fileSize,
      isFolder: isFolder,
      purpose: 'file-key',
    );
  }

  static Future<String> deriveUploadToken({
    required SecretKey sharedSecret,
    required String senderPublicKeyBase64,
    required String receiverPublicKeyBase64,
    required String fileName,
    required int fileSize,
    required bool isFolder,
  }) async {
    final bytes = await _deriveBytes(
      sharedSecret: sharedSecret,
      senderPublicKeyBase64: senderPublicKeyBase64,
      receiverPublicKeyBase64: receiverPublicKeyBase64,
      fileName: fileName,
      fileSize: fileSize,
      isFolder: isFolder,
      purpose: 'upload-token',
    );
    return base64Encode(bytes);
  }

  static Future<String> deriveSecurityCode({
    required SecretKey sharedSecret,
    required String senderPublicKeyBase64,
    required String receiverPublicKeyBase64,
    required String fileName,
    required int fileSize,
    required bool isFolder,
  }) async {
    final bytes = await _deriveBytes(
      sharedSecret: sharedSecret,
      senderPublicKeyBase64: senderPublicKeyBase64,
      receiverPublicKeyBase64: receiverPublicKeyBase64,
      fileName: fileName,
      fileSize: fileSize,
      isFolder: isFolder,
      purpose: 'security-code',
    );
    final number =
        ByteData.sublistView(bytes).getUint32(0, Endian.big) % 1000000;
    final padded = number.toString().padLeft(6, '0');
    return '${padded.substring(0, 3)} ${padded.substring(3)}';
  }

  static bool constantTimeEquals(String a, String b) {
    final maxLength = a.length > b.length ? a.length : b.length;
    var difference = a.length ^ b.length;

    for (var i = 0; i < maxLength; i++) {
      final left = i < a.length ? a.codeUnitAt(i) : 0;
      final right = i < b.length ? b.codeUnitAt(i) : 0;
      difference |= left ^ right;
    }

    return difference == 0;
  }

  static Future<Uint8List> _deriveBytes({
    required SecretKey sharedSecret,
    required String senderPublicKeyBase64,
    required String receiverPublicKeyBase64,
    required String fileName,
    required int fileSize,
    required bool isFolder,
    required String purpose,
  }) async {
    if (fileSize < 0) {
      throw ArgumentError.value(fileSize, 'fileSize');
    }

    final key = await _kdf.deriveKey(
      secretKey: sharedSecret,
      nonce: utf8.encode(
        'quickdrop-v2|$senderPublicKeyBase64|$receiverPublicKeyBase64',
      ),
      info: utf8.encode(
        '$purpose|$fileName|$fileSize|${isFolder ? 1 : 0}',
      ),
    );

    return Uint8List.fromList(await key.extractBytes());
  }
}
