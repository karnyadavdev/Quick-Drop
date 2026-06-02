import 'dart:convert';
import 'dart:typed_data';

class TransferRequest {
  final String senderId;
  final String senderName;
  final String senderDeviceType;
  final String fileName;
  final int fileSize;
  final bool isFolder;
  final String publicKeyBase64;
  final Uint8List publicKeyBytes;

  const TransferRequest({
    required this.senderId,
    required this.senderName,
    required this.senderDeviceType,
    required this.fileName,
    required this.fileSize,
    required this.isFolder,
    required this.publicKeyBase64,
    required this.publicKeyBytes,
  });

  factory TransferRequest.fromJson(Map<String, dynamic> json) {
    final fileSize = _readFileSize(json['fileSize']);
    final publicKeyBase64 = _readText(json, 'publicKey', maxLength: 128);
    final publicKeyBytes = _decodePublicKey(publicKeyBase64);

    return TransferRequest(
      senderId: _readText(json, 'id', maxLength: 64),
      senderName: _readText(json, 'name', maxLength: 32),
      senderDeviceType: _readDeviceType(json['deviceType']),
      fileName: _readText(json, 'fileName', maxLength: 220),
      fileSize: fileSize,
      isFolder: json['isFolder'] == true,
      publicKeyBase64: publicKeyBase64,
      publicKeyBytes: publicKeyBytes,
    );
  }

  static String _readText(
    Map<String, dynamic> json,
    String key, {
    required int maxLength,
  }) {
    final value = json[key];
    if (value is! String) {
      throw FormatException('Missing transfer field: $key.');
    }

    final trimmed = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (trimmed.isEmpty) {
      throw FormatException('Empty transfer field: $key.');
    }
    return trimmed.length > maxLength
        ? trimmed.substring(0, maxLength)
        : trimmed;
  }

  static int _readFileSize(Object? value) {
    if (value is! int) {
      throw const FormatException('Invalid file size in transfer request.');
    }

    if (value < 0) {
      throw const FormatException('Invalid file size in transfer request.');
    }
    return value;
  }

  static Uint8List _decodePublicKey(String value) {
    try {
      final bytes = Uint8List.fromList(base64Decode(value));
      if (bytes.length != 32) {
        throw const FormatException('Invalid public key length.');
      }
      return bytes;
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('Invalid public key.');
    }
  }

  static String _readDeviceType(Object? value) {
    if (value is String && (value == 'mobile' || value == 'desktop')) {
      return value;
    }
    return 'desktop';
  }
}

class TransferResponse {
  final String status;
  final String? publicKeyBase64;
  final Uint8List? publicKeyBytes;

  const TransferResponse({
    required this.status,
    required this.publicKeyBase64,
    required this.publicKeyBytes,
  });

  factory TransferResponse.fromJson(Map<String, dynamic> json) {
    final value = json['status'];
    if (value is! String || value.trim().isEmpty) {
      throw const FormatException('Missing transfer response status.');
    }

    final status = value.trim();
    if (status != 'accepted' && status != 'pending') {
      if (status != 'rejected') {
        throw const FormatException('Invalid transfer response status.');
      }
      return TransferResponse(
        status: status,
        publicKeyBase64: null,
        publicKeyBytes: null,
      );
    }

    final publicKeyBase64 = TransferRequest._readText(
      json,
      'publicKey',
      maxLength: 128,
    );
    return TransferResponse(
      status: status,
      publicKeyBase64: publicKeyBase64,
      publicKeyBytes: TransferRequest._decodePublicKey(publicKeyBase64),
    );
  }
}

class UploadResult {
  const UploadResult();

  factory UploadResult.fromJson(Map<String, dynamic> json) {
    final status = json['status'];
    if (status != 'success') {
      throw const FormatException('Receiver did not confirm upload success.');
    }
    return const UploadResult();
  }
}

class UploadRequestMetadata {
  final String fileName;
  final int fileSize;
  final bool isFolder;
  final String senderId;
  final Uint8List noncePrefix;
  final int encryptedLength;

  const UploadRequestMetadata({
    required this.fileName,
    required this.fileSize,
    required this.isFolder,
    required this.senderId,
    required this.noncePrefix,
    required this.encryptedLength,
  });

  factory UploadRequestMetadata.fromHeaders({
    required String? encodedFileName,
    required String? fileSize,
    required String? isFolder,
    required String? senderId,
    required String? noncePrefix,
    required int encryptedLength,
    required int expectedNoncePrefixLength,
  }) {
    if (encryptedLength < 0) {
      throw const FormatException('Missing upload content length.');
    }

    final decodedFileName = _decodeFileName(encodedFileName);
    final parsedFileSize = _readHeaderInt(fileSize, 'x-file-size');
    final parsedIsFolder = _readHeaderBool(isFolder, 'x-is-folder');
    final parsedSenderId = _readHeaderText(senderId, 'x-sender-id');
    final parsedNoncePrefix = _decodeNoncePrefix(
      noncePrefix,
      expectedNoncePrefixLength,
    );

    return UploadRequestMetadata(
      fileName: decodedFileName,
      fileSize: parsedFileSize,
      isFolder: parsedIsFolder,
      senderId: parsedSenderId,
      noncePrefix: parsedNoncePrefix,
      encryptedLength: encryptedLength,
    );
  }

  static String _decodeFileName(String? value) {
    final raw = _readHeaderText(value, 'x-file-name');
    try {
      final decoded = Uri.decodeComponent(raw).trim();
      if (decoded.isEmpty) {
        throw const FormatException('Empty upload file name.');
      }
      return decoded.length > 220 ? decoded.substring(0, 220) : decoded;
    } catch (_) {
      throw const FormatException('Invalid upload file name.');
    }
  }

  static String _readHeaderText(String? value, String name) {
    if (value == null) {
      throw FormatException('Missing upload header: $name.');
    }
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      throw FormatException('Empty upload header: $name.');
    }
    return trimmed;
  }

  static int _readHeaderInt(String? value, String name) {
    final text = _readHeaderText(value, name);
    final result = int.tryParse(text);
    if (result == null || result < 0) {
      throw FormatException('Invalid upload header: $name.');
    }
    return result;
  }

  static bool _readHeaderBool(String? value, String name) {
    final text = _readHeaderText(value, name);
    if (text == 'true') return true;
    if (text == 'false') return false;
    throw FormatException('Invalid upload header: $name.');
  }

  static Uint8List _decodeNoncePrefix(String? value, int expectedLength) {
    final text = _readHeaderText(value, 'x-nonce-prefix');
    try {
      final bytes = Uint8List.fromList(base64Decode(text));
      if (bytes.length != expectedLength) {
        throw const FormatException('Invalid upload nonce prefix length.');
      }
      return bytes;
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('Invalid upload nonce prefix.');
    }
  }
}
