import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

void packDirectoryAsTarIsolate(Map<String, String> args) {
  final folderPath = args['folderPath']!;
  final archivePath = args['archivePath']!;

  if (Platform.isWindows && !_directoryContainsLinks(folderPath)) {
    try {
      final result = Process.runSync(
        'tar.exe',
        ['-cf', archivePath, '-C', folderPath, '.'],
      );
      if (result.exitCode == 0) return;
    } catch (_) {}
  }

  final encoder = TarFileEncoder();
  encoder.open(archivePath);
  try {
    for (final file in _filesForDirectoryArchive(folderPath)) {
      final relPath = p.relative(file.path, from: folderPath);
      encoder.addFile(file, relPath);
    }
  } finally {
    encoder.close();
  }
}

bool _directoryContainsLinks(String folderPath) {
  try {
    return Directory(folderPath)
        .listSync(recursive: true, followLinks: false)
        .any((entity) => entity is Link);
  } catch (_) {
    return true;
  }
}

List<File> _filesForDirectoryArchive(String folderPath) {
  return Directory(folderPath)
      .listSync(recursive: true, followLinks: false)
      .whereType<File>()
      .toList();
}

void packFilesAsTarIsolate(Map<String, dynamic> args) {
  final filePaths = _regularFilePaths(List<String>.from(args['filePaths']!));
  final archivePath = args['archivePath'] as String;

  if (Platform.isWindows && filePaths.isNotEmpty) {
    try {
      final firstParent =
          p.normalize(Directory(p.dirname(filePaths.first)).absolute.path);
      bool allInSameDir = true;
      final relativeNames = <String>[];
      final seenNames = <String>{};
      for (final path in filePaths) {
        final parent = p.normalize(Directory(p.dirname(path)).absolute.path);
        if (parent != firstParent) {
          allInSameDir = false;
          break;
        }
        final name = p.basename(path);
        relativeNames.add(name);
        seenNames.add(name.toLowerCase());
      }

      if (allInSameDir && seenNames.length == relativeNames.length) {
        final result = Process.runSync(
          'tar.exe',
          ['-cf', archivePath, '-C', firstParent, ...relativeNames],
        );
        if (result.exitCode == 0) {
          return;
        }
      }
    } catch (_) {}
  }

  final encoder = TarFileEncoder();
  encoder.open(archivePath);
  try {
    final archiveNames = _uniqueArchiveNames(filePaths);
    for (var i = 0; i < filePaths.length; i++) {
      encoder.addFile(File(filePaths[i]), archiveNames[i]);
    }
  } finally {
    encoder.close();
  }
}

List<String> _regularFilePaths(List<String> filePaths) {
  final regularFiles = <String>[];

  for (final path in filePaths) {
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.file) {
      regularFiles.add(path);
      continue;
    }
    if (type == FileSystemEntityType.link) {
      continue;
    }
    throw FileSystemException('Only regular files can be packed.', path);
  }

  if (regularFiles.isEmpty) {
    throw const FileSystemException('No regular files to pack.');
  }
  return regularFiles;
}

List<String> _uniqueArchiveNames(List<String> filePaths) {
  final used = <String>{};
  final names = <String>[];

  for (final filePath in filePaths) {
    final originalName = p.basename(filePath);
    final extension = p.extension(originalName);
    final stem = p.basenameWithoutExtension(originalName).isEmpty
        ? 'file'
        : p.basenameWithoutExtension(originalName);
    var candidate = originalName.isEmpty ? 'file' : originalName;
    var suffix = 2;

    while (!used.add(candidate.toLowerCase())) {
      candidate = '${stem}_$suffix$extension';
      suffix++;
    }
    names.add(candidate);
  }

  return names;
}

void extractTarArchiveIsolate(Map<String, String> args) {
  final archivePath = args['archivePath']!;
  final destPath = args['destPath']!;

  if ((Platform.isWindows || Platform.isLinux || Platform.isMacOS) &&
      _extractWithNativeTar(archivePath, destPath)) {
    return;
  }

  final inputStream = InputFileStream(archivePath);
  try {
    final archive = TarDecoder().decodeBuffer(inputStream);
    final destDir = Directory(destPath)..createSync(recursive: true);
    final canonicalDest = p.canonicalize(destDir.absolute.path);

    for (final file in archive.files) {
      if (file.isSymbolicLink) {
        throw FormatException(
            'Refusing to extract symbolic link: ${file.name}');
      }

      _validateArchivePathSegments(file.name);
      final normalizedName = p.normalize(file.name);
      if (p.isAbsolute(normalizedName)) {
        throw FormatException(
            'Refusing to extract absolute path: ${file.name}');
      }
      if (file.isFile && (normalizedName.isEmpty || normalizedName == '.')) {
        throw FormatException(
            'Refusing to extract file without a safe name: ${file.name}');
      }

      final targetPath = p.canonicalize(p.join(canonicalDest, normalizedName));
      if (targetPath != canonicalDest &&
          !p.isWithin(canonicalDest, targetPath)) {
        throw FormatException(
            'Refusing to extract path outside destination: ${file.name}');
      }

      if (!file.isFile) {
        Directory(targetPath).createSync(recursive: true);
        continue;
      }

      final parentDir = Directory(p.dirname(targetPath));
      if (!parentDir.existsSync()) {
        parentDir.createSync(recursive: true);
      }

      final output = OutputFileStream(targetPath);
      try {
        file.writeContent(output);
      } finally {
        output.closeSync();
      }
    }
  } finally {
    inputStream.close();
  }
}

