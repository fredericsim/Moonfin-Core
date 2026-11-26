import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:server_core/server_core.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:moonfin/auth/models/server.dart';
import 'package:moonfin/data/repositories/multi_server_repository.dart';
import 'package:moonfin/data/models/aggregated_library.dart';
import 'package:moonfin/l10n/app_localizations_en.dart';
import 'package:moonfin/ui/widgets/nav_styles/atlas_panel.dart';
import 'package:moonfin/data/services/background_service.dart';
import 'package:moonfin/data/services/media_server_client_factory.dart';
import 'package:moonfin/l10n/app_localizations.dart';
import 'package:moonfin/preference/user_preferences.dart';
import 'package:moonfin/ui/screens/browse/library_genres_screen.dart';
import 'package:moonfin/ui/widgets/genre_grid_card.dart';

class _GenresApi implements ItemsApi {
  _GenresApi(this.serverId, this.genres);
  final String serverId;
  final Map<String, int> genres;
  bool fails = false;
  bool failsArtwork = false;
  bool reportsCounts = true;
  final itemCalls = <Map<Symbol, dynamic>>[];
  final calls = <({Symbol method, String? parent, List<String>? genres})>[];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final method = invocation.memberName;
    final parent =
        (method == #getItem
                ? invocation.positionalArguments.first
                : invocation.namedArguments[#parentId])
            as String?;
    calls.add((
      method: method,
      parent: parent,
      genres: invocation.namedArguments[#genreIds] as List<String>?,
    ));
    if (method == #getItems) itemCalls.add(invocation.namedArguments);
    if (parent?.startsWith('merged-') == true ||
        fails ||
        (method == #getItems && failsArtwork)) {
      return Future<Map<String, dynamic>>.error(
        StateError('not a real library'),
      );
    }
    if (method == #getItem) {
      return Future.value(<String, dynamic>{
        'Name': 'Real',
        'CollectionType': 'movies',
      });
    }
    if (method == #getGenres) {
      return Future.value(<String, dynamic>{
        'Items': [
          for (final entry in genres.entries)
            {
              'Id': '$serverId-${entry.key}',
              'Name': entry.key,
              if (reportsCounts) 'ChildCount': entry.value,
            },
        ],
      });
    }
    if (method == #getItems) {
      final genre =
          (invocation.namedArguments[#genreIds] as List<String>?)?.single;
      final name = genre?.substring(serverId.length + 1);
      final count = genres[name] ?? 0;
      return Future.value(<String, dynamic>{
        'TotalRecordCount': count,
        'Items': [
          if (count > 0 && invocation.namedArguments[#limit] != 0)
            {'Id': '$serverId-sample', 'Type': 'Movie'},
        ],
      });
    }
    return super.noSuchMethod(invocation);
  }
}

class _Images extends Fake implements ImageApi {}

class _Client extends Fake implements MediaServerClient {
  _Client(this.itemsApi);
  @override
  final _GenresApi itemsApi;
  @override
  String get baseUrl => 'http://${itemsApi.serverId}';
  @override
  String? get userId => 'user';
  @override
  ImageApi get imageApi => _Images();
}

class _Factory extends Fake implements MediaServerClientFactory {
  _Factory(this.clients);
  @override
  final Map<String, MediaServerClient> clients;
  @override
  MediaServerClient clientForServerOrActive(String? serverId) =>
      clients[serverId] ?? clients.values.first;
}

class _Merged extends Fake implements MultiServerRepository {
  _Merged(this.sources);
  final List<MergedLibrarySource> sources;
  @override
  Future<MergedLibrary> mergedLibrary(String type) async =>
      (name: 'Merged $type', sources: sources, complete: true);
}

void main() {
  late _GenresApi a;
  late _GenresApi b;
  late BackgroundService background;
  late _Factory factory;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final store = PreferenceStore();
    await store.init();
    GetIt.instance.registerSingleton<UserPreferences>(UserPreferences(store));
    background = BackgroundService();
    GetIt.instance.registerSingleton<BackgroundService>(background);
    a = _GenresApi('a', {'Action': 2, 'Drama': 1});
    b = _GenresApi('b', {'Action': 3, 'Comedy': 4});
    factory = _Factory({'a': _Client(a), 'b': _Client(b)});
    GetIt.instance.registerSingleton<MediaServerClient>(factory.clients['a']!);
    GetIt.instance.registerSingleton<MediaServerClientFactory>(factory);
    GetIt.instance.registerSingleton<MultiServerRepository>(
      _Merged([
        for (final entry in factory.clients.entries)
          (
            session: ServerUserSession(
              server: Server(
                id: entry.key,
                name: entry.key,
                address: entry.value.baseUrl,
                version: '1',
                serverType: ServerType.jellyfin,
                dateAdded: DateTime(2026),
              ),
              userId: 'user',
              client: entry.value,
            ),
            libraryId: 'real-${entry.key}',
          ),
      ]),
    );
  });

  tearDown(() async {
    background.dispose();
    await GetIt.instance.reset();
  });

  Future<GoRouter> mount(
    WidgetTester tester,
    String library, {
    String? location,
  }) async {
    final router = GoRouter(
      initialLocation: location ?? '/library/$library/genres',
      routes: [
        GoRoute(
          path: '/library/:libraryId/genres',
          builder: (_, state) => LibraryGenresScreen(
            libraryId: state.pathParameters['libraryId']!,
            serverId: state.uri.queryParameters['serverId'],
          ),
        ),
        GoRoute(
          path: '/genre/:genreName',
          builder: (_, state) => Text(state.uri.toString()),
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: const [Locale('en')],
      ),
    );
    await tester.pumpAndSettle();
    return router;
  }

  for (final type in ['movies', 'tvshows']) {
    testWidgets('merged $type aggregates real sources and opens a genre', (
      tester,
    ) async {
      final router = await mount(tester, 'merged-$type');
      final cards = tester
          .widgetList<GenreGridCard>(find.byType(GenreGridCard))
          .map((card) => card.genre)
          .toList();
      expect(cards.map((card) => card.name), ['Action', 'Comedy', 'Drama']);
      expect(cards.first.itemCount, 5);
      for (final api in [a, b]) {
        expect(api.calls, isNotEmpty);
        expect(
          api.calls.map((call) => call.parent),
          everyElement('real-${api.serverId}'),
        );
        final queries = api.calls.where((call) => call.method == #getItems);
        expect(queries, isNotEmpty);
        expect(
          queries.every(
            (call) =>
                call.genres!.every((id) => id.startsWith('${api.serverId}-')),
          ),
          isTrue,
        );
      }
      await tester.tap(find.text('Action'));
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/genre/Action');
      expect(router.state.uri.queryParameters['parentId'], 'merged-$type');
      expect(
        router.state.uri.queryParameters['includeType'],
        type == 'movies' ? 'Movie' : 'Series',
      );
      await tester.pumpWidget(const SizedBox());
      router.dispose();
    });
  }

  testWidgets('grouping recounts merged genres inside each real source', (
    tester,
  ) async {
    final router = await mount(tester, 'merged-movies');
    await GetIt.instance<UserPreferences>().set(
      UserPreferences.groupItemsIntoCollections,
      true,
    );
    await tester.pumpAndSettle();
    for (final api in [a, b]) {
      expect(api.itemCalls.last[#collapseBoxSetItems], isTrue);
      expect(api.itemCalls.last[#includeItemTypes], ['Movie', 'BoxSet']);
      expect(api.itemCalls.last[#parentId], 'real-${api.serverId}');
    }
    final action = tester
        .widgetList<GenreGridCard>(find.byType(GenreGridCard))
        .singleWhere((card) => card.genre.name == 'Action');
    expect(action.genre.itemCount, 5);
    await tester.pumpWidget(const SizedBox());
    router.dispose();
  });

  testWidgets(
    'unreported counts and unavailable artwork do not hide merged genres',
    (tester) async {
      for (final api in [a, b]) {
        api.reportsCounts = false;
        api.failsArtwork = true;
      }
      final router = await mount(tester, 'merged-movies');
      expect(find.text('Action'), findsOneWidget);
      expect(find.text('Comedy'), findsOneWidget);
      expect(find.text('Drama'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      router.dispose();
    },
  );

  testWidgets('ordinary library genre browsing retains its server scope', (
    tester,
  ) async {
    final router = await mount(tester, 'real-a');
    expect(find.text('Action'), findsOneWidget);
    expect(find.text('Drama'), findsOneWidget);
    expect(b.calls, isEmpty);
    expect(a.calls.map((call) => call.parent), everyElement('real-a'));
    await tester.pumpWidget(const SizedBox());
    router.dispose();
  });

  testWidgets('Atlas secondary-library genres keep their source server', (
    tester,
  ) async {
    final link = atlasLibraryLinks(
      AppLocalizationsEn(),
      AggregatedLibrary(
        id: 'real-b',
        name: 'Secondary',
        collectionType: 'movies',
        serverId: 'b',
      ),
    )[1];
    final router = await mount(tester, 'real-b', location: link.route);
    expect(a.calls, isEmpty);
    expect(b.calls, isNotEmpty);
    expect(b.calls.map((call) => call.parent), everyElement('real-b'));
    expect(find.text('Comedy'), findsOneWidget);
    expect(find.text('Drama'), findsNothing);
    await tester.tap(find.text('Action'));
    await tester.pumpAndSettle();
    expect(router.state.uri.queryParameters['serverId'], 'b');
    expect(router.state.uri.queryParameters['parentId'], 'real-b');
    expect(router.state.uri.queryParameters['genreId'], 'b-Action');
    await tester.pumpWidget(const SizedBox());
    router.dispose();
  });

  testWidgets(
    'an unavailable source leaves the other sources genres accessible',
    (tester) async {
      b.fails = true;
      final router = await mount(tester, 'merged-movies');
      expect(find.text('Action'), findsOneWidget);
      expect(find.text('Drama'), findsOneWidget);
      expect(find.text('Comedy'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      router.dispose();
    },
  );
}
