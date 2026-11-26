import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:moonfin/auth/models/server.dart';
import 'package:moonfin/data/repositories/mdblist_repository.dart';
import 'package:moonfin/data/repositories/multi_server_repository.dart';
import 'package:moonfin/data/services/user_data_sync.dart';
import 'package:moonfin/data/utils/blocked_ratings.dart';
import 'package:moonfin/data/utils/merged_copies.dart';
import 'package:moonfin/data/viewmodels/library_browse_view_model.dart';
import 'package:moonfin/preference/preference_constants.dart';
import 'package:moonfin/preference/user_preferences.dart';
import 'package:server_core/server_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A server library sorted by name, answering each page from where it's
/// asked to start.
class _SortedItemsApi implements ItemsApi {
  _SortedItemsApi(
    this.titles, {
    this.fails = false,
    this.originals = const {},
    this.listedOnly = const [],
    this.played = const {},
    this.ratings = const {},
    this.lightGate,
    this.pageCap,
    this.includeTotal = true,
    this.itemIds = const {},
    this.userData = const {},
    this.userDataGate,
    this.genresByTitle = const {},
  });

  /// Each title, with the TMDB id it carries when it has one.
  final List<(String, String?)> titles;
  final bool fails;

  /// The original title of each title that has one.
  final Map<String, String> originals;

  /// Titles the server lists among its provider ids but never pages in, like
  /// one hidden from this user after the list was read.
  final List<(String, String?)> listedOnly;

  /// Titles this user has watched, left out by the unplayed filter.
  final Set<String> played;

  /// The rating of each title that has one.
  final Map<String, String> ratings;
  final requests = <(int, int)>[];

  /// How many times the whole library was read for its provider ids.
  var lightReads = 0;

  /// Holds the whole-library read back until it completes, like a slow
  /// server far away.
  final Future<void>? lightGate;

  /// The most items one request answers with, whatever it asks for.
  final int? pageCap;
  final bool includeTotal;
  final Map<String, String> itemIds;
  final Map<String, Map<String, dynamic>> userData;
  final Future<void>? userDataGate;
  final Map<String, List<String>> genresByTitle;
  final genreRequests =
      <({String? parent, List<String>? ids, List<String>? names})>[];

