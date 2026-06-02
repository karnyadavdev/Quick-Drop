import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:quick_drop/network/stream_cipher.dart';

void main() {
  group('AuthenticatedStreamCryptor', () {
    test('calculates encrypted body length', () {
      expect(AuthenticatedStreamCryptor.encryptedLengthFor(0), 0);
      expect(
        AuthenticatedStreamCryptor.encryptedLengthFor(1),
        1 + 4 + AuthenticatedStreamCryptor.macLength,
      );
      expect(
        AuthenticatedStreamCryptor.encryptedLengthFor(
          AuthenticatedStreamCryptor.chunkSize + 1,
        ),
        AuthenticatedStreamCryptor.chunkSize +
            1 +
            (2 * (4 + AuthenticatedStreamCryptor.macLength)),
      );
      expect(
        () => AuthenticatedStreamCryptor.encryptedLengthFor(-1),
        throwsArgumentError,
      );
    });

    test('rejects negative metadata file sizes', () {
      expect(
        () => AuthenticatedStreamCryptor.metadataAad(
          fileName: 'bad.txt',
          fileSize: -1,
          isFolder: false,
        ),
        throwsArgumentError,
      );
    });

    test('decrypts a framed encrypted block', () async {
      final key = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
      final noncePrefix = _testNoncePrefix(1);
      final clearText =
          Uint8List.fromList(utf8.encode('hello from Quick Drop'));
      final aad = AuthenticatedStreamCryptor.metadataAad(
        fileName: 'hello.txt',
        fileSize: clearText.length,
        isFolder: false,
      );

      final encryptedParts = await AuthenticatedStreamCryptor.encryptBlock(
        clearText,
        key,
        _nonceFor(noncePrefix, 0),
        _chunkAad(aad, 0),
      );
      final framedBytes =
          Uint8List.fromList(encryptedParts.expand((e) => e).toList());

      final decryptedChunks = await AuthenticatedStreamCryptor.streamDecrypt(
        stream: Stream<List<int>>.fromIterable([
          framedBytes.sublist(0, 5),
          framedBytes.sublist(5),
        ]),
        key: key,
        noncePrefix: noncePrefix,
        aad: aad,
      ).toList();

      expect(
        utf8.decode(decryptedChunks.expand((chunk) => chunk).toList()),
        'hello from Quick Drop',
      );
    });

    test('reports an error for a truncated encrypted frame', () {
      final key = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
      final noncePrefix = _testNoncePrefix(1);
      final aad = AuthenticatedStreamCryptor.metadataAad(
        fileName: 'bad.txt',
        fileSize: 10,
        isFolder: false,
      );

      final controller = StreamController<List<int>>();
      final decrypted = AuthenticatedStreamCryptor.streamDecrypt(
        stream: controller.stream,
        key: key,
        noncePrefix: noncePrefix,
        aad: aad,
      );

      controller.add(Uint8List.fromList([0, 0, 0, 20, 1, 2, 3]));
      controller.close();

      expect(decrypted.toList(), throwsFormatException);
    });

    test('preserves order across a multi-chunk encrypted stream', () async {
      final key = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
      final noncePrefix = _testNoncePrefix(2);
      final clearText = Uint8List.fromList(
        List<int>.generate(
          (AuthenticatedStreamCryptor.chunkSize * 3) + 123,
          (i) => i % 251,
        ),
      );
      final aad = AuthenticatedStreamCryptor.metadataAad(
        fileName: 'large.bin',
        fileSize: clearText.length,
        isFolder: false,
      );

      final received = Completer<Uint8List>();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final serverSub = server.listen((request) async {
        final chunks = await AuthenticatedStreamCryptor.streamDecrypt(
          stream: request,
          key: key,
          noncePrefix: noncePrefix,
          aad: aad,
        ).toList();
        request.response.statusCode = HttpStatus.ok;
        await request.response.close();
        received.complete(Uint8List.fromList(chunks.expand((e) => e).toList()));
      });

      final client = HttpClient();
      var progressBytes = 0;

      try {
        final request = await client.postUrl(
          Uri.parse('http://127.0.0.1:${server.port}/upload'),
        );
        request.headers.contentType = ContentType.binary;

        await AuthenticatedStreamCryptor.streamEncryptAndWrite(
          stream: _splitBytes(clearText, const [333, 8191, 104729]),
          request: request,
          key: key,
          noncePrefix: noncePrefix,
          aad: aad,
          onProgress: (bytes) => progressBytes += bytes,
        );

        final response = await request.close();
        await response.drain<void>();

        expect(response.statusCode, HttpStatus.ok);
        expect(progressBytes, clearText.length);
        expect(await received.future, orderedEquals(clearText));
      } finally {
        client.close(force: true);
        await serverSub.cancel();
        await server.close(force: true);
      }
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('reports progress after flushed batches', () async {
      final key = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
      final noncePrefix = _testNoncePrefix(5);
      final clearText = Uint8List.fromList(
        List<int>.generate(
          (AuthenticatedStreamCryptor.chunkSize * 4) + 100,
          (i) => i % 251,
        ),
      );
      final aad = AuthenticatedStreamCryptor.metadataAad(
        fileName: 'progress.bin',
        fileSize: clearText.length,
        isFolder: false,
      );

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final serverSub = server.listen((request) async {
        await request.drain<void>();
        request.response.statusCode = HttpStatus.ok;
        await request.response.close();
      });
      final client = HttpClient();
      final progressEvents = <int>[];

      try {
        final request = await client.postUrl(
          Uri.parse('http://127.0.0.1:${server.port}/upload'),
        );
        request.headers.contentType = ContentType.binary;

        await AuthenticatedStreamCryptor.streamEncryptAndWrite(
          stream: _splitBytes(clearText, const [65536]),
          request: request,
          key: key,
          noncePrefix: noncePrefix,
          aad: aad,
          onProgress: progressEvents.add,
        );

        final response = await request.close();
        await response.drain<void>();

        expect(response.statusCode, HttpStatus.ok);
        expect(progressEvents.reduce((a, b) => a + b), clearText.length);
        expect(progressEvents.length, lessThan(5));
      } finally {
        client.close(force: true);
        await serverSub.cancel();
        await server.close(force: true);
      }
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('decrypt stream cancels cleanly with queued chunks', () async {
      final key = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
      final noncePrefix = _testNoncePrefix(4);
      final clearText = Uint8List.fromList(
        List<int>.generate(
          AuthenticatedStreamCryptor.chunkSize * 4,
          (i) => i % 251,
        ),
      );
      final aad = AuthenticatedStreamCryptor.metadataAad(
        fileName: 'cancel.bin',
        fileSize: clearText.length,
        isFolder: false,
      );
      final framed = BytesBuilder(copy: false);

      var offset = 0;
      var counter = 0;
      while (offset < clearText.length) {
        final end = (offset + AuthenticatedStreamCryptor.chunkSize).clamp(
          0,
          clearText.length,
        );
        final parts = await AuthenticatedStreamCryptor.encryptBlock(
          Uint8List.sublistView(clearText, offset, end),
          key,
          _nonceFor(noncePrefix, counter),
          _chunkAad(aad, counter),
        );
        for (final part in parts) {
          framed.add(part);
        }
        offset = end;
        counter++;
      }

      final source = StreamController<List<int>>();
      final cancelDone = Completer<void>();
      var receivedBytes = 0;
      late final StreamSubscription<Uint8List> subscription;
      subscription = AuthenticatedStreamCryptor.streamDecrypt(
        stream: source.stream,
        key: key,
        noncePrefix: noncePrefix,
        aad: aad,
      ).listen(
        (chunk) {
          receivedBytes += chunk.length;
          if (!cancelDone.isCompleted) {
            subscription.cancel().then(cancelDone.complete);
          }
        },
        onError: cancelDone.completeError,
      );

      source.add(framed.takeBytes());
      await cancelDone.future.timeout(const Duration(seconds: 10));
      await source.close();

      expect(receivedBytes, AuthenticatedStreamCryptor.chunkSize);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('decrypt stream reports an inactive input timeout', () async {
      final key = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
      final noncePrefix = _testNoncePrefix(9);
      final aad = AuthenticatedStreamCryptor.metadataAad(
        fileName: 'stalled.bin',
        fileSize: 10,
        isFolder: false,
      );
      final source = StreamController<List<int>>();

      try {
        await expectLater(
          AuthenticatedStreamCryptor.streamDecrypt(
            stream: source.stream.timeout(const Duration(milliseconds: 20)),
            key: key,
            noncePrefix: noncePrefix,
            aad: aad,
          ),
          emitsError(isA<TimeoutException>()),
        );
      } finally {
        await source.close();
      }
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('send notices a receiver upload error response', () async {
      final key = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
      final noncePrefix = _testNoncePrefix(3);
      final clearText = Uint8List.fromList(
        List<int>.generate(
          AuthenticatedStreamCryptor.chunkSize * 8,
          (i) => i % 251,
        ),
      );
      final aad = AuthenticatedStreamCryptor.metadataAad(
        fileName: 'disconnect.bin',
        fileSize: clearText.length,
        isFolder: false,
      );

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final serverSub = server.listen((request) async {
        await request.drain<void>();
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      });
      final client = HttpClient();

      try {
        var failed = false;
        try {
          final request = await client.postUrl(
            Uri.parse('http://127.0.0.1:${server.port}/upload'),
          );
          request.headers.contentType = ContentType.binary;

          await AuthenticatedStreamCryptor.streamEncryptAndWrite(
            stream: _splitBytes(clearText, const [65536]),
            request: request,
            key: key,
            noncePrefix: noncePrefix,
            aad: aad,
            onProgress: (_) {},
          );

          final response = await request.close();
          failed = response.statusCode != HttpStatus.ok;
          await response.drain<void>();
        } catch (_) {
          failed = true;
        }

        expect(failed, isTrue);
      } finally {
        client.close(force: true);
        await serverSub.cancel();
        await server.close(force: true);
      }
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
}

Stream<List<int>> _splitBytes(Uint8List bytes, List<int> sizes) async* {
  var offset = 0;
  var sizeIndex = 0;
  while (offset < bytes.length) {
    final size = sizes[sizeIndex % sizes.length];
    final end = (offset + size).clamp(0, bytes.length);
    yield Uint8List.sublistView(bytes, offset, end);
    offset = end;
    sizeIndex++;
  }
}

Uint8List _chunkAad(List<int> aad, int counter) {
  final result = Uint8List(aad.length + 4);
  result.setAll(0, aad);
  ByteData.sublistView(result).setUint32(aad.length, counter, Endian.big);
  return result;
}

Uint8List _nonceFor(Uint8List prefix, int counter) {
  final nonce = Uint8List(24);
  nonce.setAll(0, prefix);
  ByteData.sublistView(nonce).setUint32(20, counter, Endian.big);
  return nonce;
}

Uint8List _testNoncePrefix(int start) {
  return Uint8List.fromList(List<int>.generate(20, (i) => (start + i) % 256));
}
