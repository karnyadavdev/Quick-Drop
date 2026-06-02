import 'package:path/path.dart' as p;

class SafeFileName {
  static String forTransfer(String rawName, {required bool isFolder}) {
    return _safeName(rawName, isFolder: isFolder);
  }

  static String incoming(String rawName, {required bool isFolder}) {
    return _safeName(rawName, isFolder: isFolder);
  }

  static String _safeName(String rawName, {required bool isFolder}) {
    final raw = rawName.trim();
    final fallback = isFolder ? 'SharedFolder' : 'SharedFile';
    if (raw.isEmpty) return fallback;

    final slashNormalized = raw.replaceAll('\\', '/');
    final base = p.basename(slashNormalized);
    final sanitized = _stripUnsafeTrailingCharacters(
      base.replaceAll(RegExp(r'[<>:"/\\|?*\u0000-\u001F]'), '_').trim(),
    );
    if (_isUnsafeName(sanitized)) {
      return fallback;
    }

    final capped = sanitized.length > 180
        ? _stripUnsafeTrailingCharacters(sanitized.substring(0, 180))
        : sanitized;
    return _isUnsafeName(capped) ? fallback : capped;
  }

  static bool _isUnsafeName(String name) {
    return name.isEmpty ||
        name == '.' ||
        name == '..' ||
        _isReservedWindowsName(name);
  }

  static bool _isReservedWindowsName(String name) {
    final stem = p.basenameWithoutExtension(name).toUpperCase();
    return stem == 'CON' ||
        stem == 'PRN' ||
        stem == 'AUX' ||
        stem == 'NUL' ||
        RegExp(r'^COM[1-9]$').hasMatch(stem) ||
        RegExp(r'^LPT[1-9]$').hasMatch(stem);
  }

  static String _stripUnsafeTrailingCharacters(String name) {
    var result = name;
    while (result.endsWith('.') || result.endsWith(' ')) {
      result = result.substring(0, result.length - 1);
    }
    return result;
  }
}
