### Activity & Feedback

If you find this app useful, please consider **starring** the repository. 
Found a bug or have feedback? Feel free to open an **[issue](https://github.com/karnyadavdev/Quick-Drop/issues)**!

# QuickDrop

QuickDrop is a local peer-to-peer file sharing application for Windows, built with Flutter, focusing on high-speed offline transfers using native network sockets and robust cryptographic verification.

## Protocol

QuickDrop uses a custom protocol for local transfers:
1. Discovery over UDP Broadcast.
2. The sender initiates an ECDH handshake.
3. Both devices derive a shared secret using HKDF.
4. A 6-digit PIN is displayed on both screens for verification.
5. Files are streamed in 64KB blocks, encrypted using XChaCha20-Poly1305, and written directly to disk.

## Requirements

* **OS:** Windows 10 or Windows 11
* **Network:** Both devices must be connected to the same local network (Wi-Fi or Ethernet).

## Build Instructions

**Prerequisites:** Flutter SDK (Windows Setup), Visual Studio Build Tools.

```bash
flutter build windows
```

### Development Testing

To run multiple instances of QuickDrop on the same PC (e.g. for testing UI/UX), enable UDP Port sharing:
```bash
flutter run -d windows --dart-define=QUICKDROP_ALLOW_SAME_PC=true
```

## License

[MIT License](LICENSE)
