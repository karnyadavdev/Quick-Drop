part of 'stream_cipher.dart';

class _CryptoWorkerPool {
  final List<_CryptoWorker> _workers;
  final ReceivePort _results;
  final StreamSubscription<dynamic> _resultSub;
  final Map<int, Completer<dynamic>> _jobs;
  int _nextWorker = 0;
  int _nextJob = 0;
  bool _isClosed = false;

  _CryptoWorkerPool._(
    this._workers,
    this._results,
    this._resultSub,
    this._jobs,
  );

  static Future<_CryptoWorkerPool> start(Uint8List key, int size) async {
    if (size <= 0) {
      throw ArgumentError.value(size, 'size');
    }

    final results = ReceivePort();
    final jobs = <int, Completer<dynamic>>{};

    late final StreamSubscription<dynamic> resultSub;
    resultSub = results.listen((message) {
      final data = message as List<dynamic>;
      final id = data[0] as int;
      final completer = jobs.remove(id);
      if (completer == null) return;

      if (data[1] != true) {
        completer.completeError(Exception(data[2] as String));
        return;
      }

      if (data[2] == 'encrypt') {
        completer.complete(
          (data[3] as List<dynamic>)
              .map(
                (e) => (e as TransferableTypedData).materialize().asUint8List(),
              )
              .toList(),
        );
      } else {
        completer.complete(
          (data[3] as TransferableTypedData).materialize().asUint8List(),
        );
      }
    });

    final workers = <_CryptoWorker>[];
    try {
      for (var i = 0; i < size; i++) {
        final ready = ReceivePort();
        try {
          final isolate = await Isolate.spawn(
            _cryptoWorkerMain,
            [ready.sendPort, results.sendPort, key],
          );
          final response = await ready.first;
          if (response is List && response.isNotEmpty && response[0] == false) {
            throw Exception('Crypto worker failed to start: ${response[1]}');
          }
          final sendPort = response as SendPort;
          workers.add(_CryptoWorker(isolate, sendPort));
        } finally {
          ready.close();
        }
      }
    } catch (_) {
      for (final worker in workers) {
        worker.sendPort.send(null);
        worker.isolate.kill(priority: Isolate.immediate);
      }
      await resultSub.cancel();
      results.close();
      rethrow;
    }

    return _CryptoWorkerPool._(workers, results, resultSub, jobs);
  }

  Future<List<Uint8List>> encrypt(
    Uint8List block,
    Uint8List nonce,
    Uint8List aad,
  ) {
    return _send<List<Uint8List>>([
      'encrypt',
      TransferableTypedData.fromList([block]),
      nonce,
      aad,
    ]);
  }

  Future<Uint8List> decrypt(
    Uint8List cipherText,
    Uint8List nonce,
    Uint8List macBytes,
    Uint8List aad,
  ) {
    return _send<Uint8List>([
      'decrypt',
      TransferableTypedData.fromList([cipherText]),
      nonce,
      macBytes,
      aad,
    ]);
  }

  Future<T> _send<T>(List<dynamic> message) {
    if (_isClosed) {
      return Future<T>.error(StateError('Crypto worker pool is closed.'));
    }

    final id = _nextJob++;
    final completer = Completer<T>();
    _jobs[id] = completer;
    _workers[_nextWorker].sendPort.send([id, ...message]);
    _nextWorker = (_nextWorker + 1) % _workers.length;
    return completer.future;
  }

  void close() {
    if (_isClosed) return;
    _isClosed = true;

    final closeError = StateError('Crypto worker pool is closed.');
    for (final completer in _jobs.values) {
      if (!completer.isCompleted) {
        completer.completeError(closeError);
      }
    }
    _jobs.clear();

    for (final worker in _workers) {
      worker.sendPort.send(null);
      worker.isolate.kill(priority: Isolate.immediate);
    }
    unawaited(_resultSub.cancel());
    _results.close();
  }
}

class _CryptoWorker {
  final Isolate isolate;
  final SendPort sendPort;

  const _CryptoWorker(this.isolate, this.sendPort);
}

Future<void> _cryptoWorkerMain(List<dynamic> args) async {
  final readyPort = args[0] as SendPort;
  final resultPort = args[1] as SendPort;
  final key = args[2] as Uint8List;

  late final Sodium sodium;
  late final SecureKey secureKey;
  late final ReceivePort inbox;

  try {
    sodium = await AuthenticatedStreamCryptor._loadSodium();
    secureKey = sodium.secureCopy(key);
    inbox = ReceivePort();
    readyPort.send(inbox.sendPort);
  } catch (e, stackTrace) {
    readyPort.send([false, e.toString(), stackTrace.toString()]);
    return;
  }

  try {
    await for (final message in inbox) {
      if (message == null) {
        inbox.close();
        break;
      }

      final data = message as List<dynamic>;
      final id = data[0] as int;
      final operation = data[1] as String;

      try {
        if (operation == 'encrypt') {
          final block =
              (data[2] as TransferableTypedData).materialize().asUint8List();
          final nonce = data[3] as Uint8List;
          final aad = data[4] as Uint8List;
          final parts = AuthenticatedStreamCryptor._encryptWithKey(
            sodium,
            secureKey,
            block,
            nonce,
            aad,
          );
          resultPort.send([
            id,
            true,
            'encrypt',
            parts.map((p) => TransferableTypedData.fromList([p])).toList(),
          ]);
        } else {
          final cipherText =
              (data[2] as TransferableTypedData).materialize().asUint8List();
          final nonce = data[3] as Uint8List;
          final macBytes = data[4] as Uint8List;
          final aad = data[5] as Uint8List;
          final clearText = AuthenticatedStreamCryptor._decryptWithKey(
            sodium,
            secureKey,
            cipherText,
            nonce,
            macBytes,
            aad,
          );
          resultPort.send([
            id,
            true,
            'decrypt',
            TransferableTypedData.fromList([clearText]),
          ]);
        }
      } catch (e) {
        resultPort.send([id, false, e.toString()]);
      }
    }
  } finally {
    secureKey.dispose();
  }
}