bool _extractWithNativeTar(String archivePath, String destPath) {
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    try {
      final scanPathsResult = Process.runSync('tar', ['-tf', archivePath]);
      final scanTypesResult = Process.runSync('tar', ['-tvf', archivePath]);

      if (scanPathsResult.exitCode == 0 && scanTypesResult.exitCode == 0) {
        final paths = scanPathsResult.stdout
            .toString()
            .split('\n')
            .where((s) => s.trim().isNotEmpty)
            .toList();
        final types = scanTypesResult.stdout
            .toString()
            .split('\n')
            .where((s) => s.trim().isNotEmpty)
            .toList();

        if (paths.length == types.length) {
          bool isSafe = true;
          for (var i = 0; i < paths.length; i++) {
            final path = paths[i].trim();
            final typeLine = types[i].trimLeft();
            if (typeLine.isEmpty) {
              isSafe = false;
              break;
            }

            final firstChar = typeLine[0];
            // Only allow regular files ('-') or directories ('d')
            if (firstChar != '-' && firstChar != 'd') {
              isSafe = false;
              break;
            }

            final normalized = p.normalize(path).replaceAll('\\', '/');
            if (p.isAbsolute(normalized) ||
                normalized.startsWith('../') ||
                normalized == '..') {
              isSafe = false;
              break;
            }
          }

          if (isSafe) {
            final extractResult = Process.runSync(
              'tar',
              ['-xf', archivePath, '-C', destPath],
            );
            if (extractResult.exitCode == 0) return true;
          }
        }
      }
    } catch (_) {}
  }
  return false;
}

_TarListEntry? _parseTarListEntry(String line) {
  if (line.isEmpty) return null;
  final type = line.codeUnitAt(0);
  final isFile = type == 0x2d; // -
  final isDirectory = type == 0x64; // d
  if (!isFile && !isDirectory) return null;

  final match = RegExp(
    r'^\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+(.+)$',
  ).firstMatch(line);
  if (match == null) return null;

  final name = match.group(1)!.trim();
  if (name.contains(' -> ')) return null;
  return _TarListEntry(name, isFile: isFile);
}

class _TarListEntry {
  final String name;
  final bool isFile;

  const _TarListEntry(this.name, {required this.isFile});
}

void _validateArchiveEntry(
  String archiveName, {
  required bool isFile,
  required String canonicalDest,
}) {
  _validateArchivePathSegments(archiveName);
  final normalizedName = p.normalize(archiveName);
  if (p.isAbsolute(normalizedName)) {
    throw FormatException('Refusing to extract absolute path: $archiveName');
  }
  if (isFile && (normalizedName.isEmpty || normalizedName == '.')) {
    throw FormatException(
        'Refusing to extract file without a safe name: $archiveName');
  }

  final targetPath = p.canonicalize(p.join(canonicalDest, normalizedName));
  if (targetPath != canonicalDest && !p.isWithin(canonicalDest, targetPath)) {
    throw FormatException(
        'Refusing to extract path outside destination: $archiveName');
  }
}

void _validateArchivePathSegments(String archiveName) {
  final parts = archiveName.replaceAll('\\', '/').split('/');
  if (parts.isEmpty) {
    throw FormatException(
        'Refusing to extract path without a safe name: $archiveName');
  }

  for (var i = 0; i < parts.length; i++) {
    final part = parts[i];
    final isTrailingSlash = part.isEmpty && i == parts.length - 1;
    if (isTrailingSlash) {
      continue;
    }
    if (part == '.') {
      continue;
    }
    if (part.isEmpty || part == '..') {
      throw FormatException(
          'Refusing to extract unsafe path segment: $archiveName');
    }

    final trimmed = _trimUnsafeTrailingCharacters(part);
    if (trimmed.isEmpty || _isReservedWindowsName(trimmed)) {
      throw FormatException(
          'Refusing to extract unsafe path segment: $archiveName');
    }
  }
}

String _trimUnsafeTrailingCharacters(String value) {
  var result = value;
  while (result.endsWith('.') || result.endsWith(' ')) {
    result = result.substring(0, result.length - 1);
  }
  return result;
}

bool _isReservedWindowsName(String value) {
  final stem = p.basenameWithoutExtension(value).toUpperCase();
  return stem == 'CON' ||
      stem == 'PRN' ||
      stem == 'AUX' ||
      stem == 'NUL' ||
      RegExp(r'^COM[1-9]$').hasMatch(stem) ||
      RegExp(r'^LPT[1-9]$').hasMatch(stem);
}
