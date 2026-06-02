import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:cryptography/cryptography.dart';

import '../models/device.dart';
import 'archive_isolate.dart';
import 'body_limit.dart';
import 'safe_file_name.dart';
import 'session_crypto.dart';
import 'stream_cipher.dart';
import 'transfer_request.dart';

class NetworkController extends ChangeNotifier {
  final String deviceId;
  String deviceName;
  String deviceType;

  final List<NetworkDevice> _devices = [];
  List<NetworkDevice> get devices => List.unmodifiable(_devices);

  double _transferProgress = 0.0;
  double get transferProgress => _transferProgress;

  String _transferSpeed = '0 KB/s';
  String get transferSpeed => _transferSpeed;

  String _transferFileName = '';
  String get transferFileName => _transferFileName;

  int _transferFileSize = 0;
  int get transferFileSize => _transferFileSize;

  String _transferType = 'none';
  String get transferType => _transferType;

  bool _transferIsFolder = false;
  bool get transferIsFolder => _transferIsFolder;

  String _transferSenderName = '';
  String get transferSenderName => _transferSenderName;

  String _transferSenderDeviceType = 'desktop';
  String get transferSenderDeviceType => _transferSenderDeviceType;

  String _transferSecurityCode = '';
  String get transferSecurityCode => _transferSecurityCode;

  NetworkDevice? get pendingSendDevice => _pendingSendDevice;
  String get transferPeerName => _transferType == 'send'
      ? _pendingSendDevice?.name ?? ''
      : _transferSenderName;
  String get transferPeerDeviceType => _transferType == 'send'
      ? _pendingSendDevice?.deviceType ?? 'desktop'
      : _transferSenderDeviceType;

  bool get canDismiss => _canDismiss;

  SimpleKeyPair? _senderKeyPair;
  SimpleKeyPair? _receiverKeyPair;
  String? _receiverPublicKeyBase64;
  String _pendingConsentDecision = 'pending';
  Uint8List? _derivedSharedKey;
  bool _canDismiss = false;

  String? _uploadVerifyToken;

  RawDatagramSocket? _udpSocket;
  HttpServer? _httpServer;
  Timer? _broadcastTimer;
  Timer? _pruneTimer;
  Timer? _receiveWaitTimer;
  int _localHttpPort = 50005;

  static const int udpPort = 55555;
  static const int _maxHandshakeBodyBytes = 16 * 1024;
  static const Duration _presenceBroadcastInterval =
      Duration(milliseconds: 750);
  static const Duration _peerPruneInterval = Duration(milliseconds: 750);
  static const Duration _peerStaleAfter = Duration(milliseconds: 2500);
  static const Duration _receiveUploadTimeout = Duration(seconds: 30);
  static const Duration _uploadIoTimeout = Duration(seconds: 30);
  static const bool allowSamePcDiscovery =
      bool.fromEnvironment('QUICKDROP_ALLOW_SAME_PC');
  bool _isDisposed = false;

  Completer<bool>? _consentCompleter;
  NetworkDevice? _pendingSendDevice;
  File? _pendingSendFile;
  String? _incomingExpectedFileName;
  int? _incomingExpectedFileSize;
  bool? _incomingExpectedIsFolder;
  String? _incomingExpectedSenderId;
  String? _incomingExpectedSenderIp;
  String? _activeRequestSenderId;
  String? _activeRequestSenderIp;

  final Map<String, int> _declineCounts = {};
  final Map<String, int> _declineIpCounts = {};
  final Set<String> _ignoredSenders = {};
  final Set<String> _ignoredSenderIps = {};
  final List<String> _localIps = [];
  int _transferStateVersion = 0;

  NetworkController({
    required this.deviceId,
    required this.deviceName,
    this.deviceType = 'desktop',
  });

  Future<void> start() async {
    await _loadStoredProfile();
    await _resolveLocalIps();
    await _startHttpServer();
    await _startUdpDiscovery();
    _startTimers();
  }

