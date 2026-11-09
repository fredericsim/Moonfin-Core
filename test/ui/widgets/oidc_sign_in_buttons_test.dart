import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/auth/models/server.dart';
import 'package:moonfin/auth/services/oidc_provider_service.dart';
import 'package:moonfin/l10n/app_localizations.dart';
import 'package:moonfin/ui/widgets/oidc_sign_in_buttons.dart';
import 'package:server_core/server_core.dart';

Server _server({ServerType type = ServerType.jellyfin}) => Server(
  id: 'server',
  name: 'Fredflix',
  address: 'https://movie.sopolak.com',
  version: '12.2.0',
  serverType: type,
  dateAdded: DateTime(2026),
);

OidcProvider _google() => OidcProvider(
  id: 'google',
  displayName: 'google',
  buttonColor: '#4285f4',
  buttonIcon: '',
  startUri: Uri.parse('https://movie.sopolak.com/sso/OIDC/Start/google'),
);

Widget _app(Widget child) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: const [Locale('en')],
  home: Scaffold(body: Center(child: child)),
);

void main() {
  testWidgets('shows Google and navigates in the current tab', (tester) async {
    Uri? opened;
    await tester.pumpWidget(
      _app(
        OidcSignInButtons(
          server: _server(),
          webEnabled: true,
          pageOrigin: 'https://movie.sopolak.com',
          loadProviders: (_) async => [_google()],
          navigate: (uri) {
            opened = uri;
            return true;
          },
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Sign In · Google'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('oidc-google')));
    expect(
      opened,
      Uri.parse('https://movie.sopolak.com/sso/OIDC/Start/google'),
    );
  });

  testWidgets(
    'does not query providers outside a same-origin Jellyfin web app',
    (tester) async {
      var calls = 0;
      Future<List<OidcProvider>> loader(String _) async {
        calls++;
        return [_google()];
      }

      await tester.pumpWidget(
        _app(
          OidcSignInButtons(
            server: _server(),
            webEnabled: true,
            pageOrigin: 'https://other.example.com',
            loadProviders: loader,
          ),
        ),
      );
      await tester.pump();
      expect(calls, 0);
      expect(find.byKey(const ValueKey('oidc-google')), findsNothing);

      await tester.pumpWidget(
        _app(
          OidcSignInButtons(
            server: _server(type: ServerType.plex),
            webEnabled: true,
            pageOrigin: 'https://movie.sopolak.com',
            loadProviders: loader,
          ),
        ),
      );
      await tester.pump();
      expect(calls, 0);
    },
  );

  testWidgets('keeps native sign-in unchanged', (tester) async {
    var called = false;
    await tester.pumpWidget(
      _app(
        OidcSignInButtons(
          server: _server(),
          webEnabled: false,
          pageOrigin: 'https://movie.sopolak.com',
          loadProviders: (_) async {
            called = true;
            return [_google()];
          },
        ),
      ),
    );
    await tester.pump();

    expect(called, isFalse);
    expect(find.byKey(const ValueKey('oidc-google')), findsNothing);
  });
}
