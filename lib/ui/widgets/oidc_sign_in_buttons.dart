import 'dart:async';

import 'package:flutter/material.dart';
import 'package:server_core/server_core.dart';

import '../../auth/models/server.dart';
import '../../auth/services/oidc_browser_navigation.dart';
import '../../auth/services/oidc_provider_service.dart';
import '../../l10n/app_localizations.dart';
import '../../util/platform_detection.dart';

typedef OidcProviderLoader = Future<List<OidcProvider>> Function(
  String baseUrl,
);
typedef OidcNavigator = bool Function(Uri uri);

/// Discovers server-provided OIDC choices and starts the browser flow in the
/// current tab. The callback writes Jellyfin credentials to this origin, which
/// Moonfin imports on its next load, so this is intentionally web-only and
/// same-origin-only. Native apps continue to use Quick Connect.
class OidcSignInButtons extends StatefulWidget {
  final Server server;
  final OidcProviderLoader? loadProviders;
  final OidcNavigator? navigate;
  final String? pageOrigin;
  final bool? webEnabled;

  const OidcSignInButtons({
    super.key,
    required this.server,
    this.loadProviders,
    this.navigate,
    this.pageOrigin,
    this.webEnabled,
  });

  @override
  State<OidcSignInButtons> createState() => _OidcSignInButtonsState();
}

class _OidcSignInButtonsState extends State<OidcSignInButtons> {
  List<OidcProvider> _providers = const [];
  String? _openingProvider;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(OidcSignInButtons oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.server.address != widget.server.address ||
        oldWidget.server.serverType != widget.server.serverType ||
        oldWidget.pageOrigin != widget.pageOrigin ||
        oldWidget.webEnabled != widget.webEnabled) {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    if (!_eligible) {
      if (mounted) setState(() => _providers = const []);
      return;
    }

    try {
      final loader =
          widget.loadProviders ?? OidcProviderService().fetchProviders;
      final providers = await loader(widget.server.address);
      if (mounted && generation == _loadGeneration) {
        setState(() => _providers = providers);
      }
    } catch (_) {
      // OIDC is an optional server capability. Leave the normal password and
      // Quick Connect UI untouched when discovery is unavailable.
      if (mounted && generation == _loadGeneration) {
        setState(() => _providers = const []);
      }
    }
  }

  bool get _eligible {
    if (!(widget.webEnabled ?? PlatformDetection.isWeb) ||
        widget.server.serverType != ServerType.jellyfin) {
      return false;
    }
    return canUseOidcWebFlow(
      serverBaseUrl: widget.server.address,
      pageOrigin: widget.pageOrigin ?? oidcBrowserPageOrigin(),
    );
  }

  void _open(OidcProvider provider) {
    if (_openingProvider != null) return;
    setState(() => _openingProvider = provider.id);
    final opened = (widget.navigate ?? openOidcInCurrentTab)(provider.startUri);
    if (opened || !mounted) return;
    setState(() => _openingProvider = null);
  }

  @override
  Widget build(BuildContext context) {
    if (_providers.isEmpty) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          for (var index = 0; index < _providers.length; index++) ...[
            if (index > 0) const SizedBox(height: 10),
            OutlinedButton.icon(
              key: ValueKey('oidc-${_providers[index].id}'),
              onPressed: _openingProvider == null
                  ? () => _open(_providers[index])
                  : null,
              icon: _openingProvider == _providers[index].id
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.login_rounded),
              label: Text(
                '${l10n.signIn} · ${_providers[index].effectiveDisplayName}',
              ),
              style: OutlinedButton.styleFrom(minimumSize: const Size(220, 48)),
            ),
          ],
        ],
      ),
    );
  }
}