  Future<void> _loadStoredProfile() async {
    try {
      final docDir = await getApplicationDocumentsDirectory();
      final file = File(p.join(docDir.path, 'quick_drop_profile.json'));
      if (await file.exists()) {
        final data =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        final storedName = data['name'];
        if (storedName is String) {
          deviceName = _sanitizeDeviceName(storedName);
        }
        final storedDeviceType = data['deviceType'];
        if (storedDeviceType is String) {
          deviceType = storedDeviceType;
        }
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> updateProfile(String newName, String newDeviceType) async {
    deviceName = newName;
    deviceType = newDeviceType;
    notifyListeners();
    try {
      final docDir = await getApplicationDocumentsDirectory();
      final file = File(p.join(docDir.path, 'quick_drop_profile.json'));
      await file.writeAsString(
          jsonEncode({'name': deviceName, 'deviceType': deviceType}));
    } catch (_) {}
  }


  Future<void> _resolveLocalIps() async {
    try {
      _localIps.clear();
      final interfaces = await NetworkInterface.list();
      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          _localIps.add(addr.address);
        }
      }
    } catch (_) {}
  }

  Future<void> _startHttpServer() async {
    int portAttempt = 50005;
    while (_httpServer == null && portAttempt < 50050) {
      try {
        _httpServer =
            await HttpServer.bind(InternetAddress.anyIPv4, portAttempt);
        _localHttpPort = portAttempt;
      } catch (_) {
        portAttempt++;
      }
    }

    if (_httpServer == null) {
      throw Exception('Could not bind HTTP server to any port in range.');
    }

    _httpServer!.listen(_handleHttpRequest, onError: (e) {
      if (kDebugMode) debugPrint('HTTP Server error: $e');
    });
  }

  Future<void> _handleHttpRequest(HttpRequest request) async {
    final response = request.response;

    if (request.method == 'GET' && request.uri.path == '/ping') {
      await _sendJson(response, HttpStatus.ok, _presenceJson());
      return;
    }

    if (request.method == 'GET' && request.uri.path == '/request_status') {
      final senderId = request.uri.queryParameters['id'];
      if (_activeRequestSenderId != senderId) {
        await _sendJson(response, HttpStatus.notFound, {'status': 'not_found'});
        return;
      }
      await _sendJson(
          response, HttpStatus.ok, {'status': _pendingConsentDecision});
      return;
    }

    if (request.method == 'POST' && request.uri.path == '/request') {
      if (_transferType != 'none') {
        await _sendJson(response, HttpStatus.serviceUnavailable, {
          'status': 'busy',
        });
        return;
      }

      try {
        if (request.contentLength > _maxHandshakeBodyBytes) {
          await _sendJson(response, HttpStatus.requestEntityTooLarge, {
            'status': 'too_large',
          });
          return;
        }

        final bodyStr = await BodyLimit.readUtf8(
          request,
          maxBytes: _maxHandshakeBodyBytes,
        );
        final json = jsonDecode(bodyStr) as Map<String, dynamic>;
        final transferRequest = TransferRequest.fromJson(json);
        final senderIp = request.connectionInfo?.remoteAddress.address;

        if (_ignoredSenders.contains(transferRequest.senderId) ||
            (senderIp != null && _ignoredSenderIps.contains(senderIp))) {
          await _sendJson(response, HttpStatus.forbidden, {
            'status': 'ignored',
          });
          return;
        }

        final fileName = SafeFileName.incoming(
          transferRequest.fileName,
          isFolder: transferRequest.isFolder,
        );

        final algorithm = X25519();
        _receiverKeyPair = await algorithm.newKeyPair();
        final receiverPublicKey = await _receiverKeyPair!.extractPublicKey();
        _receiverPublicKeyBase64 = base64Encode(receiverPublicKey.bytes);
        final remotePublicKey = SimplePublicKey(
          transferRequest.publicKeyBytes,
          type: KeyPairType.x25519,
        );
        final sharedSecret = await algorithm.sharedSecretKey(
          keyPair: _receiverKeyPair!,
          remotePublicKey: remotePublicKey,
        );
        _derivedSharedKey = await TransferSessionCrypto.deriveFileKey(
          sharedSecret: sharedSecret,
          senderPublicKeyBase64: transferRequest.publicKeyBase64,
          receiverPublicKeyBase64: _receiverPublicKeyBase64!,
          fileName: fileName,
          fileSize: transferRequest.fileSize,
          isFolder: transferRequest.isFolder,
        );
        _uploadVerifyToken = await TransferSessionCrypto.deriveUploadToken(
          sharedSecret: sharedSecret,
          senderPublicKeyBase64: transferRequest.publicKeyBase64,
          receiverPublicKeyBase64: _receiverPublicKeyBase64!,
          fileName: fileName,
          fileSize: transferRequest.fileSize,
          isFolder: transferRequest.isFolder,
        );
        _transferSecurityCode = await TransferSessionCrypto.deriveSecurityCode(
          sharedSecret: sharedSecret,
          senderPublicKeyBase64: transferRequest.publicKeyBase64,
          receiverPublicKeyBase64: _receiverPublicKeyBase64!,
          fileName: fileName,
          fileSize: transferRequest.fileSize,
          isFolder: transferRequest.isFolder,
        );

        _beginTransferState();
        _transferType = 'incoming_request';
        _transferFileName = fileName;
        _transferFileSize = transferRequest.fileSize;
        _transferIsFolder = transferRequest.isFolder;
        _transferSenderName = transferRequest.senderName;
        _transferSenderDeviceType = transferRequest.senderDeviceType;
        _incomingExpectedFileName = fileName;
        _incomingExpectedFileSize = transferRequest.fileSize;
        _incomingExpectedIsFolder = transferRequest.isFolder;
        _incomingExpectedSenderId = transferRequest.senderId;
        _incomingExpectedSenderIp = senderIp;
        _activeRequestSenderId = transferRequest.senderId;
        _activeRequestSenderIp = senderIp;
        _transferProgress = 0.0;
        _transferSpeed = 'Waiting...';
        _consentCompleter = Completer<bool>();
        _pendingConsentDecision = 'pending';
        notifyListeners();

        await _sendJson(response, HttpStatus.accepted, {
          'status': 'pending',
          'publicKey': _receiverPublicKeyBase64!,
        });

        _awaitConsentDecision(const Duration(minutes: 2)).then((accepted) {
          _pendingConsentDecision = accepted ? 'accepted' : 'rejected';
          if (accepted) {
            _transferType = 'receive';
            _transferSpeed = 'Connecting...';
            _startReceiveUploadTimeout();
            notifyListeners();
          } else {
            _resetTransferState();
          }
        });
      } on BodyTooLargeException {
        await _sendJson(response, HttpStatus.requestEntityTooLarge, {
          'status': 'too_large',
        });
      } catch (e) {
        if (kDebugMode) debugPrint('Handshake request handling error: $e');
        await _sendJson(response, HttpStatus.internalServerError, {
          'error': e.toString(),
        });
        _resetTransferState();
      }
      return;
    }

    if (request.method == 'POST' && request.uri.path == '/upload') {
      final verifyHeader = request.headers.value('x-verify') ?? '';

      if (_derivedSharedKey == null || _uploadVerifyToken == null) {
        await _sendJson(response, HttpStatus.unauthorized, {
          'status': 'unauthorized',
          'error': 'No negotiated key found',
        });
        return;
      }

      if (_transferType != 'receive' ||
          !TransferSessionCrypto.constantTimeEquals(
            verifyHeader,
            _uploadVerifyToken!,
          )) {
        await _sendJson(response, HttpStatus.unauthorized, {
          'status': 'unauthorized',
          'error': 'Invalid cryptographic verification'
        });
        return;
      }

      if (_incomingExpectedFileName == null ||
          _incomingExpectedFileSize == null ||
          _incomingExpectedIsFolder == null ||
          _incomingExpectedSenderId == null) {
        await _sendJson(response, HttpStatus.badRequest, {
          'status': 'invalid_request',
          'error': 'No accepted transfer metadata available',
        });
        _resetTransferState();
        return;
      }

      _cancelReceiveUploadTimeout();

      File? receivedFile;
      Directory? extractionDir;
      var receiveSucceeded = false;

      try {
        final expectedFileName = _incomingExpectedFileName!;
        final expectedFileLength = _incomingExpectedFileSize!;
        final expectedIsFolder = _incomingExpectedIsFolder!;
        final expectedSenderId = _incomingExpectedSenderId!;
        final expectedSenderIp = _incomingExpectedSenderIp;
        final uploadMetadata = UploadRequestMetadata.fromHeaders(
          encodedFileName: request.headers.value('x-file-name'),
          fileSize: request.headers.value('x-file-size'),
          isFolder: request.headers.value('x-is-folder'),
          senderId: request.headers.value('x-sender-id'),
          noncePrefix: request.headers.value('x-nonce-prefix'),
          encryptedLength: request.contentLength,
          expectedNoncePrefixLength:
              AuthenticatedStreamCryptor.noncePrefixLength,
        );
        final remoteIp = request.connectionInfo?.remoteAddress.address;
        if (uploadMetadata.fileName != expectedFileName) {
          throw Exception('Upload file name mismatch from accepted request.');
        }
        if (uploadMetadata.fileSize != expectedFileLength) {
          throw Exception('Upload file size mismatch from accepted request.');
        }
        if (uploadMetadata.isFolder != expectedIsFolder) {
          throw Exception('Upload folder flag mismatch from accepted request.');
        }
        if (uploadMetadata.senderId != expectedSenderId) {
          throw Exception('Upload sender mismatch from accepted request.');
        }
        if (expectedSenderIp != null &&
            remoteIp != null &&
            remoteIp != expectedSenderIp) {
          throw Exception('Upload source IP changed after handshake.');
        }

        final fileName = expectedFileName;
        final fileLength = expectedFileLength;
        final isFolder = expectedIsFolder;
        final expectedEncryptedLength =
            AuthenticatedStreamCryptor.encryptedLengthFor(fileLength);
        if (uploadMetadata.encryptedLength != expectedEncryptedLength) {
          throw Exception('Encrypted upload size does not match request.');
        }

        final noncePrefix = uploadMetadata.noncePrefix;

        final downloadDir = await getDownloadsDirectory();
        if (downloadDir == null) {
          throw Exception('Unable to resolve Windows Downloads folder.');
        }
        final canonicalDownloads = p.canonicalize(downloadDir.absolute.path);

        String baseName = p.basenameWithoutExtension(fileName);
        String extension = p.extension(fileName);
        String finalName = fileName;

        if (isFolder && extension.isEmpty) {
          extension = '.tar';
          finalName = '$baseName$extension';
        }

        String targetPath = p.join(downloadDir.path, finalName);
        int counter = 1;
        while (await File(targetPath).exists() ||
            (isFolder &&
                await Directory(p.join(downloadDir.path, baseName)).exists())) {
          if (isFolder) {
            baseName = '${p.basenameWithoutExtension(fileName)}_$counter';
            finalName = baseName + extension;
          } else {
            finalName =
                '${p.basenameWithoutExtension(fileName)}_$counter$extension';
          }
          targetPath = p.join(downloadDir.path, finalName);
          counter++;
        }
        final canonicalTarget = p.canonicalize(File(targetPath).absolute.path);
        if (canonicalTarget != canonicalDownloads &&
            !p.isWithin(canonicalDownloads, canonicalTarget)) {
          throw Exception('Refusing to write outside Downloads directory.');
        }

        final file = File(targetPath);
        receivedFile = file;
        final raf = await file.open(mode: FileMode.write);

        final aad = AuthenticatedStreamCryptor.metadataAad(
          fileName: fileName,
          fileSize: fileLength,
          isFolder: isFolder,
        );

        int bytesReceived = 0;
        int lastBytesReceived = 0;
        double shownSpeed = 0;
        final stopwatch = Stopwatch()..start();

        Timer? speedTimer =
            Timer.periodic(const Duration(milliseconds: 500), (timer) {
          shownSpeed = _updateShownSpeed(
            shownSpeed: shownSpeed,
            byteDelta: bytesReceived - lastBytesReceived,
            stopwatch: stopwatch,
          );
          lastBytesReceived = bytesReceived;
          _transferSpeed = _formatSpeed(shownSpeed);
          notifyListeners();
        });

        final currentVersion = _transferStateVersion;
        try {
          await for (final decryptedChunk
              in AuthenticatedStreamCryptor.streamDecrypt(
            stream: request.timeout(_receiveUploadTimeout),
            key: _derivedSharedKey!,
            noncePrefix: noncePrefix,
            aad: aad,
            isCancelled: () => _transferStateVersion != currentVersion,
          )) {
            await raf.writeFrom(decryptedChunk);
            bytesReceived += decryptedChunk.length;
            if (bytesReceived > fileLength) {
              throw Exception('Upload stream exceeded announced file size.');
            }
            if (fileLength > 0) {
              _transferProgress =
                  (bytesReceived / fileLength).clamp(0.0, 1.0).toDouble();
            }
          }
          if (bytesReceived != fileLength) {
            throw Exception(
              'Upload stream ended early. Expected $fileLength bytes, received $bytesReceived bytes.',
            );
          }
          await raf.flush();
        } finally {
          await raf.close();
          speedTimer.cancel();
          stopwatch.stop();
        }

        if (isFolder) {
          _transferSpeed = 'Extracting...';
          _transferProgress = 0.99;
          notifyListeners();

          final destPath = p.join(downloadDir.path, baseName);
          extractionDir = Directory(destPath);
          await extractionDir.create(recursive: true);

          await compute(extractTarArchiveIsolate, {
            'archivePath': file.path,
            'destPath': destPath,
          });

          await file.delete();
        }

        receiveSucceeded = true;
        await _sendJson(response, HttpStatus.ok, {'status': 'success'});

        _transferProgress = 1.0;
        _transferSpeed = 'Finished';
        notifyListeners();
      } catch (e) {
        if (kDebugMode) debugPrint('Upload handling error: $e');
        await _sendJson(response, HttpStatus.internalServerError, {
          'error': e.toString(),
        });
        if (!receiveSucceeded) {
          try {
            if (receivedFile != null && await receivedFile.exists()) {
              await receivedFile.delete();
            }
            if (extractionDir != null && await extractionDir.exists()) {
              await extractionDir.delete(recursive: true);
            }
          } catch (_) {}
        }
        _transferSpeed = 'Failed';
        notifyListeners();
      } finally {
        _resetTransferStateAfterDelay(force: true);
      }
      return;
    }

    response.statusCode = HttpStatus.notFound;
    await response.close();
  }

  Future<void> _sendJson(
    HttpResponse response,
    int statusCode,
    Map<String, dynamic> body,
  ) async {
    response.statusCode = statusCode;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
    await response.close();
  }

  void acceptTransfer() {
    final completer = _consentCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete(true);
    }
  }

