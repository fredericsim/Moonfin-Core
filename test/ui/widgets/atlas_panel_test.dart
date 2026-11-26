import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:server_core/server_core.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:moonfin/auth/models/server.dart';
import 'package:moonfin/auth/models/user.dart';
import 'package:moonfin/auth/repositories/user_repository.dart';
import 'package:moonfin/auth/repositories/session_repository.dart';
import 'package:moonfin/data/models/aggregated_library.dart';
import 'package:moonfin/data/repositories/multi_server_repository.dart';
import 'package:moonfin/data/repositories/seerr_repository.dart';
import 'package:moonfin/data/services/seerr/seerr_api_models.dart';
import 'package:moonfin/data/services/media_server_client_factory.dart';
import 'package:moonfin/data/services/user_data_sync.dart';
import 'package:moonfin/data/utils/blocked_ratings.dart';
import 'package:moonfin/l10n/app_localizations.dart';
import 'package:moonfin/l10n/app_localizations_en.dart';
import 'package:moonfin/preference/user_preferences.dart';
import 'package:moonfin/preference/seerr_preferences.dart';
import 'package:moonfin/ui/navigation/destinations.dart';
import 'package:moonfin/ui/widgets/nav_styles/atlas_panel.dart';
import 'package:moonfin/ui/widgets/nav_styles/nav_focusable.dart';

class _Session extends Fake implements SessionRepository {
  @override
  String get activeUserId => 'a';
}

class _SeerrRepo extends Fake implements SeerrRepository {
  List<SeerrDiscoverItem> results = [];
  int calls = 0;
  @override
  Future<SeerrDiscoverPage> getTrending({
    int limit = 20,
    int offset = 0,
  }) async {
    calls++;
    return SeerrDiscoverPage(
      results: results.skip(offset).take(limit).toList(),
    );
  }
}

const _trending = [
  SeerrDiscoverItem(
    id: 1,
    title: 'Adult flag',
    adult: true,
    backdropPath: '/adult.jpg',
  ),
  SeerrDiscoverItem(
    id: 2,
    title: 'Erotic Thriller',
    backdropPath: '/keyword.jpg',
  ),
  SeerrDiscoverItem(
    id: 3,
    name: 'Overview match',
    overview: 'An erotic story',
    backdropPath: '/overview.jpg',
  ),
  SeerrDiscoverItem(
    id: 4,
    title: 'Blocklisted',
    backdropPath: '/blocked.jpg',
    mediaInfo: SeerrMediaInfo(status: SeerrMediaStatus.blocklisted),
  ),
  SeerrDiscoverItem(
    id: 5,
    title: 'Available',
    backdropPath: '/available.jpg',
    mediaInfo: SeerrMediaInfo(status: SeerrMediaStatus.available),
  ),
  SeerrDiscoverItem(id: 6, title: 'No artwork'),
  SeerrDiscoverItem(
    id: 7,
    title: 'Allowed movie',
    mediaType: 'movie',
    backdropPath: '/movie.jpg',
  ),
  SeerrDiscoverItem(
    id: 8,
    name: 'Allowed series',
    mediaType: 'tv',
    backdropPath: '/tv.jpg',
  ),
];

class _Api implements ItemsApi {
  List<Map<String, dynamic>> resume = [];
  List<Map<String, dynamic>> latest = [];
  Future<void>? gate;
  bool fails = false;
  final calls = <(Symbol, String?)>[];

