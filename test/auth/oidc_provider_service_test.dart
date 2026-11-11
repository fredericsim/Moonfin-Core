import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/auth/services/oidc_provider_service.dart';

class _OidcAdapter implements HttpClientAdapter {
  RequestOptions? request;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    request = options;
    return ResponseBody.fromString(
      jsonEncode([
        {
          'ProviderId': 'google',
          'DisplayName': 'google',
          'ButtonColor': '#4285f4',
          'StartUrl': 'http://media.example.test/sso/OIDC/Start/google',
        },
      ]),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  group('parseOidcProviders', () {
    test('uses the configured server instead of an advertised start URL', () {
      final providers = parseOidcProviders([
        {
          'ProviderId': 'google',
          'DisplayName': 'google',
          'ButtonColor': '#4285f4',
          'ButtonIcon': '',
          'StartUrl': 'http://attacker.example/start',
        },
      ], serverBaseUrl: 'https://media.example.com/jellyfin/');

      expect(providers, hasLength(1));
      expect(providers.single.effectiveDisplayName, 'Google');
      expect(
        providers.single.startUri,
        Uri.parse('https://media.example.com/jellyfin/sso/OIDC/Start/google'),
      );
    });

    test('accepts lowercase response keys and rejects unsafe IDs', () {
      final providers = parseOidcProviders([
        {'providerId': 'work_login', 'displayName': 'Work'},
        {'ProviderId': '../elsewhere', 'DisplayName': 'Unsafe'},
        {'ProviderId': 'with/slash', 'DisplayName': 'Unsafe'},
        {'ProviderId': List.filled(65, 'a').join(), 'DisplayName': 'Too long'},
        {'ProviderId': '', 'DisplayName': 'Empty'},
      ], serverBaseUrl: 'https://media.example.com');

      expect(providers, hasLength(1));
      expect(providers.single.id, 'work_login');
      expect(providers.single.effectiveDisplayName, 'Work');
    });

    test('rejects non-http server addresses', () {
      expect(
        parseOidcProviders([
          {'ProviderId': 'google'},
        ], serverBaseUrl: 'file:///tmp/server'),
        isEmpty,
      );
    });
  });

  group('canUseOidcWebFlow', () {
    test('requires Moonfin and Jellyfin to share an origin', () {
      expect(
        canUseOidcWebFlow(
          serverBaseUrl: 'https://media.example.com/jellyfin',
          pageOrigin: 'https://media.example.com',
        ),
        isTrue,
      );
      expect(
        canUseOidcWebFlow(
          serverBaseUrl: 'https://jellyfin.example.com',
          pageOrigin: 'https://moonfin.example.com',
        ),
        isFalse,
      );
      expect(
        canUseOidcWebFlow(
          serverBaseUrl: 'https://media.example.com',
          pageOrigin: null,
        ),
        isFalse,
      );
    });
  });

  test(
    'fetches the public provider endpoint under a server base path',
    () async {
      final adapter = _OidcAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final providers = await OidcProviderService(dio: dio)
          .fetchProviders('https://media.example.test/jellyfin/');

      expect(
        adapter.request?.uri.toString(),
        'https://media.example.test/jellyfin/sso/OIDC/Providers',
      );
      expect(
        providers.single.startUri.toString(),
        'https://media.example.test/jellyfin/sso/OIDC/Start/google',
      );
    },
  );
}
