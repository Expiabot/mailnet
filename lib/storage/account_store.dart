import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// What we need to log back in without asking again.
class SavedAccount {
  const SavedAccount({
    required this.providerId,
    required this.host,
    required this.port,
    required this.email,
    required this.password,
  });

  final String providerId;
  final String host;
  final int port;
  final String email;
  final String password;

  Map<String, dynamic> toJson() => {
        'providerId': providerId,
        'host': host,
        'port': port,
        'email': email,
        'password': password,
      };

  static SavedAccount fromJson(Map<String, dynamic> json) => SavedAccount(
        providerId: json['providerId'] as String? ?? 'other',
        host: json['host'] as String? ?? '',
        port: json['port'] as int? ?? 993,
        email: json['email'] as String? ?? '',
        password: json['password'] as String? ?? '',
      );
}

/// Credentials live in the Android Keystore / iOS Keychain, never in plain
/// preferences and never on our side of the network.
class AccountStore {
  AccountStore([FlutterSecureStorage? storage])
      : _storage = storage ??
            const FlutterSecureStorage(
              // v11's defaults are already AES-GCM with RSA key wrapping in the
              // Keystore. On iOS, first_unlock_this_device keeps the password
              // off iCloud Keychain — it must never leave the handset.
              aOptions: AndroidOptions(),
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
              ),
            );

  static const _key = 'mailnet.account';

  final FlutterSecureStorage _storage;

  Future<SavedAccount?> read() async {
    try {
      final raw = await _storage.read(key: _key);
      if (raw == null) return null;
      return SavedAccount.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      // A corrupt or unreadable entry must not block the login screen.
      return null;
    }
  }

  Future<void> save(SavedAccount account) async {
    try {
      await _storage.write(key: _key, value: jsonEncode(account.toJson()));
    } catch (_) {
      // Worst case the user types the password again next time.
    }
  }

  Future<void> clear() async {
    try {
      await _storage.delete(key: _key);
    } catch (_) {
      // nothing useful to do
    }
  }
}