  void declineTransfer() {
    final senderId = _activeRequestSenderId;
    final senderIp = _activeRequestSenderIp;
    if (senderId != null || senderIp != null) {
      _rememberDecline(senderId: senderId, senderIp: senderIp);
    }

    if (!(_consentCompleter?.isCompleted ?? true)) {
      _consentCompleter?.complete(false);
    }
    _resetTransferState();
  }

  void dismissTransfer() {
    _resetTransferState();
  }

  void cancelActiveTransfer() {
    _resetTransferState();
  }

  void _rememberDecline({String? senderId, String? senderIp}) {
    if (senderId != null) {
      final count = (_declineCounts[senderId] ?? 0) + 1;
      _declineCounts[senderId] = count;
      if (count >= 2) {
        _ignoredSenders.add(senderId);
      }
    }

    if (senderIp != null) {
      final count = (_declineIpCounts[senderIp] ?? 0) + 1;
      _declineIpCounts[senderIp] = count;
      if (count >= 2) {
        _ignoredSenderIps.add(senderIp);
      }
    }
  }

  Future<bool> _awaitConsentDecision(Duration timeout) async {
    final completer = _consentCompleter;
    if (completer == null) return false;
    final accepted = await Future.any<bool>([
      completer.future,
      Future<bool>.delayed(timeout, () => false),
    ]);
    if (!accepted && !completer.isCompleted) {
      completer.complete(false);
    }
    return accepted;
  }

