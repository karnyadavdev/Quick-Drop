import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:quick_drop/network/archive_isolate.dart';

void main() {
  group('TAR archive helpers', () {
    test('packs and extracts a folder', () async {
      final tempDir = await Directory.systemTemp.createTemp('quick_drop_tar_');
      addTearDown(() => tempDir.delete(recursive: true));

      final sourceDir = Directory(p.join(tempDir.path, 'source'));
      final nestedDir = Directory(p.join(sourceDir.path, 'nested'));
      await nestedDir.create(recursive: true);
      await File(p.join(sourceDir.path, 'hello.txt')).writeAsString('hello');
      await File(p.join(nestedDir.path, 'note.txt')).writeAsString('nested');

      final archivePath = p.join(tempDir.path, 'folder.tar');
      final outputDir = p.join(tempDir.path, 'output');

      packDirectoryAsTarIsolate({
        'folderPath': sourceDir.path,
        'archivePath': archivePath,
      });
      extractTarArchiveIsolate({
        'archivePath': archivePath,
        'destPath': outputDir,
      });

      expect(
          await File(p.join(outputDir, 'hello.txt')).readAsString(), 'hello');
      expect(
        await File(p.join(outputDir, 'nested', 'note.txt')).readAsString(),
        'nested',
      );
    });

    test('keeps duplicate multi-file names instead of overwriting', () async {
      final tempDir =
          await Directory.systemTemp.createTemp('quick_drop_multi_tar_');
      addTearDown(() => tempDir.delete(recursive: true));

      final firstDir = Directory(p.join(tempDir.path, 'first'));
      final secondDir = Directory(p.join(tempDir.path, 'second'));
      await firstDir.create(recursive: true);
      await secondDir.create(recursive: true);
      final firstFile = File(p.join(firstDir.path, 'note.txt'));
      final secondFile = File(p.join(secondDir.path, 'note.txt'));
      await firstFile.writeAsString('first');
      await secondFile.writeAsString('second');

      final archivePath = p.join(tempDir.path, 'files.tar');
      final outputDir = p.join(tempDir.path, 'output');

      packFilesAsTarIsolate({
        'filePaths': [firstFile.path, secondFile.path],
        'archivePath': archivePath,
      });
      extractTarArchiveIsolate({
        'archivePath': archivePath,
        'destPath': outputDir,
      });

      expect(await File(p.join(outputDir, 'note.txt')).readAsString(), 'first');
      expect(
        await File(p.join(outputDir, 'note_2.txt')).readAsString(),
        'second',
      );
    });

    test('does not follow links while packing a folder', () async {
      final tempDir =
          await Directory.systemTemp.createTemp('quick_drop_link_tar_');
      addTearDown(() => tempDir.delete(recursive: true));

      final sourceDir = Directory(p.join(tempDir.path, 'source'));
      final outsideDir = Directory(p.join(tempDir.path, 'outside'));
      await sourceDir.create(recursive: true);
      await outsideDir.create(recursive: true);
      await File(p.join(sourceDir.path, 'inside.txt')).writeAsString('inside');
      final outsideFile = File(p.join(outsideDir.path, 'private.txt'));
      await outsideFile.writeAsString('private');

      final link = Link(p.join(sourceDir.path, 'linked-private.txt'));
      try {
        await link.create(outsideFile.path);
      } on FileSystemException {
        markTestSkipped('This system does not allow symlink creation.');
        return;
      }

      final archivePath = p.join(tempDir.path, 'folder.tar');
      final outputDir = p.join(tempDir.path, 'output');

      packDirectoryAsTarIsolate({
        'folderPath': sourceDir.path,
        'archivePath': archivePath,
      });
      extractTarArchiveIsolate({
        'archivePath': archivePath,
        'destPath': outputDir,
      });

      expect(
        await File(p.join(outputDir, 'inside.txt')).readAsString(),
        'inside',
      );
      expect(
        await File(p.join(outputDir, 'linked-private.txt')).exists(),
        isFalse,
      );
    });

    test('does not follow links while packing multiple files', () async {
      final tempDir =
          await Directory.systemTemp.createTemp('quick_drop_multi_link_tar_');
      addTearDown(() => tempDir.delete(recursive: true));

      final selectedDir = Directory(p.join(tempDir.path, 'selected'));
      final outsideDir = Directory(p.join(tempDir.path, 'outside'));
      await selectedDir.create(recursive: true);
      await outsideDir.create(recursive: true);
      final visibleFile = File(p.join(selectedDir.path, 'visible.txt'));
      await visibleFile.writeAsString('visible');
      final outsideFile = File(p.join(outsideDir.path, 'private.txt'));
      await outsideFile.writeAsString('private');

      final link = Link(p.join(selectedDir.path, 'linked-private.txt'));
      try {
        await link.create(outsideFile.path);
      } on FileSystemException {
        markTestSkipped('This system does not allow symlink creation.');
        return;
      }

      final archivePath = p.join(tempDir.path, 'files.tar');
      final outputDir = p.join(tempDir.path, 'output');

      packFilesAsTarIsolate({
        'filePaths': [visibleFile.path, link.path],
        'archivePath': archivePath,
      });
      extractTarArchiveIsolate({
        'archivePath': archivePath,
        'destPath': outputDir,
      });

      expect(
        await File(p.join(outputDir, 'visible.txt')).readAsString(),
        'visible',
      );
      expect(
        await File(p.join(outputDir, 'linked-private.txt')).exists(),
        isFalse,
      );
    });

    test('rejects archive entries that escape the destination', () async {
      final tempDir =
          await Directory.systemTemp.createTemp('quick_drop_bad_tar_');
      addTearDown(() => tempDir.delete(recursive: true));

      final archive = Archive()
        ..addFile(
          ArchiveFile(
            '../outside.txt',
            7,
            utf8.encode('outside'),
          ),
        );
      final archivePath = p.join(tempDir.path, 'bad.tar');
      await File(archivePath).writeAsBytes(TarEncoder().encode(archive));

      expect(
        () => extractTarArchiveIsolate({
          'archivePath': archivePath,
          'destPath': p.join(tempDir.path, 'output'),
        }),
        throwsFormatException,
      );
      expect(await File(p.join(tempDir.path, 'outside.txt')).exists(), isFalse);
    });

    test('rejects archive entries with parent path segments', () async {
      final tempDir =
          await Directory.systemTemp.createTemp('quick_drop_parent_tar_');
      addTearDown(() => tempDir.delete(recursive: true));

      final archive = Archive()
        ..addFile(
          ArchiveFile(
            'nested/../outside.txt',
            7,
            utf8.encode('outside'),
          ),
        );
      final archivePath = p.join(tempDir.path, 'parent.tar');
      await File(archivePath).writeAsBytes(TarEncoder().encode(archive));

      expect(
        () => extractTarArchiveIsolate({
          'archivePath': archivePath,
          'destPath': p.join(tempDir.path, 'output'),
        }),
        throwsFormatException,
      );
    });

    test('rejects archive entries with Windows reserved names', () async {
      final tempDir =
          await Directory.systemTemp.createTemp('quick_drop_reserved_tar_');
      addTearDown(() => tempDir.delete(recursive: true));

      final archive = Archive()
        ..addFile(
          ArchiveFile(
            'NUL.txt',
            4,
            utf8.encode('data'),
          ),
        );
      final archivePath = p.join(tempDir.path, 'reserved.tar');
      await File(archivePath).writeAsBytes(TarEncoder().encode(archive));

      expect(
        () => extractTarArchiveIsolate({
          'archivePath': archivePath,
          'destPath': p.join(tempDir.path, 'output'),
        }),
        throwsFormatException,
      );
    });

    test('rejects archive file entries without a safe file name', () async {
      final tempDir =
          await Directory.systemTemp.createTemp('quick_drop_dot_tar_');
      addTearDown(() => tempDir.delete(recursive: true));

      final archive = Archive()
        ..addFile(
          ArchiveFile(
            '.',
            4,
            utf8.encode('data'),
          ),
        );
      final archivePath = p.join(tempDir.path, 'dot.tar');
      await File(archivePath).writeAsBytes(TarEncoder().encode(archive));

      expect(
        () => extractTarArchiveIsolate({
          'archivePath': archivePath,
          'destPath': p.join(tempDir.path, 'output'),
        }),
        throwsFormatException,
      );
    });
  });
}