  @override
  Future<Map<String, dynamic>> getItems({
    bool? serverWide,
    String? parentId,
    List<String>? ids,
    List<String>? includeItemTypes,
    List<String>? excludeItemTypes,
    String? sortBy,
    String? sortOrder,
    int? startIndex,
    int? limit,
    bool? recursive,
    String? searchTerm,
    String? fields,
    List<String>? personIds,
    List<String>? artistIds,
    List<String>? filters,
    List<String>? seriesStatus,
    String? nameStartsWith,
    String? nameLessThan,
    List<String>? genreIds,
    List<String>? genres,
    bool? isFavorite,
    bool? collapseBoxSetItems,
    bool? enableTotalRecordCount,
    String? enableImageTypes,
    int? imageTypeLimit,
    List<String>? tags,
    List<String>? studios,
    DateTime? minPremiereDate,
    String? maxOfficialRating,
    bool? hasParentalRating,
    String? anyProviderIdEquals,
    List<String>? officialRatings,
    List<int>? years,
    List<String>? videoTypes,
    List<String>? audioLanguages,
    List<String>? subtitleLanguages,
    bool? hasSubtitles,
    bool? hasTrailer,
    bool? hasSpecialFeature,
    bool? hasThemeSong,
    bool? hasThemeVideo,
    bool? isHd,
    bool? is4K,
    bool? is3D,
    bool? enableUserData,
  }) async {
    if (fails) throw StateError('offline');
    genreRequests.add((parent: parentId, ids: genreIds, names: genres));
    if (ids != null) await userDataGate;
    final start = startIndex ?? 0;
    final light = fields?.startsWith('ProviderIds') ?? false;
    if (light) {
      lightReads++;
      await lightGate;
    } else {
      requests.add((start, limit ?? 0));
    }
    final unplayed = filters?.contains('IsUnplayed') ?? false;
    final sorted = [
      for (final title in [...titles, if (light) ...listedOnly])
        if ((!unplayed || !played.contains(title.$1)) &&
            (genres == null ||
                genres.any(
                  (name) => (genresByTitle[title.$1] ?? []).contains(name),
                )))
          title,
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    return {
      if (includeTotal) 'TotalRecordCount': sorted.length,
      'Items': [
        for (final (title, tmdb)
            in sorted.skip(start).take(min(limit ?? 100, pageCap ?? 100000)))
          {
            'Id': itemIds[title] ?? '$parentId-$title',
            'UserData': ?userData[title],
            'Name': title,
            'SortName': title,
            'Type': 'Movie',
            'ProviderIds': {'Tmdb': ?tmdb},
            'OriginalTitle': ?originals[title],
            'OfficialRating': ?ratings[title],
            'Genres': ?genresByTitle[title],
          },
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> getItem(
    String id, {
    String? fields,
    String? mediaSourceId,
  }) async => {'Id': id, 'Name': 'Library $id', 'CollectionType': 'movies'};

  /// Each server's library id stands in for the genre only it holds.
  @override
  Future<QueryFilterValues> getQueryFilters({
    String? parentId,
    List<String>? includeItemTypes,
  }) async => QueryFilterValues(genres: [?parentId]);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeClient implements MediaServerClient {
  _FakeClient(this.itemsApi);

  @override
  final ItemsApi itemsApi;

  @override
  String get baseUrl => 'http://active';

  @override
  String? get userId => 'user';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeMdbListRepository implements MdbListRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

MergedLibrarySource _source(String serverId, _SortedItemsApi api) => (
  session: ServerUserSession(
    server: Server(
      id: serverId,
      name: serverId,
      address: 'http://$serverId',
      version: '10.11.0',
      serverType: ServerType.jellyfin,
      dateAdded: DateTime(2026),
    ),
    userId: 'user',
    client: _FakeClient(api),
  ),
  libraryId: serverId,
);

Future<LibraryBrowseViewModel> _viewModel(
  List<MergedLibrarySource> sources, {
  Future<MergedLibrary> Function()? lookup,
  String? genreId,
  String? genreName,
}) async {
  SharedPreferences.setMockInitialValues({});
  final store = PreferenceStore();
  await store.init();
  return LibraryBrowseViewModel(
    libraryId: mergedLibraryId('movies'),
    genreId: genreId,
    overrideName: genreName,
    client: _FakeClient(_SortedItemsApi(const [])),
    prefs: UserPreferences(store),
    mdbListRepository: _FakeMdbListRepository(),
    loadMergedLibrary:
        lookup ??
        () async => (name: 'Movies', sources: sources, complete: true),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a merged genre filters every real library by name, not a server genre ID',
    () async {
      final a = _SortedItemsApi(
        [('A Action', null), ('A Drama', null)],
        genresByTitle: {
          'A Action': ['Action', 'Adventure'],
          'A Drama': ['Drama'],
        },
      );
      final b = _SortedItemsApi(
        [('B Action', null), ('B Horror', null)],
        genresByTitle: {
          'B Action': ['Action'],
          'B Horror': ['Horror'],
        },
      );
      final vm = await _viewModel(
        [_source('a', a), _source('b', b)],
        genreId: 'only-on-server-a',
        genreName: 'Action',
      );
      addTearDown(vm.dispose);
      await vm.load();
      await vm.ensureAllItemsLoaded();

      expect(vm.items.map((item) => item.name), ['A Action', 'B Action']);
      await vm.toggleGenreFilter('Adventure');
      await vm.ensureAllItemsLoaded();
      expect(vm.items.map((item) => item.name), ['A Action']);
      for (final (id, api) in [('a', a), ('b', b)]) {
        expect(api.genreRequests, isNotEmpty);
        for (final request in api.genreRequests) {
          expect(request.parent, id);
          expect(request.ids, isNull);
          expect(request.names, ['Action']);
        }
      }
    },
  );

  test('merged genre library selection scopes pages and copy index', () async {
    final a = _SortedItemsApi(
      [for (var i = 0; i < 90; i++) ('A$i', '${i + 1}')],
      genresByTitle: {
        for (var i = 0; i < 90; i++) 'A$i': ['Action'],
      },
    );
    final b = _SortedItemsApi(
      [('B Action', '1')],
      genresByTitle: {
        'B Action': ['Action'],
      },
    );
    final vm = await _viewModel(
      [_source('a', a), _source('b', b)],
      genreId: 'a-action',
      genreName: 'Action',
    );
    addTearDown(vm.dispose);
    await vm.load();
    await vm.ensureAllItemsLoaded();
    expect(vm.totalCount, 90);
    a.genreRequests.clear();
    b.genreRequests.clear();
    await vm.setLibraryFilter('a');
    await vm.ensureAllItemsLoaded();
    // Allow the copy-index read to finish too.
    await Future<void>.delayed(Duration.zero);
    expect(vm.items, hasLength(90));
    expect(vm.items.every((item) => item.serverId == 'a'), isTrue);
    expect(vm.items.every((item) => copiesOf(item).length == 1), isTrue);
    expect(b.genreRequests, isEmpty);
    expect(a.genreRequests.map((request) => request.parent), everyElement('a'));
    await vm.setLibraryFilter('b');
    await vm.ensureAllItemsLoaded();
    await Future<void>.delayed(Duration.zero);
    expect(vm.items.map((item) => item.name), ['B Action']);
    expect(copiesOf(vm.items.single), hasLength(1));
    expect(vm.totalCount, 1);
    await vm.setLibraryFilter(null);
    await vm.ensureAllItemsLoaded();
    await Future<void>.delayed(Duration.zero);
    expect(vm.items, hasLength(90));
    expect(
      copiesOf(vm.items.singleWhere((item) => item.name == 'A0')),
      hasLength(2),
    );
  });

  test('merged genre picker distinguishes identical library IDs on different servers', () async {
    final a = _SortedItemsApi(
      [('A Action', '1')],
      genresByTitle: {
        'A Action': ['Action'],
      },
    );
    final b = _SortedItemsApi(
      [('B Action', '1')],
      genresByTitle: {
        'B Action': ['Action'],
      },
    );
    final sourceA = _source('a', a);
    final sourceB = _source('b', b);
    final vm = await _viewModel(
      [
        (session: sourceA.session, libraryId: 'same'),
        (session: sourceB.session, libraryId: 'same'),
      ],
      genreId: 'a-action',
      genreName: 'Action',
    );
    addTearDown(vm.dispose);
    await vm.load();
    await Future<void>.delayed(Duration.zero);
    expect(vm.libraryFilter, isNull);
    expect(vm.libraries.map((library) => library['Name']), [
      'Library same (a)',
      'Library same (b)',
    ]);
    final choices = vm.libraries
        .map((library) => library['Id'] as String)
        .toList();
    expect(choices.toSet(), hasLength(2));
    for (var i = 0; i < choices.length; i++) {
      a.genreRequests.clear();
      b.genreRequests.clear();
      await vm.setLibraryFilter(choices[i]);
      await vm.ensureAllItemsLoaded();
      await Future<void>.delayed(Duration.zero);
      expect(vm.items.single.serverId, i == 0 ? 'a' : 'b');
      expect(copiesOf(vm.items.single), hasLength(1));
      expect((i == 0 ? b : a).genreRequests, isEmpty);
      expect(
        (i == 0 ? a : b).genreRequests.map((request) => request.parent),
        everyElement('same'),
      );
    }
    await vm.setLibraryFilter(null);
    await vm.ensureAllItemsLoaded();
    await Future<void>.delayed(Duration.zero);
    expect(copiesOf(vm.items.single), hasLength(2));
  });

  test(
    'a stale partial lookup cannot replace newer complete merged readers',
    () async {
      final old = Completer<MergedLibrary>();
      final a = _source(
        'a',
        _SortedItemsApi([
          for (var i = 0; i < 60; i++)
            ('A${i.toString().padLeft(3, '0')}', null),
        ]),
      );
      final b = _source(
        'b',
        _SortedItemsApi([
          for (var i = 0; i < 60; i++)
            ('B${i.toString().padLeft(3, '0')}', null),
        ]),
      );
      var lookups = 0;
      final vm = await _viewModel(
        [],
        lookup: () async => ++lookups == 1
            ? await old.future
            : (name: 'Complete', sources: [a, b], complete: true),
      );
      addTearDown(vm.dispose);
      final stale = vm.load();
      await pumpEventQueue();
      await vm.load();
      expect(vm.items, hasLength(75));

      old.complete((name: 'Partial', sources: [a], complete: false));
      await stale;
      await vm.ensureAllItemsLoaded();

      expect(vm.items, hasLength(120));
      expect(vm.totalCount, 120);
      expect(vm.items.where((item) => item.serverId == 'b'), hasLength(60));
      expect(vm.hasMore, isFalse);
    },
  );

  for (final reverse in [false, true]) {
    test('merged user-data refresh keeps overlapping IDs separate '
        '(reverse responses: $reverse)', () async {
      userDataSync.reset();
      final gates = [Completer<void>(), Completer<void>()];
      final aData = <String, Map<String, dynamic>>{
        'First': {'Played': true, 'IsFavorite': false},
      };
      final bData = <String, Map<String, dynamic>>{
        'Second': {'Played': false, 'IsFavorite': true},
      };
      final a = _SortedItemsApi(
        [('First', null)],
        itemIds: {'First': '7'},
        userData: aData,
        userDataGate: gates[0].future,
      );
      final b = _SortedItemsApi(
        [('Second', null)],
        itemIds: {'Second': '7'},
        userData: bData,
        userDataGate: gates[1].future,
      );
      final vm = await _viewModel([_source('a', a), _source('b', b)]);
      addTearDown(() {
        vm.dispose();
        userDataSync.reset();
      });
      await vm.load();
      expect(vm.items.map((item) => item.isPlayed), [true, false]);

      aData['First'] = {
        'Played': true,
        'IsFavorite': true,
        'PlaybackPositionTicks': 42,
        'PlayedPercentage': 25,
      };
      bData['Second'] = {
        'Played': false,
        'IsFavorite': false,
        'PlaybackPositionTicks': 99,
        'PlayedPercentage': 70,
      };
      userDataSync.publish('unrelated', {'Played': true});
      final refresh = vm.syncUserDataIfStale();
      gates[reverse ? 1 : 0].complete();
      await pumpEventQueue();
      expect(vm.items.map((item) => item.isPlayed), [true, false]);
      gates[reverse ? 0 : 1].complete();
      await refresh;

      expect(vm.items.map((item) => item.isPlayed), [true, false]);
      expect(vm.items.map((item) => item.isFavorite), [true, false]);
      expect(vm.items.map((item) => item.playbackPositionTicks), [42, 99]);
      expect(vm.items.map((item) => item.playedPercentage), [25, 70]);
    });
  }

  test(
    'every server pages in by name, with shared titles shown once',
    () async {
      final a = _SortedItemsApi([
        for (var i = 0; i < 60; i += 2)
          ('a${i.toString().padLeft(3, '0')}', null),
        ('shared', '603'),
      ]);
      final b = _SortedItemsApi([
        for (var i = 1; i < 60; i += 2)
          ('a${i.toString().padLeft(3, '0')}', null),
        ('shared', '603'),
      ]);
      final vm = await _viewModel([_source('a', a), _source('b', b)]);
      addTearDown(vm.dispose);

      await vm.load();
      while (vm.hasMore) {
        await vm.loadMore();
      }

      final names = vm.items.map((item) => item.name).toList();
      expect(names, [...names]..sort());
      expect(names.where((name) => name == 'shared'), hasLength(1));
      expect(names, hasLength(61));
      expect(vm.totalCount, 61);
      final shared = vm.items.singleWhere((item) => item.name == 'shared');
      expect(copiesOf(shared).map((copy) => copy.serverId), ['a', 'b']);
      expect(vm.items.firstWhere((item) => item.name == 'a001').serverId, 'b');
      // Each server is asked from where it left off, not from the list's count.
      final pages = a.requests.where((request) => request.$2 > 0);
      expect(pages.first.$1, 0);
      expect(pages.skip(1).every((request) => request.$1 > 0), isTrue);
    },
  );

  test('merged paging reads past short pages with a reported total', () async {
    final a = _SortedItemsApi([
      for (var i = 0; i < 160; i++) ('a${i.toString().padLeft(3, '0')}', null),
    ], pageCap: 50);
    final vm = await _viewModel([
      _source('a', a),
      _source('b', _SortedItemsApi(const [('zebra', null)])),
    ]);
    addTearDown(vm.dispose);
    await vm.load();

    await vm.ensureAllItemsLoaded();

    expect(vm.items.map((item) => item.name), [
      for (var i = 0; i < 160; i++) 'a${i.toString().padLeft(3, '0')}',
      'zebra',
    ]);
    expect(vm.totalCount, 161);
    expect(vm.hasMore, isFalse);
    expect(a.requests.map((request) => request.$1), [0, 50, 100, 150]);
  });

  for (final unknownTitle in ['aardvark', 'zebra']) {
    test(
      'a capped merged reader keeps paging with an unknown-total source ($unknownTitle)',
      () async {
        final a = _SortedItemsApi([
          for (var i = 0; i < 160; i++)
            ('a${i.toString().padLeft(3, '0')}', null),
        ], pageCap: 50);
        final b = _SortedItemsApi([(unknownTitle, null)], includeTotal: false);
        final vm = await _viewModel([_source('a', a), _source('b', b)]);
        addTearDown(vm.dispose);
        await vm.load();
        expect(vm.hasMore, isTrue);
        await vm.ensureAllItemsLoaded();
        final expected = [
          for (var i = 0; i < 160; i++) 'a${i.toString().padLeft(3, '0')}',
          unknownTitle,
        ]..sort();
        expect(vm.items.map((item) => item.name), expected);
        expect(vm.totalCount, 161);
        expect(vm.hasMore, isFalse);
        expect(a.requests.map((request) => request.$1), [0, 50, 100, 150]);
        expect(b.requests, hasLength(1));
      },
    );
  }

  test(
    'merged paging stops on a short page without a reported total',
    () async {
      final a = _SortedItemsApi(const [
        ('alpha', null),
        ('beta', null),
      ], includeTotal: false);
      final vm = await _viewModel([
        _source('a', a),
        _source('b', _SortedItemsApi(const [('zebra', null)])),
      ]);
      addTearDown(vm.dispose);
      await vm.load();
      await vm.ensureAllItemsLoaded();

      expect(vm.items.map((item) => item.name), ['alpha', 'beta', 'zebra']);
      expect(vm.hasMore, isFalse);
      expect(a.requests, hasLength(1));
    },
  );

  test(
    'an empty page stops a source even when its total claims more',
    () async {
      final a = _SortedItemsApi(const [('missing', null)], pageCap: 0);
      final vm = await _viewModel([
        _source('a', a),
        _source('b', _SortedItemsApi(const [('zebra', null)])),
      ]);
      addTearDown(vm.dispose);
      await vm.load();
      await vm.ensureAllItemsLoaded();

      expect(vm.items.map((item) => item.name), ['zebra']);
      expect(vm.hasMore, isFalse);
      expect(a.requests, hasLength(1));
    },
  );

  test('the search box finds a card by any copy\'s title or the original '
      'title', () async {
    final vm = await _viewModel([
      _source(
        'a',
        _SortedItemsApi(
          [('The Lord of the Rings', '120'), ('Amélie', '194')],
          originals: {'Amélie': "Le Fabuleux Destin d'Amélie Poulain"},
        ),
      ),
      _source(
        'b',
        _SortedItemsApi([
          ('Le Seigneur des Anneaux', '120'),
          ('Die fabelhafte Welt der Amélie', '194'),
        ]),
      ),
    ]);
    addTearDown(vm.dispose);
    await vm.load();

    vm.setSearchQuery('seigneur');
    expect(vm.items.map((item) => item.name), ['The Lord of the Rings']);
    vm.setSearchQuery('fabuleux');
    expect(vm.items.map((item) => item.name), ['Amélie']);
  });

  test(
    'loading everything carries on past a page that only held copies',
    () async {
      String name(String prefix, int i) =>
          '$prefix${i.toString().padLeft(3, '0')}';
      final vm = await _viewModel([
        _source(
          'a',
          _SortedItemsApi([
            for (var i = 0; i < 600; i++) (name('a', i), '${i + 1}'),
          ]),
        ),
        _source(
          'b',
          _SortedItemsApi([
            for (var i = 0; i < 600; i++) (name('z', i), '${i + 1}'),
            ('zzzz', null),
          ]),
        ),
      ]);
      addTearDown(vm.dispose);
      await vm.load();

      await vm.ensureAllItemsLoaded();

      expect(vm.items, hasLength(601));
      expect(vm.items.last.name, 'zzzz');
    },
  );

  for (final count in [100, 250]) {
    test(
      'the first merged load passes $count deferred translated copies',
      () async {
        final vm = await _viewModel([
          _source(
            'a',
            _SortedItemsApi([
              for (var i = 0; i < count; i++)
                ('Z${i.toString().padLeft(3, '0')}', '${i + 1}'),
            ]),
          ),
          _source(
            'b',
            _SortedItemsApi([
              for (var i = 0; i < count; i++)
                ('A${i.toString().padLeft(3, '0')}', '${i + 1}'),
            ]),
          ),
        ]);
        addTearDown(vm.dispose);

        await vm.load();

        expect(vm.state, LibraryBrowseState.ready);
        expect(vm.items, isNotEmpty);
        expect(vm.items.every((item) => item.serverId == 'a'), isTrue);
        expect(vm.items.first.name, 'Z000');
        expect(copiesOf(vm.items.first).map((copy) => copy.serverId), [
          'a',
          'b',
        ]);
        await vm.ensureAllItemsLoaded();
        expect(vm.items, hasLength(count));
        expect(vm.totalCount, count);
        expect(vm.hasMore, isFalse);
      },
    );
  }

  test('an initial page of deferred copies is recovered when preferred cards '
      'never arrive', () async {
    final titles = [
      for (var i = 0; i < 100; i++)
        ('A${i.toString().padLeft(3, '0')}', '${i + 1}'),
    ];
    final vm = await _viewModel([
      _source('a', _SortedItemsApi(const [], listedOnly: titles)),
      _source('b', _SortedItemsApi(titles)),
    ]);
    addTearDown(vm.dispose);

    await vm.load();

    expect(vm.state, LibraryBrowseState.ready);
    expect(vm.items, hasLength(100));
    expect(vm.items.every((item) => item.serverId == 'b'), isTrue);
    expect(vm.hasMore, isFalse);
  });

  group("the first server's copy is the card", () {
    List<MergedLibrarySource> sources({
      List<(String, String?)> listedOnly = const [],
    }) => [
      _source(
        'a',
        _SortedItemsApi([
          ('Alpha', '1'),
          ('The Lord of the Rings', '120'),
        ], listedOnly: listedOnly),
      ),
      _source(
        'b',
        _SortedItemsApi([
          ('Beta', '2'),
          ('Le Seigneur des Anneaux', '120'),
          ('Spectre', '9'),
        ]),
      ),
    ];

    test('at its own place, even when the other copy sorts first', () async {
      final vm = await _viewModel(sources());
      addTearDown(vm.dispose);
      await vm.load();

      expect(vm.items.map((item) => item.name), [
        'Alpha',
        'Beta',
        'Spectre',
        'The Lord of the Rings',
      ]);
      expect(copiesOf(vm.items.last).map((copy) => copy.serverId), ['a', 'b']);
    });

    test('but the first copy keeps the card while a filter is on', () async {
      final vm = await _viewModel(sources());
      addTearDown(vm.dispose);
      await vm.setPlayedFilter(PlayedStatusFilter.unwatched);

      expect(
        vm.items.map((item) => item.name),
        contains('Le Seigneur des Anneaux'),
      );
    });

    test(
      'a copy that waited for a card that never came shows at the end',
      () async {
        final vm = await _viewModel(sources(listedOnly: [('Spectre', '9')]));
        addTearDown(vm.dispose);
        await vm.load();

        expect(vm.items.map((item) => item.name), [
          'Alpha',
          'Beta',
          'The Lord of the Rings',
          'Spectre',
        ]);
        expect(vm.totalCount, 4);
      },
    );
  });

  test(
    'a search is still filling until it has read the whole library',
    () async {
      final vm = await _viewModel([
        _source(
          'a',
          _SortedItemsApi([
            for (var i = 0; i < 200; i++)
              ('a${i.toString().padLeft(3, '0')}', null),
          ]),
        ),
        _source('b', _SortedItemsApi(const [('zebra', null)])),
      ]);
      addTearDown(vm.dispose);
      await vm.load();
      expect(vm.hasMore, isTrue);

      vm.setSearchQuery('zebra');
      expect(vm.items, isEmpty);
      expect(vm.searchFilling, isTrue);

      while (vm.searchFilling) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(vm.items.map((item) => item.name), ['zebra']);
    },
  );

  test('a search with nothing left to read is done at once', () async {
    final vm = await _viewModel([
      _source('a', _SortedItemsApi(const [('alpha', null)])),
      _source('b', _SortedItemsApi(const [('beta', null)])),
    ]);
    addTearDown(vm.dispose);
    await vm.load();

    vm.setSearchQuery('zebra');
    expect(vm.items, isEmpty);
    expect(vm.searchFilling, isFalse);
  });

  test('a server that fails leaves the others browsing', () async {
    final vm = await _viewModel([
      _source('a', _SortedItemsApi([('one', null), ('two', null)])),
      _source('b', _SortedItemsApi(const [], fails: true)),
    ]);
    addTearDown(vm.dispose);

    await vm.load();

    expect(vm.state, LibraryBrowseState.ready);
    expect(vm.items.map((item) => item.name), ['one', 'two']);
    expect(vm.hasMore, isFalse);
  });

  test(
    'a server that answers a retried lookup adds its filter values',
    () async {
      final a = _source('a', _SortedItemsApi(const [('Alpha', '1')]));
      final b = _source('b', _SortedItemsApi(const [('Beta', '2')]));
      var lookups = 0;
      final vm = await _viewModel(
        const [],
        lookup: () async => ++lookups == 1
            ? (name: 'Movies', sources: [a], complete: false)
            : (name: 'Movies', sources: [a, b], complete: true),
      );
      await vm.load();
      await vm.ensureFacetValuesLoaded();
      expect(vm.facetValues.genres, ['a']);

      await vm.load();
      await pumpEventQueue();
      expect(vm.facetValues.genres, ['a', 'b']);
    },
  );

  test('every server failing is an error, not an empty library', () async {
    final vm = await _viewModel([
      _source('a', _SortedItemsApi(const [], fails: true)),
      _source('b', _SortedItemsApi(const [], fails: true)),
    ]);
    addTearDown(vm.dispose);

    await vm.load();

    expect(vm.state, LibraryBrowseState.error);
  });

  group('a copy paging has not reached', () {
    // Server a's first page ends long before server b's copy of the shared
    // title, which sorts last there under another name.
    List<MergedLibrarySource> sources({
      Set<String> played = const {},
      Map<String, String> ratings = const {},
      Future<void>? slow,
      List<(String, String?)> before = const [],
      int? pageCap,
    }) => [
      _source(
        'a',
        _SortedItemsApi([
          ('Aaa Vortelle', '1001'),
          for (var i = 0; i < 200; i++)
            ('b${i.toString().padLeft(3, '0')}', null),
        ]),
      ),
      _source(
        'b',
        _SortedItemsApi(
          [...before, ('Zz Vortelle', '1001')],
          played: played,
          ratings: ratings,
          lightGate: slow,
          pageCap: pageCap,
        ),
      ),
    ];

    List<String> serversOfFirstCard(LibraryBrowseViewModel vm) => [
      for (final copy in copiesOf(vm.items.first)) copy.serverId,
    ];

    test('joins its card once the index is in', () async {
      final vm = await _viewModel(sources());
      addTearDown(vm.dispose);
      await vm.load();
      await pumpEventQueue();

      expect(vm.items.first.name, 'Aaa Vortelle');
      expect(serversOfFirstCard(vm), ['a', 'b']);
    });

    test('is read with each server once for the index and the first '
        "server's titles together", () async {
      final list = sources();
      final vm = await _viewModel(list);
      addTearDown(vm.dispose);
      await vm.load();
      await pumpEventQueue();

      for (final source in list) {
        final api = source.session.client.itemsApi as _SortedItemsApi;
        expect(api.lightReads, 1);
      }
    });

    test('stays off the card when the filter on leaves it out', () async {
      final vm = await _viewModel(sources(played: {'Zz Vortelle'}));
      addTearDown(vm.dispose);
      await vm.setPlayedFilter(PlayedStatusFilter.unwatched);
      await pumpEventQueue();

      expect(vm.items.first.name, 'Aaa Vortelle');
      expect(serversOfFirstCard(vm), ['a']);
    });

    test('stays off the card when the viewer blocked its rating', () async {
      SharedPreferences.setMockInitialValues({});
      final store = PreferenceStore();
      await store.init();
      final prefs = UserPreferences(store);
      await prefs.set(UserPreferences.blockedParentalRatings, 'Rated-Q');
      GetIt.instance.registerSingleton<UserPreferences>(prefs);
      addTearDown(() async {
        await GetIt.instance.reset();
        resetParentalFilterCache();
      });

      final vm = await _viewModel(sources(ratings: {'Zz Vortelle': 'Rated-Q'}));
      addTearDown(vm.dispose);
      await vm.load();
      await pumpEventQueue();

      expect(serversOfFirstCard(vm), ['a']);
    });

    test("shows the first page without waiting on a slow server's whole "
        'library', () async {
      final slow = Completer<void>();
      final vm = await _viewModel(sources(slow: slow.future));
      addTearDown(vm.dispose);

      await vm.load().timeout(const Duration(seconds: 2));
      expect(vm.items.first.name, 'Aaa Vortelle');
      expect(serversOfFirstCard(vm), ['a']);

      slow.complete();
      await pumpEventQueue();
      expect(serversOfFirstCard(vm), ['a', 'b']);
    });

    test('gives way to the full copy once paging reaches it', () async {
      final vm = await _viewModel(sources());
      addTearDown(vm.dispose);
      await vm.load();
      await pumpEventQueue();
      expect(copiesOf(vm.items.first)[1].rawData['SortName'], isNull);

      while (vm.hasMore) {
        await vm.loadMore();
      }

      final copies = copiesOf(vm.items.first);
      expect(copies.map((copy) => copy.serverId), ['a', 'b']);
      expect(copies[1].rawData['SortName'], 'Zz Vortelle');
      expect(vm.items.map((item) => item.name), isNot(contains('Zz Vortelle')));
      expect(vm.totalCount, vm.items.length);
    });

    test('is read once, and kept when the browse loads again', () async {
      final list = sources();
      final vm = await _viewModel(list);
      addTearDown(vm.dispose);
      await vm.load();
      await pumpEventQueue();
      await vm.load();
      await pumpEventQueue();

      for (final source in list) {
        final api = source.session.client.itemsApi as _SortedItemsApi;
        expect(api.lightReads, 1);
      }
      expect(serversOfFirstCard(vm), ['a', 'b']);
    });

    test(
      'is found when a server answers in pages shorter than asked',
      () async {
        final vm = await _viewModel(
          sources(
            before: [
              for (var i = 0; i < 150; i++)
                ('C${i.toString().padLeft(3, '0')}', null),
            ],
            pageCap: 50,
          ),
        );
        addTearDown(vm.dispose);
        await vm.load();
        await pumpEventQueue();

        expect(vm.items.first.name, 'Aaa Vortelle');
        expect(serversOfFirstCard(vm), ['a', 'b']);
      },
    );

    test(
      'is read again under the unplayed filter once it is watched',
      () async {
        final played = <String>{};
        final vm = await _viewModel(sources(played: played));
        addTearDown(vm.dispose);
        await vm.setPlayedFilter(PlayedStatusFilter.unwatched);
        await pumpEventQueue();
        expect(serversOfFirstCard(vm), ['a', 'b']);

        played.add('Zz Vortelle');
        await vm.load();
        await pumpEventQueue();

        expect(serversOfFirstCard(vm), ['a']);
      },
    );

    test('is read again on a refresh, though not on a plain reload', () async {
      final list = sources();
      final vm = await _viewModel(list);
      addTearDown(vm.dispose);
      await vm.load();
      await pumpEventQueue();
      await vm.load();
      await pumpEventQueue();
      await vm.refresh();
      await pumpEventQueue();

      for (final source in list) {
        final api = source.session.client.itemsApi as _SortedItemsApi;
        expect(api.lightReads, 2);
      }
    });
  });
}