  Future<Map<String, dynamic>> read(Invocation invocation) async {
    calls.add((
      invocation.memberName,
      invocation.namedArguments[#parentId] as String?,
    ));
    final items = List<Map<String, dynamic>>.of(
      invocation.memberName == #getResumeItems ? resume : latest,
    );
    await gate;
    if (fails) throw StateError('offline');
    return {'Items': items};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      invocation.memberName == #getResumeItems ||
          invocation.memberName == #getLatestItems
      ? read(invocation)
      : super.noSuchMethod(invocation);
}

class _Images extends Fake implements ImageApi {}

class _Client extends Fake implements MediaServerClient {
  _Client(this.itemsApi);
  @override
  final _Api itemsApi;
  @override
  ImageApi get imageApi => _Images();
}

class _Factory extends Fake implements MediaServerClientFactory {
  final clientsById = <String, MediaServerClient>{};
  @override
  MediaServerClient clientForServerOrActive(String? serverId) =>
      clientsById[serverId] ?? clientsById.values.first;
}

class _Merged extends Fake implements MultiServerRepository {
  List<MergedLibrarySource> sources = [];
  final asked = <String>[];
  @override
  Future<MergedLibrary> mergedLibrary(String collectionType) async {
    asked.add(collectionType);
    return (name: 'Merged', sources: sources, complete: true);
  }
}

Map<String, dynamic> _item(
  String title, {
  String id = '7',
  String rating = 'PG',
}) => {
  'Id': id,
  'Name': title,
  'Type': 'Movie',
  'OfficialRating': rating,
  'UserData': {'PlayedPercentage': 50},
};

PrivateUser _user(String id) => PrivateUser(
  id: id,
  name: id,
  serverId: 'a',
  accessToken: 'test',
  lastUsed: DateTime(2026),
);

const _library = AggregatedLibrary(
  id: 'movies',
  name: 'Movies',
  collectionType: 'movies',
  serverId: 'a',
);

Finder _tile(String title) => find.byWidgetPredicate(
  (widget) => widget is NavFocusable && widget.semanticLabel == title,
);

void main() {
  late UserPreferences prefs;
  late SeerrPreferences seerrPrefs;
  late _SeerrRepo seerr;
  late UserRepository users;
  late _Factory factory;
  late _Api api;
  late FocusScopeNode scope;
  late FocusNode first;
  late List<String> opened;

  setUp(() async {
    userDataSync.reset();
    resetParentalFilterCache();
    SharedPreferences.setMockInitialValues({});
    final store = PreferenceStore();
    await store.init();
    prefs = UserPreferences(store);
    seerrPrefs = SeerrPreferences(store, _Session());
    seerr = _SeerrRepo();
    GetIt.instance.registerSingleton<SeerrPreferences>(seerrPrefs);
    GetIt.instance.registerSingletonAsync<SeerrRepository>(() async => seerr);
    await GetIt.instance.isReady<SeerrRepository>();
    users = UserRepository()..setCurrentUser(_user('a'));
    api = _Api();
    factory = _Factory()..clientsById['a'] = _Client(api);
    GetIt.instance.registerSingleton<UserPreferences>(prefs);
    GetIt.instance.registerSingleton<UserRepository>(users);
    GetIt.instance.registerSingleton<MediaServerClientFactory>(factory);
    scope = FocusScopeNode();
    first = FocusNode();
    opened = [];
  });

  tearDown(() async {
    scope.dispose();
    first.dispose();
    users.dispose();
    await GetIt.instance.reset();
  });

  Future<void> mount(
    WidgetTester tester, {
    AggregatedLibrary lib = _library,
    AtlasPanelSpec? spec,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: const [Locale('en')],
        home: Scaffold(
          body: SingleChildScrollView(
            child: AtlasPanel(
              spec: spec ?? atlasLibrarySpec(AppLocalizationsEn(), lib),
              scopeNode: scope,
              firstFocus: first,
              compact: true,
              onExit: () {},
              onOpen: (route, {required topLevel}) => opened.add(route),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  void ratedItems() {
    api.resume = [
      _item('Blocked resume', rating: 'R'),
      _item('Allowed resume', id: '8'),
    ];
    api.latest = [
      _item('Blocked latest', rating: 'R'),
      _item('Allowed latest', id: '8'),
    ];
  }

  test(
    'Seerr preview applies Discover filters before taking its two cards',
    () async {
      seerr.results = _trending;
      expect(seerrPrefs.blockNsfw, isTrue);
      final data = await atlasSeerrSpec(
        AppLocalizationsEn(),
        'Requests',
      ).load!();
      expect(data.cards.map((tile) => tile.title), [
        'Allowed movie',
        'Allowed series',
      ]);
      expect(
        data.cards.last.route,
        Destinations.seerrMedia('8', mediaType: 'tv', title: 'Allowed series'),
      );
    },
  );

  test('turning off the adult filter keeps blocklisted and available titles hidden', () async {
    seerr.results = [_trending[3], _trending[4], _trending[0], _trending[1]];
    await seerrPrefs.setBlockNsfw(false);
    final data = await atlasSeerrSpec(AppLocalizationsEn(), 'Requests').load!();
    expect(data.cards.map((tile) => tile.title), [
      'Adult flag',
      'Erotic Thriller',
    ]);
  });

  test('Seerr preview is empty when all candidates are filtered out', () async {
    seerr.results = _trending.take(5).toList();
    final data = await atlasSeerrSpec(AppLocalizationsEn(), 'Requests').load!();
    expect(data.cards, isEmpty);
  });

  testWidgets(
    'cached Seerr previews honor the current adult filter on rebuild and reopen',
    (tester) async {
      seerr.results = [_trending[0], _trending[6]];
      await seerrPrefs.setBlockNsfw(false);
      await mount(
        tester,
        spec: atlasSeerrSpec(AppLocalizationsEn(), 'Requests'),
      );
      expect(find.text('Adult flag'), findsOneWidget);
      await seerrPrefs.setBlockNsfw(true);
      await mount(
        tester,
        spec: atlasSeerrSpec(AppLocalizationsEn(), 'Requests'),
      );
      expect(find.text('Adult flag'), findsNothing);
      expect(find.text('Allowed movie'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await mount(
        tester,
        spec: atlasSeerrSpec(AppLocalizationsEn(), 'Requests'),
      );
      expect(find.text('Adult flag'), findsNothing);
      expect(find.text('Allowed movie'), findsOneWidget);
      expect(seerr.calls, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('rating filters apply to both library columns', (tester) async {
    ratedItems();
    await prefs.set(UserPreferences.blockedParentalRatings, 'R');
    await mount(tester);
    expect(find.text('Blocked resume'), findsNothing);
    expect(_tile('Blocked latest'), findsNothing);
    expect(find.text('Allowed resume'), findsOneWidget);
    expect(_tile('Allowed latest'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('new rating filters apply to cached data and a mounted panel', (
    tester,
  ) async {
    ratedItems();
    await mount(tester);
    expect(find.text('Blocked resume'), findsOneWidget);
    await prefs.set(UserPreferences.blockedParentalRatings, 'R');
    await tester.pump();
    expect(find.text('Blocked resume'), findsNothing);
    expect(_tile('Blocked latest'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await mount(tester);
    expect(api.calls, hasLength(2));
    expect(find.text('Blocked resume'), findsNothing);
    expect(find.text('Allowed resume'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  for (final resetSession in [false, true]) {
    testWidgets(
      'account changes cannot reuse cached resume data (reset: $resetSession)',
      (tester) async {
        api.resume = [_item('User A resume')];
        await mount(tester);
        expect(find.text('User A resume'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        users.setCurrentUser(_user('b'));
        if (resetSession) userDataSync.reset();
        api.resume = [_item('User B resume')];
        await mount(tester);
        expect(find.text('User A resume'), findsNothing);
        expect(find.text('User B resume'), findsOneWidget);
        expect(api.calls, hasLength(4));
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('late account responses cannot populate the next account panel', (
    tester,
  ) async {
    final release = Completer<void>();
    api.resume = [_item('User A resume')];
    api.gate = release.future;
    await mount(tester);
    users.setCurrentUser(_user('b'));
    userDataSync.reset();
    api.gate = null;
    api.resume = [_item('User B resume')];
    await tester.pumpAndSettle();
    expect(find.text('User B resume'), findsOneWidget);
    release.complete();
    await tester.pumpAndSettle();
    expect(find.text('User A resume'), findsNothing);
    expect(find.text('User B resume'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('restarting the same user session invalidates cached cards', (
    tester,
  ) async {
    api.resume = [_item('Old session')];
    await mount(tester);
    await tester.pumpWidget(const SizedBox());
    userDataSync.reset();
    api.resume = [_item('New session')];
    await mount(tester);
    expect(find.text('Old session'), findsNothing);
    expect(find.text('New session'), findsOneWidget);
    expect(api.calls, hasLength(4));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('logout clears a mounted panel without loading another user', (
    tester,
  ) async {
    api.resume = [_item('Private resume')];
    await mount(tester);
    users.setCurrentUser(null);
    await tester.pumpAndSettle();
    expect(find.text('Private resume'), findsNothing);
    expect(api.calls, hasLength(2));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a failed load is retried on the next open', (tester) async {
    api.fails = true;
    await mount(tester);
    await tester.pumpWidget(const SizedBox());
    api.fails = false;
    api.resume = [_item('Recovered')];
    await mount(tester);
    expect(find.text('Recovered'), findsOneWidget);
    expect(api.calls, hasLength(4));
    await tester.pumpWidget(const SizedBox());
  });

  for (final type in ['movies', 'tvshows']) {
    testWidgets('merged $type queries real libraries on every server', (
      tester,
    ) async {
      final b = _Api()
        ..resume = [_item('B resume', rating: 'R')]
        ..latest = [_item('B latest', rating: 'R')];
      api.resume = [_item('A resume')];
      api.latest = [_item('A latest')];
      factory.clientsById['b'] = _Client(b);
      final merged = _Merged()
        ..sources = [
          for (final id in ['a', 'b'])
            (
              session: ServerUserSession(
                server: Server(
                  id: id,
                  name: id,
                  address: 'http://$id',
                  version: '1',
                  serverType: ServerType.jellyfin,
                  dateAdded: DateTime(2026),
                ),
                userId: 'user',
                client: factory.clientsById[id]!,
              ),
              libraryId: 'real-$id',
            ),
        ];
      GetIt.instance.registerSingleton<MultiServerRepository>(merged);
      await mount(
        tester,
        lib: AggregatedLibrary(
          id: 'merged-$type',
          name: 'Merged',
          collectionType: type,
          serverId: 'a',
        ),
      );
      expect(merged.asked, [type]);
      expect(api.calls.map((call) => call.$2), everyElement('real-a'));
      expect(b.calls.map((call) => call.$2), everyElement('real-b'));
      expect(find.text('A resume'), findsOneWidget);
      expect(find.text('B resume'), findsOneWidget);
      expect(_tile('A latest'), findsOneWidget);
      expect(_tile('B latest'), findsOneWidget);
      await tester.tap(find.text('B resume'));
      expect(opened, [Destinations.item('7', serverId: 'b')]);
      await prefs.set(UserPreferences.blockedParentalRatings, 'R');
      await tester.pump();
      expect(find.text('B resume'), findsNothing);
      expect(_tile('B latest'), findsNothing);
      expect(find.text('A resume'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
