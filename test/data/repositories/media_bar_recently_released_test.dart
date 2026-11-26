import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moonfin/data/models/media_bar_state.dart';
import 'package:moonfin/data/repositories/media_bar_repository.dart';
import 'package:moonfin/preference/preference_constants.dart';
import 'package:moonfin/preference/user_preferences.dart';
import 'package:server_core/server_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Client extends Mock implements MediaServerClient {}

class _ItemsApi extends Mock implements ItemsApi {}

class _ImageApi extends Mock implements ImageApi {}

class _UserViewsApi extends Mock implements UserViewsApi {}

Map<String, dynamic> _item(String id, String type, {String? seriesId}) => {
  'Id': id,
  'Type': type,
  'SeriesId': ?seriesId,
  'BackdropImageTags': ['b'],
};

void main() {
  tearDown(() => GetIt.instance.reset());

  /// Loads the bar from one TV library with the home row in [mode], and
  /// returns the slides and the item types asked of the server. [children]
  /// answers an episode or season request by its limit.
  Future<(List<String>, List<List<String>?>)> load(
    RecentlyReleasedSeriesType mode, {
    List<Map<String, dynamic>> Function(int limit)? children,
    String source = UserPreferences.mediaBarSourceRecentlyReleased,
    int itemCount = 10,
    bool mixed = false,
    bool collection = false,
    List<Map<String, dynamic>> movies = const [],
  }) async {
    SharedPreferences.setMockInitialValues({});
    final store = PreferenceStore();
    await store.init();
    final prefs = UserPreferences(store);
    await prefs.set(UserPreferences.pluginSyncEnabled, false);
    await prefs.set(UserPreferences.mediaBarItemCount, "$itemCount");
    await prefs.set(UserPreferences.mediaBarSourceType, source);
    await prefs.set(UserPreferences.recentlyReleasedSeriesType, mode);
    if (collection) {
      await prefs.set(UserPreferences.mediaBarCollectionIds, 'collection');
    }

    final views = _UserViewsApi();
    when(() => views.getUserViews()).thenAnswer(
      (_) async => {
        'Items': [
          {'Id': 'tv', 'CollectionType': mixed ? 'mixed' : 'tvshows'},
        ],
      },
    );
    final asked = <List<String>?>[];
    final items = _ItemsApi();
    when(
      () => items.getRecentlyReleasedItems(
        includeItemTypes: any(named: 'includeItemTypes'),
        parentId: any(named: 'parentId'),
        recursive: any(named: 'recursive'),
        limit: any(named: 'limit'),
        fields: any(named: 'fields'),
        enableImageTypes: any(named: 'enableImageTypes'),
        hideWatched: any(named: 'hideWatched'),
      ),
    ).thenAnswer((invocation) async {
      final types =
          invocation.namedArguments[#includeItemTypes] as List<String>?;
      final limit = invocation.namedArguments[#limit] as int;
      asked.add(types);
      return {
        'Items': switch (types?.single) {
          'Series' => [_item('first', 'Series')],
          'Movie' => movies,
          _ when children != null => children(limit),
          _ => [
            _item('e1', 'Episode', seriesId: 'late'),
            _item('e2', 'Episode', seriesId: 'early'),
            _item('e3', 'Episode', seriesId: 'late'),
          ],
        },
      };
    });
    // Jellyfin answers a Series filter here with nothing.
    when(
      () => items.getLatestItems(
        includeItemTypes: any(named: 'includeItemTypes'),
        parentId: any(named: 'parentId'),
        limit: any(named: 'limit'),
        fields: any(named: 'fields'),
        enableImageTypes: any(named: 'enableImageTypes'),
      ),
    ).thenAnswer(
      (invocation) async => {
        'Items': invocation.namedArguments[#includeItemTypes] == null
            ? [
                _item('e1', 'Episode', seriesId: 'late'),
                _item('s1', 'Season', seriesId: 'early'),
                _item('e3', 'Episode', seriesId: 'late'),
              ]
            : const [],
      },
    );
    when(
      () => items.getItems(
        ids: any(named: 'ids'),
        fields: any(named: 'fields'),
        enableTotalRecordCount: any(named: 'enableTotalRecordCount'),
        enableImageTypes: any(named: 'enableImageTypes'),
      ),
    ).thenAnswer(
      (invocation) async => {
        'Items': [
          // A server can answer in its own order.
          for (final id
              in (invocation.namedArguments[#ids] as List<String>).reversed)
            _item(id, 'Series'),
        ],
      },
    );
    when(() => items.getItems(
      parentId: any(named: 'parentId'),
      includeItemTypes: const ['Episode'],
      recursive: true,
      sortBy: 'PremiereDate',
      sortOrder: 'Descending',
      minPremiereDate: any(named: 'minPremiereDate'),
      limit: any(named: 'limit'),
      enableTotalRecordCount: false,
    )).thenAnswer((invocation) async => {
      'Items': children?.call(invocation.namedArguments[#limit] as int) ?? [],
    });
    when(() => items.getItems(
      parentId: any(named: 'parentId'),
      includeItemTypes: const ['Movie'],
      recursive: true,
      sortBy: 'PremiereDate',
      sortOrder: 'Descending',
      minPremiereDate: any(named: 'minPremiereDate'),
      filters: any(named: 'filters'),
      limit: any(named: 'limit'),
      fields: any(named: 'fields'),
      enableTotalRecordCount: false,
      enableImageTypes: 'Backdrop,Logo,Banner',
    )).thenAnswer((_) async => {'Items': movies});
    final images = _ImageApi();
    when(
      () => images.getBackdropImageUrl(
        any(),
        tag: any(named: 'tag'),
        maxWidth: any(named: 'maxWidth'),
      ),
    ).thenReturn('backdrop');
    when(
      () => images.getPrimaryImageUrl(
        any(),
        tag: any(named: 'tag'),
        maxWidth: any(named: 'maxWidth'),
      ),
    ).thenReturn('primary');
    final client = _Client();
    when(() => client.userViewsApi).thenReturn(views);
    when(() => client.itemsApi).thenReturn(items);
    when(() => client.imageApi).thenReturn(images);

    final repo = MediaBarRepository(client, prefs);
    GetIt.instance.registerSingleton<MediaBarRepository>(repo);
    final state = await repo.loadItems();
    final shown = (state as MediaBarReady).items.map((item) => item.itemId);
    return (shown.toList(), asked);
  }

  test('episode mode brings each series back once by its latest episode',
      () async {
    final (shown, asked) = await load(RecentlyReleasedSeriesType.episode);

    expect(asked, [
      ['Episode'],
    ]);
    expect(shown, unorderedEquals(['late', 'early']));
  });

  test('season mode keeps the series Silo answers with', () async {
    final (shown, asked) = await load(
      RecentlyReleasedSeriesType.season,
      children: (_) => [_item('a', 'Series'), _item('b', 'Series')],
    );

    expect(asked, [
      ['Season'],
    ]);
    expect(shown, unorderedEquals(['a', 'b']));
  });

  test('a source with no seasons keeps its series', () async {
    final (shown, asked) = await load(
      RecentlyReleasedSeriesType.season,
      children: (_) => const [],
    );

    expect(asked, [
      ['Season'],
      ['Series'],
    ]);
    expect(shown, ['first']);
  });

  test('one show filling the first read is read again at the ceiling',
      () async {
    final (shown, asked) = await load(
      RecentlyReleasedSeriesType.episode,
      children: (limit) => [
        for (var i = 0; i < limit; i++)
          _item('e$i', 'Episode', seriesId: limit > 160 ? 's${i % 5}' : 'daily'),
      ],
    );

    expect(asked, hasLength(2));
    expect(shown, hasLength(5));
  });

  test('recently added brings each series back by its newest episode',
      () async {
    final (shown, _) = await load(
      RecentlyReleasedSeriesType.series,
      source: UserPreferences.mediaBarSourceRecentlyAdded,
    );

    expect(shown, ['late', 'early']);
  });

  for (final mode in [
    RecentlyReleasedSeriesType.episode,
    RecentlyReleasedSeriesType.season,
  ]) {
    for (final collection in [false, true]) {
      for (final movieCount in [1, 8]) {
        test(
          '$mode mixes $movieCount movies into ${collection ? 'collection' : 'mixed library'} slides before limiting',
          () async {
            final (shown, _) = await load(
              mode,
              mixed: true,
              collection: collection,
              children: (_) => [
                for (var i = 0; i < 12; i++)
                  _item(
                    'child$i',
                    mode == RecentlyReleasedSeriesType.season
                        ? 'Season'
                        : 'Episode',
                    seriesId: 's$i',
                  ),
              ],
              movies: [
                for (var i = 0; i < movieCount; i++) _item('m$i', 'Movie'),
              ],
            );

            expect(shown, hasLength(10));
            expect(shown.where((id) => id.startsWith('s')), [
              for (var i = 0; i < (movieCount == 1 ? 9 : 5); i++) 's$i',
            ]);
            expect(shown.where((id) => id.startsWith('m')), [
              for (var i = 0; i < (movieCount == 1 ? 1 : 5); i++) 'm$i',
            ]);
          },
        );
      }
    }
  }

  for (final collection in [false, true]) {
    test('New Releases keeps movies alongside recent series '
        '(collection: $collection)', () async {
      final yesterday = DateTime.now().subtract(const Duration(days: 1)).toUtc().toIso8601String();
      final (shown, _) = await load(
        RecentlyReleasedSeriesType.episode,
        source: UserPreferences.mediaBarSourceNewReleases,
        itemCount: 5,
        mixed: true,
        collection: collection,
        children: (_) => [
          for (var i = 0; i < 20; i++) {
            ..._item('e$i', 'Episode', seriesId: 's$i'),
            'PremiereDate': yesterday,
            'LocationType': 'FileSystem',
          },
        ],
        movies: [{..._item('new-movie', 'Movie'), 'PremiereDate': yesterday}],
      );
      expect(shown, ['s0', 'new-movie', 's1', 's2', 's3']);
    });
  }

  test('series mode still asks for series', () async {
    final (shown, asked) = await load(RecentlyReleasedSeriesType.series);

    expect(asked, [
      ['Series'],
    ]);
    expect(shown, ['first']);
  });
}
