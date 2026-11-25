@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moonfin/auth/models/server.dart';
import 'package:moonfin/auth/models/server_addition_state.dart';
import 'package:moonfin/auth/repositories/server_repository.dart';
import 'package:moonfin/auth/repositories/session_repository.dart';
import 'package:moonfin/auth/services/server_discovery_service.dart';
import 'package:moonfin/auth/store/authentication_preferences.dart';
import 'package:moonfin/auth/store/authentication_store.dart';
import 'package:moonfin/data/services/media_server_client_factory.dart';
import 'package:moonfin/l10n/app_localizations.dart';
import 'package:moonfin/platform/web_runtime_config_model.dart';
import 'package:moonfin/platform/web_runtime_config_web.dart' as runtime;
import 'package:moonfin/ui/navigation/destinations.dart';
import 'package:moonfin/ui/screens/auth/server_select_screen.dart';
import 'package:moonfin_design/moonfin_design.dart';
import 'package:server_core/server_core.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web/web.dart' as web;

class _Servers extends Mock implements ServerRepository {}

class _Session extends Mock implements SessionRepository {}

class _ClientFactory extends Mock implements MediaServerClientFactory {}

class _Client extends Mock implements MediaServerClient {}

class _Users extends Mock implements UsersApi {}

class _Discovery extends Fake implements ServerDiscoveryService {
  @override
  Stream<DiscoveredServer> discoverLocalServers() => const Stream.empty();
}

void main() {
  final server = Server(
    id: 'hosted-server',
    name: 'Hosted Jellyfin',
    address: Uri.base.origin,
    version: '12.2.0',
    serverType: ServerType.jellyfin,
    dateAdded: DateTime(2026),
  );
  late _Servers servers;
  late _Session session;
  late _ClientFactory factory;
  late StreamController<ServerAdditionState> additions;
  late Completer<Server?> connection;
  late List<Server> saved;

  setUp(() async {
    await GetIt.instance.reset();
    SharedPreferences.setMockInitialValues({});
    final prefs = PreferenceStore();
    await prefs.init();
    final authStore = AuthenticationStore();
    await authStore.init();
    ThemeRegistry.setActiveById(ThemeRegistry.moonfinId);
    runtime.webRuntimeConfig = WebRuntimeConfig.fromJson({
      'pluginMode': true,
      'enableWebRtcScan': false,
    });
    web.window.localStorage.clear();
    web.window.sessionStorage.clear();

    saved = [];
    servers = _Servers();
    session = _Session();
    factory = _ClientFactory();
    additions = StreamController<ServerAdditionState>.broadcast();
    connection = Completer<Server?>();
    when(() => servers.servers).thenAnswer((_) => saved);
    when(() => servers.loadStoredServers()).thenAnswer((_) async {});
    when(() => servers.additionState).thenAnswer((_) => additions.stream);
    when(() => servers.addServer(server.address)).thenAnswer((_) async {
      additions.add(ServerConnecting(address: server.address));
      final result = await connection.future;
      if (result != null) {
        saved.add(result);
        additions.add(ServerConnected(id: result.id, publicInfo: const {}));
      }
      return result;
    });
    GetIt.instance
      ..registerSingleton<ServerRepository>(servers)
      ..registerSingleton<SessionRepository>(session)
      ..registerSingleton<MediaServerClientFactory>(factory)
      ..registerSingleton<AuthenticationStore>(authStore)
      ..registerSingleton<AuthenticationPreferences>(
        AuthenticationPreferences(prefs),
      )
      ..registerSingleton<DeviceInfo>(
        const DeviceInfo(
          id: 'test',
          name: 'Browser',
          appName: 'Moonfin',
          appVersion: '3.1.0',
        ),
      );
  });

  tearDown(() async {
    runtime.webRuntimeConfig = WebRuntimeConfig.defaults;
    web.window.localStorage.clear();
    web.window.sessionStorage.clear();
    await additions.close();
    await GetIt.instance.reset();
  });

  Future<GoRouter> open(WidgetTester tester) async {
    final router = GoRouter(
      initialLocation: Destinations.serverSelect,
      routes: [
        GoRoute(
          path: Destinations.serverSelect,
          builder: (_, _) => ServerSelectScreen(discoveryService: _Discovery()),
        ),
        GoRoute(
          path: Destinations.server,
          builder: (_, state) => Scaffold(
            body: Text('Sign in: ${state.uri.queryParameters['serverId']}'),
          ),
        ),
        GoRoute(
          path: Destinations.home,
          builder: (_, _) => const Scaffold(body: Text('Signed in')),
        ),
      ],
    );
    addTearDown(router.dispose);
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: const [Locale('en')],
      ),
    );
    await tester.pump();
    return router;
  }

  Future<void> finishConnection(WidgetTester tester, Server? result) async {
    await tester.runAsync(() async {
      connection.complete(result);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
  }

  testWidgets('a fresh browser proceeds to sign-in after adding the host', (
    tester,
  ) async {
    final router = await open(tester);
    expect(saved, isEmpty);
    await finishConnection(tester, server);
    expect(
      router.routeInformationProvider.value.uri.queryParameters['serverId'],
      server.id,
    );
    expect(find.text('Sign in: ${server.id}'), findsOneWidget);
    verify(() => servers.addServer(server.address)).called(1);
  });

  testWidgets('a saved host proceeds without adding it again', (tester) async {
    saved.add(server);
    await open(tester);
    await tester.pumpAndSettle();
    expect(find.text('Sign in: ${server.id}'), findsOneWidget);
    verifyNever(() => servers.addServer(any()));
  });

  testWidgets('a failed automatic connection displays an error', (
    tester,
  ) async {
    final router = await open(tester);
    await finishConnection(tester, null);
    expect(
      router.routeInformationProvider.value.uri.path,
      Destinations.serverSelect,
    );
    final context = tester.element(find.byType(ServerSelectScreen));
    expect(
      find.text(AppLocalizations.of(context).unableToConnectToServer),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a connection completing after leaving does not navigate', (
    tester,
  ) async {
    final router = await open(tester);
    router.go(Destinations.home);
    await tester.pumpAndSettle();
    await finishConnection(tester, server);
    expect(find.text('Signed in'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('OIDC credentials open Home before the sign-in fallback', (
    tester,
  ) async {
    final client = _Client();
    final users = _Users();
    when(
      () => factory.getClient(
        serverId: server.id,
        serverType: server.serverType,
        baseUrl: server.address,
      ),
    ).thenReturn(client);
    when(() => client.usersApi).thenReturn(users);
    when(() => users.getCurrentUser())
        .thenAnswer((_) async => const ServerUser(id: 'user', name: 'Viewer'));
    when(
      () => session.switchCurrentSession(serverId: server.id, userId: 'user'),
    ).thenAnswer((_) async => true);
    web.window.sessionStorage.setItem(
      'moonfin_bootstrap_credentials',
      jsonEncode({
        'serverAddress': server.address,
        'accessToken': 'test-token',
        'userId': 'user',
      }),
    );
    await open(tester);
    await finishConnection(tester, server);
    expect(find.text('Signed in'), findsOneWidget);
    verify(
      () => session.switchCurrentSession(serverId: server.id, userId: 'user'),
    ).called(1);
  });
}
