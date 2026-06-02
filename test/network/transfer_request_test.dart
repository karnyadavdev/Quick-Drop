import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:quick_drop/network/transfer_request.dart';

void main() {
  group('TransferRequest', () {
    test('parses and trims a valid transfer request', () {
      final publicKey = base64Encode(List<int>.generate(32, (i) => i));

      final request = TransferRequest.fromJson({
        'id': ' peer-1 ',
        'name': ' Penguin   PC ',
        'deviceType': 'desktop',
        'fileName': ' photo.jpg ',
        'fileSize': 123,
        'isFolder': false,
        'publicKey': publicKey,
      });

      expect(request.senderId, 'peer-1');
      expect(request.senderName, 'Penguin PC');
      expect(request.senderDeviceType, 'desktop');
      expect(request.fileName, 'photo.jpg');
      expect(request.fileSize, 123);
      expect(request.isFolder, isFalse);
      expect(request.publicKeyBytes.length, 32);
    });

    test('defaults invalid optional deviceType and folder flag', () {
      final publicKey = base64Encode(List<int>.generate(32, (i) => i));

      final request = TransferRequest.fromJson({
        'id': 'peer-1',
        'name': 'Penguin',
        'deviceType': 'bad',
        'fileName': 'folder',
        'fileSize': 123,
        'isFolder': 'true',
        'publicKey': publicKey,
      });

      expect(request.senderDeviceType, 'desktop');
      expect(request.isFolder, isFalse);
    });

    test('rejects bad file sizes and public keys', () {
      final publicKey = base64Encode(List<int>.generate(32, (i) => i));
      final base = {
        'id': 'peer-1',
        'name': 'Penguin',
        'fileName': 'photo.jpg',
        'fileSize': 123,
        'publicKey': publicKey,
      };

      expect(
        () => TransferRequest.fromJson({...base, 'fileSize': -1}),
        throwsFormatException,
      );
      expect(
        () => TransferRequest.fromJson({...base, 'fileSize': 1.5}),
        throwsFormatException,
      );
      expect(
        () => TransferRequest.fromJson({...base, 'fileSize': 123.0}),
        throwsFormatException,
      );
      expect(
        () => TransferRequest.fromJson({...base, 'publicKey': 'bad'}),
        throwsFormatException,
      );
      expect(
        () => TransferRequest.fromJson({
          ...base,
          'publicKey': base64Encode([1, 2, 3]),
        }),
        throwsFormatException,
      );
    });
  });

  group('TransferResponse', () {
    test('parses accepted response with public key', () {
      final publicKey = base64Encode(List<int>.generate(32, (i) => i));

      final response = TransferResponse.fromJson({
        'status': 'accepted',
        'publicKey': publicKey,
      });

      expect(response.status, 'accepted');
      expect(response.publicKeyBase64, publicKey);
      expect(response.publicKeyBytes, hasLength(32));
    });

    test('parses declined response without public key', () {
      final response = TransferResponse.fromJson({'status': ' rejected '});

      expect(response.status, 'rejected');
      expect(response.publicKeyBase64, isNull);
      expect(response.publicKeyBytes, isNull);
    });

    test('rejects accepted response with bad public key', () {
      expect(
        () => TransferResponse.fromJson({
          'status': 'accepted',
          'publicKey': base64Encode([1, 2, 3]),
        }),
        throwsFormatException,
      );
    });

    test('rejects unknown response statuses', () {
      expect(
        () => TransferResponse.fromJson({'status': 'maybe'}),
        throwsFormatException,
      );
      expect(
        () => TransferResponse.fromJson({'status': ''}),
        throwsFormatException,
      );
    });
  });

  group('UploadResult', () {
    test('accepts only receiver success confirmation', () {
      expect(
        UploadResult.fromJson({'status': 'success'}),
        isA<UploadResult>(),
      );
    });

    test('rejects missing or non-success statuses', () {
      expect(
        () => UploadResult.fromJson({'status': 'failed'}),
        throwsFormatException,
      );
      expect(
        () => UploadResult.fromJson({'ok': true}),
        throwsFormatException,
      );
    });
  });

  group('UploadRequestMetadata', () {
    test('parses required upload headers', () {
      final noncePrefix = base64Encode(List<int>.generate(8, (i) => i));

      final metadata = UploadRequestMetadata.fromHeaders(
        encodedFileName: Uri.encodeComponent('  photo 1.jpg  '),
        fileSize: '123',
        isFolder: 'false',
        senderId: 'peer-1',
        noncePrefix: noncePrefix,
        encryptedLength: 143,
        expectedNoncePrefixLength: 8,
      );

      expect(metadata.fileName, 'photo 1.jpg');
      expect(metadata.fileSize, 123);
      expect(metadata.isFolder, isFalse);
      expect(metadata.senderId, 'peer-1');
      expect(metadata.noncePrefix, hasLength(8));
      expect(metadata.encryptedLength, 143);
    });

    test('rejects empty decoded upload file names', () {
      final noncePrefix = base64Encode(List<int>.generate(8, (i) => i));

      expect(
        () => UploadRequestMetadata.fromHeaders(
          encodedFileName: Uri.encodeComponent('   '),
          fileSize: '123',
          isFolder: 'false',
          senderId: 'peer-1',
          noncePrefix: noncePrefix,
          encryptedLength: 143,
          expectedNoncePrefixLength: 8,
        ),
        throwsFormatException,
      );
    });

    test('rejects missing or malformed upload headers', () {
      final noncePrefix = base64Encode(List<int>.generate(8, (i) => i));
      final base = {
        'encodedFileName': Uri.encodeComponent('photo.jpg'),
        'fileSize': '123',
        'isFolder': 'false',
        'senderId': 'peer-1',
        'noncePrefix': noncePrefix,
      };

      expect(
        () => UploadRequestMetadata.fromHeaders(
          encodedFileName: null,
          fileSize: base['fileSize'],
          isFolder: base['isFolder'],
          senderId: base['senderId'],
          noncePrefix: base['noncePrefix'],
          encryptedLength: 143,
          expectedNoncePrefixLength: 8,
        ),
        throwsFormatException,
      );
      expect(
        () => UploadRequestMetadata.fromHeaders(
          encodedFileName: base['encodedFileName'],
          fileSize: '-1',
          isFolder: base['isFolder'],
          senderId: base['senderId'],
          noncePrefix: base['noncePrefix'],
          encryptedLength: 143,
          expectedNoncePrefixLength: 8,
        ),
        throwsFormatException,
      );
      expect(
        () => UploadRequestMetadata.fromHeaders(
          encodedFileName: base['encodedFileName'],
          fileSize: base['fileSize'],
          isFolder: 'yes',
          senderId: base['senderId'],
          noncePrefix: base['noncePrefix'],
          encryptedLength: 143,
          expectedNoncePrefixLength: 8,
        ),
        throwsFormatException,
      );
      expect(
        () => UploadRequestMetadata.fromHeaders(
          encodedFileName: base['encodedFileName'],
          fileSize: base['fileSize'],
          isFolder: base['isFolder'],
          senderId: base['senderId'],
          noncePrefix: base64Encode([1, 2, 3]),
          encryptedLength: 143,
          expectedNoncePrefixLength: 8,
        ),
        throwsFormatException,
      );
      expect(
        () => UploadRequestMetadata.fromHeaders(
          encodedFileName: base['encodedFileName'],
          fileSize: base['fileSize'],
          isFolder: base['isFolder'],
          senderId: base['senderId'],
          noncePrefix: base['noncePrefix'],
          encryptedLength: -1,
          expectedNoncePrefixLength: 8,
        ),
        throwsFormatException,
      );
    });
  });
}
