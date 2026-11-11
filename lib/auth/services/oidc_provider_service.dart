import 'package:dio/dio.dart';
import 'package:server_core/server_core.dart';

import '../../util/server_url.dart';

final _providerIdPattern = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

class OidcProvider {
  final String id;
  final String displayName;
  final String buttonColor;
  final String buttonIcon;
  final Uri startUri;

  const OidcProvider({
    required this.id,
    required this.displayName,
    required this.buttonColor,
    required this.buttonIcon,
    required this.startUri,
  });

  String get effectiveDisplayName {
    if (id.toLowerCase() == 'google') return 'Google';
    return displayName.isEmpty ? id : displayName;
  }
}

class OidcProviderService {
  final Dio _dio;

  OidcProviderService({Dio? dio}) : _dio = dio ?? Dio() {
    if (dio == null) configureServerDio(_dio);
  }

  Future<List<OidcProvider>> fetchProviders(String serverBaseUrl) async {
    final base = normalizeServerBaseUrl(serverBaseUrl);
    final baseUri = Uri.tryParse(base);
    if (baseUri == null ||
        !baseUri.hasAuthority ||
        !const {'http', 'https'}.contains(baseUri.scheme)) {
      return const [];
    }

    final response = await _dio.get<Object?>(
      '$base/sso/OIDC/Providers',
      options: Options(
        responseType: ResponseType.json,
        sendTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 5),
      ),
    );

    return parseOidcProviders(response.data, serverBaseUrl: base);
  }
}

List<OidcProvider> parseOidcProviders(
  Object? value, {
  required String serverBaseUrl,
}) {
  if (value is! List) return const [];

  final base = normalizeServerBaseUrl(serverBaseUrl);
  final baseUri = Uri.tryParse(base);
  if (baseUri == null ||
      !baseUri.hasAuthority ||
      !const {'http', 'https'}.contains(baseUri.scheme)) {
    return const [];
  }

  final providers = <OidcProvider>[];
  for (final entry in value) {
    if (entry is! Map) continue;
    final map = entry.map((key, value) => MapEntry(key.toString(), value));
    final id = _stringValue(map, 'ProviderId', 'providerId').trim();
    if (id.isEmpty || !_providerIdPattern.hasMatch(id)) continue;

    final displayName = _stringValue(map, 'DisplayName', 'displayName').trim();

    // Deliberately construct this from the known server origin. Older OIDC
    // plugin configurations can advertise an http StartUrl behind a reverse
    // proxy; following that value could downgrade credentials or leave the
    // Moonfin origin whose local storage receives the completed session.
    final startUri = Uri.parse(
      '$base/sso/OIDC/Start/${Uri.encodeComponent(id)}',
    );

    providers.add(
      OidcProvider(
        id: id,
        displayName: displayName,
        buttonColor: _stringValue(map, 'ButtonColor', 'buttonColor'),
        buttonIcon: _stringValue(map, 'ButtonIcon', 'buttonIcon'),
        startUri: startUri,
      ),
    );
  }
  return providers;
}

bool canUseOidcWebFlow({
  required String serverBaseUrl,
  required String? pageOrigin,
}) {
  if (pageOrigin == null || pageOrigin.isEmpty) return false;
  final server = Uri.tryParse(normalizeServerBaseUrl(serverBaseUrl));
  final page = Uri.tryParse(pageOrigin);
  if (server == null || page == null) return false;
  if (!server.hasAuthority || !page.hasAuthority) return false;
  if (!const {'http', 'https'}.contains(server.scheme) ||
      !const {'http', 'https'}.contains(page.scheme)) {
    return false;
  }
  return server.origin == page.origin;
}

String _stringValue(Map<String, Object?> map, String primary, String fallback) {
  final value = map[primary] ?? map[fallback];
  return value is String ? value : '';
}