  Future<void> _startUdpDiscovery() async {
    try {
      _udpSocket = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4, udpPort,
          reuseAddress: true);
      _udpSocket!.broadcastEnabled = true;

      _udpSocket!.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          final datagram = _udpSocket!.receive();
          if (datagram != null) {
            _parseDiscoveryPacket(datagram.data, datagram.address.address);
          }
        }
      });
    } catch (e) {
      if (kDebugMode) debugPrint('UDP Socket error: $e');
    }
  }

  void _parseDiscoveryPacket(Uint8List data, String senderIp) {
    try {
      final message = utf8.decode(data);
      final json = jsonDecode(message) as Map<String, dynamic>;
      final device = NetworkDevice.fromJson(json, senderIp);

      if (device.id == deviceId) return;

      if (!kDebugMode &&
          !allowSamePcDiscovery &&
          _isLocalDiscoveryAddress(senderIp)) {
        return;
      }

      final index = _devices.indexWhere((d) => d.id == device.id);
      if (index == -1) {
        _devices.add(device);
      } else {
        _devices[index] = device;
      }
      notifyListeners();
    } catch (_) {}
  }

  void _startTimers() {
    _broadcastPresence();
    _broadcastTimer =
        Timer.periodic(_presenceBroadcastInterval, (_) => _broadcastPresence());
    _pruneTimer =
        Timer.periodic(_peerPruneInterval, (_) => _pruneInactiveDevices());
  }

  void _broadcastPresence() {
    if (_udpSocket == null) return;
    try {
      final packet = jsonEncode(_presenceJson()..['port'] = _localHttpPort);
      final bytes = utf8.encode(packet);
      _udpSocket!.send(bytes, InternetAddress('255.255.255.255'), udpPort);
    } catch (_) {}
  }

  Map<String, dynamic> _presenceJson() => {
        'id': deviceId,
        'name': deviceName,
        'deviceType': deviceType,
        'status': _transferType == 'none' ? 'free' : 'busy',
      };

  void _pruneInactiveDevices() {
    final now = DateTime.now();
    final beforePruneCount = _devices.length;
    _devices.removeWhere((device) => device.isStale(now, _peerStaleAfter));
    if (_devices.length != beforePruneCount) {
      notifyListeners();
    }
  }

  bool _isLocalDiscoveryAddress(String senderIp) {
    return senderIp == '127.0.0.1' ||
        senderIp == 'localhost' ||
        _localIps.contains(senderIp);
  }

  Future<void> sendFolder(NetworkDevice device, String folderPath) async {
    await _packAndSend(
      device: device,
      displayName: p.basename(folderPath),
      tempFileName:
          '${p.basename(folderPath)}_${DateTime.now().millisecondsSinceEpoch}.tar',
      pack: (archivePath) => compute(packDirectoryAsTarIsolate, {
        'folderPath': folderPath,
        'archivePath': archivePath,
      }),
    );
  }

  Future<void> sendMultipleFiles(
      NetworkDevice device, List<String> filePaths) async {
    final timestamp =
        DateTime.now().millisecondsSinceEpoch.toString().substring(8);
    final archiveName = 'Shared_Files_$timestamp.tar';
    await _packAndSend(
      device: device,
      displayName: archiveName,
      tempFileName: archiveName,
      pack: (archivePath) => compute(packFilesAsTarIsolate, {
        'filePaths': filePaths,
        'archivePath': archivePath,
      }),
    );
  }

  Future<void> _packAndSend({
    required NetworkDevice device,
    required String displayName,
    required String tempFileName,
    required Future<void> Function(String archivePath) pack,
  }) async {
    if (_transferType != 'none') return;

    File? archiveFile;
    try {
      _beginTransferState();
      _transferFileName = displayName;
      _transferProgress = 0.0;
      _transferSpeed = 'Packaging...';
      _transferType = 'send_requesting';
      _transferIsFolder = true;
      notifyListeners();

      final tempDir = await getTemporaryDirectory();
      final archivePath = p.join(tempDir.path, tempFileName);
      archiveFile = File(archivePath);

      await pack(archivePath);

      if (!await archiveFile.exists()) {
        throw Exception('Packaging failed to generate archive.');
      }

      await _initiateSendHandshake(device, archiveFile, isFolder: true);
    } catch (e) {
      if (kDebugMode) debugPrint('Packaging error: $e');
      _transferSpeed = 'Failed';
      notifyListeners();
      _resetTransferStateAfterDelay();
    } finally {
      if (archiveFile != null) {
        await _deleteFileIfExists(archiveFile);
      }
    }
  }

  Future<void> sendFile(NetworkDevice device, File file) async {
    if (_transferType != 'none') return;
    _transferIsFolder = false;
    await _initiateSendHandshake(device, file, isFolder: false);
  }

  Future<void> _initiateSendHandshake(NetworkDevice device, File file,
      {required bool isFolder}) async {
    try {
      final fileName = SafeFileName.forTransfer(
        isFolder ? _transferFileName : p.basename(file.path),
        isFolder: isFolder,
      );
      final fileSize = await file.length();

      _beginTransferState();
      _transferFileName = fileName;
      _transferFileSize = fileSize;
      _transferIsFolder = isFolder;
      _transferProgress = 0.0;
      _transferSpeed = 'Requesting...';
      _transferType = 'send_requesting';
      notifyListeners();

      final algorithm = X25519();
      _senderKeyPair = await algorithm.newKeyPair();
      final senderPublicKey = await _senderKeyPair!.extractPublicKey();
      final senderPublicKeyBase64 = base64Encode(senderPublicKey.bytes);

      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 8);
      late final TransferResponse transferResponse;
      try {
        final uri = Uri.parse('http://${device.ip}:${device.port}/request');
        final request = await client.postUrl(uri);

        request.headers.contentType = ContentType.json;
        request.write(jsonEncode({
          'id': deviceId,
          'name': deviceName,
          'deviceType': deviceType,
          'fileName': fileName,
          'fileSize': fileSize,
          'isFolder': isFolder,
          'publicKey': senderPublicKeyBase64,
        }));

        final response = await request.close();

        if (response.statusCode == HttpStatus.serviceUnavailable) {
          _transferSpeed = 'Busy';
          _resetTransferStateAfterDelay();
          return;
        }

        if (response.statusCode == HttpStatus.forbidden) {
          _transferSpeed = 'Ignored';
          _resetTransferStateAfterDelay();
          return;
        }

        if (response.statusCode != HttpStatus.ok &&
            response.statusCode != HttpStatus.accepted) {
          throw Exception('Receiver declined connection or error');
        }

        final bodyStr = await BodyLimit.readUtf8(
          response,
          maxBytes: _maxHandshakeBodyBytes,
        );
        transferResponse = TransferResponse.fromJson(
          jsonDecode(bodyStr) as Map<String, dynamic>,
        );
      } finally {
        client.close(force: true);
      }

      if (transferResponse.status == 'accepted' ||
          transferResponse.status == 'pending') {
        final remotePublicKey = SimplePublicKey(
          transferResponse.publicKeyBytes!,
          type: KeyPairType.x25519,
        );
        final sharedSecret = await algorithm.sharedSecretKey(
          keyPair: _senderKeyPair!,
          remotePublicKey: remotePublicKey,
        );
        _derivedSharedKey = await TransferSessionCrypto.deriveFileKey(
          sharedSecret: sharedSecret,
          senderPublicKeyBase64: senderPublicKeyBase64,
          receiverPublicKeyBase64: transferResponse.publicKeyBase64!,
          fileName: fileName,
          fileSize: fileSize,
          isFolder: isFolder,
        );
        _uploadVerifyToken = await TransferSessionCrypto.deriveUploadToken(
          sharedSecret: sharedSecret,
          senderPublicKeyBase64: senderPublicKeyBase64,
          receiverPublicKeyBase64: transferResponse.publicKeyBase64!,
          fileName: fileName,
          fileSize: fileSize,
          isFolder: isFolder,
        );
        _transferSecurityCode = await TransferSessionCrypto.deriveSecurityCode(
          sharedSecret: sharedSecret,
          senderPublicKeyBase64: senderPublicKeyBase64,
          receiverPublicKeyBase64: transferResponse.publicKeyBase64!,
          fileName: fileName,
          fileSize: fileSize,
          isFolder: isFolder,
        );

        _pendingSendDevice = device;
        _pendingSendFile = file;

        notifyListeners();

        var currentStatus = transferResponse.status;
        while (currentStatus == 'pending') {
          await Future.delayed(const Duration(seconds: 1));
          if (_transferType != 'send_requesting') {
            return;
          }
          final statusClient = HttpClient()
            ..connectionTimeout = const Duration(seconds: 2);
          try {
            final uri = Uri.parse(
                'http://${device.ip}:${device.port}/request_status?id=$deviceId');
            final statusReq = await statusClient.getUrl(uri);
            final statusRes = await statusReq.close();
            if (statusRes.statusCode == HttpStatus.ok) {
              final statusBody = jsonDecode(
                  await BodyLimit.readUtf8(statusRes, maxBytes: 1024));
              currentStatus = statusBody['status'];
            }
          } catch (_) {
          } finally {
            statusClient.close(force: true);
          }
        }

        if (currentStatus == 'accepted') {
          await _startUpload();
        } else {
          _transferSpeed = 'Declined';
          _resetTransferStateAfterDelay();
        }
      } else {
        _transferSpeed = 'Declined';
        _resetTransferStateAfterDelay();
      }
    } catch (e) {
      if (kDebugMode) debugPrint('Handshake connection failed: $e');
      _transferSpeed = 'Failed';
      _resetTransferStateAfterDelay();
    }
  }

  Future<void> _startUpload() async {
    if (_pendingSendDevice == null ||
        _pendingSendFile == null ||
        _derivedSharedKey == null ||
        _uploadVerifyToken == null) return;

    final device = _pendingSendDevice!;
    final file = _pendingSendFile!;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);

    try {
      _beginTransferState();
      _transferType = 'send';
      _transferSpeed = 'Connecting...';
      notifyListeners();

      final uri = Uri.parse('http://${device.ip}:${device.port}/upload');
      final request = await client.postUrl(uri);
      final noncePrefix = AuthenticatedStreamCryptor.newNoncePrefix();

      request.headers
          .set('x-file-name', Uri.encodeComponent(_transferFileName));
      request.headers.set('x-file-size', _transferFileSize.toString());
      request.headers.set('x-is-folder', _transferIsFolder ? 'true' : 'false');
      request.headers.set('x-sender-id', deviceId);
      request.headers.set('x-verify', _uploadVerifyToken!);
      request.headers.set('x-nonce-prefix', base64Encode(noncePrefix));
      request.headers.contentType = ContentType.binary;
      request.bufferOutput = false;
      request.persistentConnection = false;
      request.contentLength =
          AuthenticatedStreamCryptor.encryptedLengthFor(_transferFileSize);

      final fileStream = _readFileInChunks(
        file,
        AuthenticatedStreamCryptor.chunkSize,
      );
      int bytesSent = 0;
      int lastBytesSent = 0;
      double shownSpeed = 0;

      final stopwatch = Stopwatch()..start();
      Timer? speedTimer =
          Timer.periodic(const Duration(milliseconds: 500), (timer) {
        shownSpeed = _updateShownSpeed(
          shownSpeed: shownSpeed,
          byteDelta: bytesSent - lastBytesSent,
          stopwatch: stopwatch,
        );
        lastBytesSent = bytesSent;
        _transferSpeed = _formatSpeed(shownSpeed);
        notifyListeners();
      });

      try {
        final currentVersion = _transferStateVersion;
        await AuthenticatedStreamCryptor.streamEncryptAndWrite(
          stream: fileStream,
          request: request,
          key: _derivedSharedKey!,
          noncePrefix: noncePrefix,
          aad: AuthenticatedStreamCryptor.metadataAad(
            fileName: _transferFileName,
            fileSize: _transferFileSize,
            isFolder: _transferIsFolder,
          ),
          writeTimeout: _uploadIoTimeout,
          isCancelled: () => _transferStateVersion != currentVersion,
          onProgress: (int chunkLen) {
            bytesSent += chunkLen;
            if (_transferFileSize > 0) {
              _transferProgress =
                  (bytesSent / _transferFileSize).clamp(0.0, 0.99).toDouble();
            }
            notifyListeners();
          },
        );

        speedTimer.cancel();
        _transferSpeed = 'Finishing...';
        notifyListeners();

        final response = await request.close().timeout(_uploadIoTimeout);
        final bodyStr = await BodyLimit.readUtf8(
          response.timeout(_uploadIoTimeout),
          maxBytes: _maxHandshakeBodyBytes,
        );
        var uploadSucceeded = false;
        if (response.statusCode == HttpStatus.ok) {
          UploadResult.fromJson(jsonDecode(bodyStr) as Map<String, dynamic>);
          uploadSucceeded = true;
        }
        if (uploadSucceeded) {
          _transferProgress = 1.0;
          _transferSpeed = 'Finished';
        } else {
          _transferSpeed = 'Failed';
        }
      } finally {
        speedTimer.cancel();
        stopwatch.stop();
      }
    } catch (e) {
      if (kDebugMode) debugPrint('Client streaming failed: $e');
      _transferSpeed = 'Failed';
    } finally {
      client.close(force: true);

      _resetTransferStateAfterDelay();
    }
  }

  Stream<List<int>> _readFileInChunks(File file, int chunkSize) async* {
    final raf = await file.open(mode: FileMode.read);
    try {
      while (true) {
        final bytes = await raf.read(chunkSize);
        if (bytes.isEmpty) break;
        yield bytes;
      }
    } finally {
      await raf.close();
    }
  }

  Future<void> _deleteFileIfExists(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }

  void _beginTransferState() {
    _transferStateVersion++;
  }

  void _startReceiveUploadTimeout() {
    _cancelReceiveUploadTimeout();
    final version = _transferStateVersion;
    _receiveWaitTimer = Timer(_receiveUploadTimeout, () {
      if (_isDisposed ||
          version != _transferStateVersion ||
          _transferType != 'receive') {
        return;
      }
      _transferSpeed = 'Failed';
      notifyListeners();
      _resetTransferStateAfterDelay(force: true);
    });
  }

  void _cancelReceiveUploadTimeout() {
    _receiveWaitTimer?.cancel();
    _receiveWaitTimer = null;
  }

  void _resetTransferState() {
    _transferStateVersion++;
    _cancelReceiveUploadTimeout();
    _canDismiss = false;
    _transferType = 'none';
    _transferProgress = 0.0;
    _transferSpeed = '0 KB/s';
    _transferFileName = '';
    _transferFileSize = 0;
    _transferIsFolder = false;
    _transferSenderName = '';
    _transferSenderDeviceType = 'desktop';
    _transferSecurityCode = '';
    _consentCompleter = null;
    _pendingSendDevice = null;
    _pendingSendFile = null;
    _senderKeyPair = null;
    _receiverKeyPair = null;
    _receiverPublicKeyBase64 = null;
    _derivedSharedKey = null;
    _uploadVerifyToken = null;
    _incomingExpectedFileName = null;
    _incomingExpectedFileSize = null;
    _incomingExpectedIsFolder = null;
    _incomingExpectedSenderId = null;
    _incomingExpectedSenderIp = null;
    _activeRequestSenderId = null;
    _activeRequestSenderIp = null;
    notifyListeners();
  }

  void _resetTransferStateAfterDelay({bool force = false}) {
    final version = _transferStateVersion;
    _canDismiss = false;

    Future.delayed(const Duration(seconds: 3), () {
      if (!_isDisposed && version == _transferStateVersion) {
        _canDismiss = true;
        notifyListeners();
      }
    });

    Future.delayed(const Duration(seconds: 7), () {
      if (!_isDisposed &&
          version == _transferStateVersion &&
          (force ||
              _transferType == 'send' ||
              _transferType == 'send_requesting' ||
              _transferSpeed == 'Failed' ||
              _transferSpeed == 'Declined' ||
              _transferSpeed == 'Ignored' ||
              _transferSpeed == 'Busy' ||
              _transferSpeed == 'Finished')) {
        _resetTransferState();
      }
    });
  }

  String _formatSpeed(double bytesPerSecond) {
    if (bytesPerSecond >= 1024 * 1024) {
      return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s';
    } else if (bytesPerSecond >= 1024) {
      return '${(bytesPerSecond / 1024).toStringAsFixed(0)} KB/s';
    } else {
      return '${bytesPerSecond.toStringAsFixed(0)} B/s';
    }
  }

  double _updateShownSpeed({
    required double shownSpeed,
    required int byteDelta,
    required Stopwatch stopwatch,
  }) {
    final seconds = stopwatch.elapsedMilliseconds / 1000.0;
    stopwatch.reset();
    stopwatch.start();
    if (seconds <= 0 || byteDelta <= 0) return shownSpeed;

    return byteDelta / seconds;
  }

  String _sanitizeDeviceName(String rawName) {
    final normalized = rawName.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.isEmpty) return 'Windows PC';
    return normalized.length > 15 ? normalized.substring(0, 15) : normalized;
  }

  @override
  void dispose() {
    _isDisposed = true;
    _broadcastTimer?.cancel();
    _pruneTimer?.cancel();
    _cancelReceiveUploadTimeout();
    _udpSocket?.close();
    _httpServer?.close(force: true);
    super.dispose();
  }
}
