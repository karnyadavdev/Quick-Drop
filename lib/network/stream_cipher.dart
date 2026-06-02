import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:sodium/sodium.dart' as sodium_core;
import 'package:sodium_libs/sodium_libs.dart';

part 'crypto_worker_pool.dart';

class AuthenticatedStreamCryptor {
  static const int _macLength = 16;
  static const int _noncePrefixLength = 20;
  static const int _nonceLength = 24;
  static const int _frameHeaderLength = 4;
  static const int chunkSize = 1024 * 1024;
  static const int _maxClearTextChunkLength = chunkSize;
  static const int _maxParallelJobs = 8;
  static const int _flushBatchBlocks = _maxParallelJobs;

  static int get macLength => _macLength;
  static int get noncePrefixLength => _noncePrefixLength;

  static int encryptedLengthFor(int clearTextLength) {
    if (clearTextLength < 0) {
      throw ArgumentError.value(clearTextLength, 'clearTextLength');
    }
    if (clearTextLength == 0) return 0;

    final frames = (clearTextLength + chunkSize - 1) ~/ chunkSize;
    return clearTextLength + (frames * (_frameHeaderLength + macLength));
  }

  static Uint8List newNoncePrefix() {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(_noncePrefixLength, (_) => random.nextInt(256)),
    );
  }

  static List<int> metadataAad({
    required String fileName,
    required int fileSize,
    required bool isFolder,
  }) {
    if (fileSize < 0) {
      throw ArgumentError.value(fileSize, 'fileSize');
    }
    return Uint8List.fromList(
      utf8.encode('quickdrop-v2|$fileName|$fileSize|${isFolder ? 1 : 0}'),
    );
  }

  static Future<void> streamEncryptAndWrite({
    required Stream<List<int>> stream,
    required HttpClientRequest request,
    required Uint8List key,
    required Uint8List noncePrefix,
    required List<int> aad,
    required void Function(int chunkLength) onProgress,
    Duration? writeTimeout,
    bool Function()? isCancelled,
  }) async {
    final pool = await _CryptoWorkerPool.start(key, _maxParallelJobs);
    final done = Completer<void>();
    final buffer = BytesBuilder(copy: false);
    final pending = <_PendingEncryptedBlock>[];
    late final StreamSubscription<List<int>> subscription;
    var counter = 0;
    var isWriting = false;
    var blocksSinceFlush = 0;
    var bytesSinceFlush = 0;
    Completer<void>? drainCompleter;

    Future<void> waitForDrain() {
      if (pending.isEmpty && !isWriting) {
        return Future<void>.value();
      }
      drainCompleter ??= Completer<void>();
      return drainCompleter!.future;
    }

    void completeDrainIfIdle() {
      if (pending.isNotEmpty || isWriting) return;
      final completer = drainCompleter;
      if (completer == null || completer.isCompleted) return;
      drainCompleter = null;
      completer.complete();
    }

    void failDrain(Object error, StackTrace stackTrace) {
      final completer = drainCompleter;
      if (completer == null || completer.isCompleted) return;
      drainCompleter = null;
      completer.completeError(error, stackTrace);
    }

    Future<void> flushProgress() async {
      if (bytesSinceFlush == 0) return;
      final flush = request.flush();
      if (writeTimeout == null) {
        await flush;
      } else {
        await flush.timeout(writeTimeout);
      }
      onProgress(bytesSinceFlush);
      blocksSinceFlush = 0;
      bytesSinceFlush = 0;
    }

    Future<void> writeQueue() async {
      if (isWriting) return;
      isWriting = true;

      while (pending.isNotEmpty) {
        final next = pending.removeAt(0);
        if (subscription.isPaused && pending.length < _maxParallelJobs) {
          subscription.resume();
        }

        try {
          final parts = await next.future;
          for (final part in parts) {
            request.add(part);
          }
          blocksSinceFlush++;
          bytesSinceFlush += next.clearTextLength;
          if (blocksSinceFlush >= _flushBatchBlocks || pending.isEmpty) {
            await flushProgress();
          }
        } catch (e, stackTrace) {
          await subscription.cancel();
          if (!done.isCompleted) done.completeError(e, stackTrace);
          failDrain(e, stackTrace);
          isWriting = false;
          return;
        }
      }

      isWriting = false;
      completeDrainIfIdle();
    }

    void queueBlock(Uint8List block) {
      pending.add(
        _PendingEncryptedBlock(
          clearTextLength: block.length,
          future: pool.encrypt(
            block,
            _nonceFor(noncePrefix, counter),
            _chunkAad(aad, counter),
          ),
        ),
      );
      counter++;

      if (pending.length == 1) {
        unawaited(writeQueue());
      }
      if (pending.length >= _maxParallelJobs) {
        subscription.pause();
      }
    }

    subscription = stream.listen(
      (chunk) {
        if (isCancelled != null && isCancelled()) {
          done.completeError(Exception('Transfer cancelled by user'));
          subscription.cancel();
          return;
        }
        buffer.add(chunk);
        while (buffer.length >= chunkSize) {
          final bytes = buffer.takeBytes();
          queueBlock(Uint8List.sublistView(bytes, 0, chunkSize));

          final remaining = bytes.length - chunkSize;
          if (remaining > 0) {
            buffer.add(Uint8List.sublistView(bytes, chunkSize));
          }
        }
      },
      onDone: () async {
        try {
          if (buffer.isNotEmpty) {
            queueBlock(buffer.takeBytes());
          }

          if (pending.isNotEmpty && !isWriting) {
            unawaited(writeQueue());
          }
          await waitForDrain();

          await flushProgress();
          if (!done.isCompleted) done.complete();
        } catch (e, stackTrace) {
          if (!done.isCompleted) done.completeError(e, stackTrace);
        }
      },
      onError: (Object e, StackTrace stackTrace) {
        if (!done.isCompleted) done.completeError(e, stackTrace);
      },
      cancelOnError: true,
    );

    try {
      await done.future;
    } finally {
      for (final item in pending) {
        unawaited(item.future.catchError((_) => <Uint8List>[]));
      }
      pool.close();
    }
  }

  static Stream<Uint8List> streamDecrypt({
    required Stream<List<int>> stream,
    required Uint8List key,
    required Uint8List noncePrefix,
    required List<int> aad,
    bool Function()? isCancelled,
  }) {
    final controller = StreamController<Uint8List>();

    () async {
      late final _CryptoWorkerPool pool;
      try {
        pool = await _CryptoWorkerPool.start(key, _maxParallelJobs);
      } catch (e, stackTrace) {
        controller.addError(e, stackTrace);
        await controller.close();
        return;
      }

      final buffer = BytesBuilder(copy: false);
      final pending = <Future<Uint8List>>[];
      late final StreamSubscription<List<int>> subscription;
      var counter = 0;
      var networkDone = false;
      var isYielding = false;
      var isClosed = false;
      int? nextFrameLength;

      Future<void> closeController() async {
        if (isClosed) return;
        isClosed = true;
        for (final future in pending) {
          unawaited(future.catchError((_) => Uint8List(0)));
        }
        pool.close();
        await controller.close();
      }

      Future<void> yieldQueue() async {
        if (isYielding || isClosed) return;
        isYielding = true;

        while (pending.isNotEmpty) {
          final future = pending.removeAt(0);
          if (subscription.isPaused && pending.length < _maxParallelJobs) {
            subscription.resume();
          }

          try {
            final chunk = await future;
            if (isClosed) return;
            controller.add(chunk);
          } catch (e, stackTrace) {
            if (isClosed) return;
            await subscription.cancel();
            controller.addError(e, stackTrace);
            isYielding = false;
            await closeController();
            return;
          }
        }

        isYielding = false;
        if (networkDone) {
          await closeController();
        }
      }

      void queueFrame(Uint8List bytes, int frameEnd) {
        const frameStart = _frameHeaderLength;
        final cipherTextLength = nextFrameLength! - macLength;
        final cipherText = Uint8List.fromList(
          Uint8List.sublistView(
            bytes,
            frameStart,
            frameStart + cipherTextLength,
          ),
        );
        final macBytes = Uint8List.fromList(
          Uint8List.sublistView(
            bytes,
            frameStart + cipherTextLength,
            frameEnd,
          ),
        );

        pending.add(pool.decrypt(
          cipherText,
          _nonceFor(noncePrefix, counter),
          macBytes,
          _chunkAad(aad, counter),
        ));
        counter++;
        nextFrameLength = null;

        if (pending.length == 1) {
          unawaited(yieldQueue());
        }
        if (pending.length >= _maxParallelJobs) {
          subscription.pause();
        }
      }

      subscription = stream.listen(
        (chunk) {
          if (isCancelled != null && isCancelled()) {
            controller.addError(Exception('Transfer cancelled by user'));
            subscription.cancel();
            closeController();
            return;
          }
          buffer.add(chunk);

          while (true) {
            if (nextFrameLength == null) {
              if (buffer.length < _frameHeaderLength) break;
              final bytes = buffer.takeBytes();
              nextFrameLength = _readFrameLength(bytes, 0);
              try {
                _validateFrameLength(nextFrameLength!);
              } catch (e, stackTrace) {
                controller.addError(e, stackTrace);
                unawaited(subscription.cancel());
                unawaited(closeController());
                return;
              }
              buffer.add(bytes);
            }

            final frameEnd = _frameHeaderLength + nextFrameLength!;
            if (buffer.length < frameEnd) break;

            final bytes = buffer.takeBytes();
            queueFrame(bytes, frameEnd);

            final remaining = bytes.length - frameEnd;
            if (remaining > 0) {
              buffer.add(Uint8List.sublistView(bytes, frameEnd));
            }
          }
        },
        onDone: () {
          networkDone = true;
          if (nextFrameLength != null || buffer.isNotEmpty) {
            controller.addError(
              const FormatException('Encrypted stream ended mid-frame.'),
            );
            unawaited(closeController());
            return;
          }
          if (pending.isEmpty && !isYielding) {
            unawaited(closeController());
          } else {
            unawaited(yieldQueue());
          }
        },
        onError: (Object e, StackTrace stackTrace) {
          controller.addError(e, stackTrace);
          unawaited(closeController());
        },
        cancelOnError: true,
      );

      controller.onCancel = () async {
        if (!isClosed) {
          await subscription.cancel();
          await closeController();
        }
      };
    }();

    return controller.stream;
  }

  static Future<List<Uint8List>> encryptBlock(
    Uint8List block,
    Uint8List key,
    Uint8List nonce,
    Uint8List aad,
  ) async {
    final sodium = await _loadSodium();
    final secureKey = sodium.secureCopy(key);
    try {
      return _encryptWithKey(sodium, secureKey, block, nonce, aad);
    } finally {
      secureKey.dispose();
    }
  }

  static Future<Uint8List> decryptBlock(
    Uint8List cipherText,
    Uint8List key,
    Uint8List nonce,
    Uint8List macBytes,
    Uint8List aad,
  ) async {
    final sodium = await _loadSodium();
    final secureKey = sodium.secureCopy(key);
    try {
      return _decryptWithKey(
        sodium,
        secureKey,
        cipherText,
        nonce,
        macBytes,
        aad,
      );
    } finally {
      secureKey.dispose();
    }
  }

  static Future<Sodium> _loadSodium() {
    return sodium_core.SodiumInit.init2(_openSodiumLibrary);
  }

  static DynamicLibrary _openSodiumLibrary() {
    Object? lastError;
    for (final candidate in _sodiumLibraryCandidates()) {
      try {
        return DynamicLibrary.open(candidate);
      } catch (e) {
        lastError = e;
      }
    }
    throw ArgumentError('Unable to load libsodium.dll: $lastError');
  }

  static List<String> _sodiumLibraryCandidates() {
    if (!Platform.isWindows) return const ['libsodium.so'];

    final candidates = <String>['libsodium.dll'];
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData != null && localAppData.isNotEmpty) {
      final packageRoot = Directory(
        '$localAppData\\Pub\\Cache\\hosted\\pub.dev',
      );
      if (packageRoot.existsSync()) {
        for (final package
            in packageRoot.listSync().whereType<Directory>().where(
                  (dir) => dir.path
                      .split(Platform.pathSeparator)
                      .last
                      .startsWith('sodium_libs-'),
                )) {
          candidates.addAll([
            '${package.path}\\windows\\lib\\Release\\v143\\libsodium.dll',
            '${package.path}\\windows\\lib\\Release\\v142\\libsodium.dll',
            '${package.path}\\windows\\lib\\Debug\\v143\\libsodium.dll',
            '${package.path}\\windows\\lib\\Debug\\v142\\libsodium.dll',
          ]);
        }
      }
    }
    return candidates;
  }

  static List<Uint8List> _encryptWithKey(
    Sodium sodium,
    SecureKey key,
    Uint8List block,
    Uint8List nonce,
    Uint8List aad,
  ) {
    final encryptedBytes = sodium.crypto.aeadXChaCha20Poly1305IETF.encrypt(
      message: block,
      additionalData: aad,
      nonce: nonce,
      key: key,
    );
    final header = Uint8List(_frameHeaderLength);
    ByteData.sublistView(header)
        .setUint32(0, encryptedBytes.length, Endian.big);
    return [header, encryptedBytes];
  }

  static Uint8List _decryptWithKey(
    Sodium sodium,
    SecureKey key,
    Uint8List cipherText,
    Uint8List nonce,
    Uint8List macBytes,
    Uint8List aad,
  ) {
    return sodium.crypto.aeadXChaCha20Poly1305IETF.decryptDetached(
      cipherText: cipherText,
      mac: macBytes,
      additionalData: aad,
      nonce: nonce,
      key: key,
    );
  }

  static void _validateFrameLength(int frameLength) {
    if (frameLength < macLength) {
      throw const FormatException('Encrypted frame is too short.');
    }
    if (frameLength > _maxClearTextChunkLength + macLength) {
      throw const FormatException('Encrypted frame exceeds the size limit.');
    }
  }

  static Uint8List _chunkAad(List<int> aad, int counter) {
    final result = Uint8List(aad.length + 4);
    result.setAll(0, aad);
    ByteData.sublistView(result).setUint32(aad.length, counter, Endian.big);
    return result;
  }

  static int _readFrameLength(Uint8List bytes, int offset) {
    return ByteData.sublistView(bytes, offset, offset + _frameHeaderLength)
        .getUint32(0, Endian.big);
  }

  static Uint8List _nonceFor(Uint8List prefix, int counter) {
    if (prefix.length != _noncePrefixLength) {
      throw ArgumentError.value(prefix.length, 'prefix.length');
    }
    final nonce = Uint8List(_nonceLength);
    nonce.setAll(0, prefix);
    ByteData.sublistView(nonce)
        .setUint32(_noncePrefixLength, counter, Endian.big);
    return nonce;
  }
}

class _PendingEncryptedBlock {
  final int clearTextLength;
  final Future<List<Uint8List>> future;

  const _PendingEncryptedBlock({
    required this.clearTextLength,
    required this.future,
  });
}
