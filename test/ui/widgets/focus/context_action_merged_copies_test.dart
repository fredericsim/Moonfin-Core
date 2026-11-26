import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:mocktail/mocktail.dart';
import 'package:server_core/server_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:moonfin/auth/models/server.dart';
import 'package:moonfin/auth/models/user.dart';
import 'package:moonfin/auth/repositories/user_repository.dart';
import 'package:moonfin/auth/store/authentication_store.dart';
import 'package:moonfin/data/models/aggregated_item.dart';
import 'package:moonfin/data/repositories/item_mutation_repository.dart';
import 'package:moonfin/data/services/media_server_client_factory.dart';
import 'package:moonfin/data/services/user_data_sync.dart';
import 'package:moonfin/data/utils/merged_copies.dart';
import 'package:moonfin/l10n/app_localizations.dart';
import 'package:moonfin/preference/user_preferences.dart';
import 'package:moonfin/ui/widgets/focus/context_action.dart';

class _MockClient extends Mock implements MediaServerClient {}

class _MockUserLibraryApi extends Mock implements UserLibraryApi {}

class _MockFactory extends Mock implements MediaServerClientFactory {}

class _MockAuthStore extends Mock implements AuthenticationStore {}

class _ItemsApi extends Mock implements ItemsApi {}

Server _server(String id) => Server(
  id: id,
  name: 'Server $id',
  address: 'http://$id',
  version: '10.11.0',
  serverType: ServerType.emby,
  dateAdded: DateTime(2026),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, _MockUserLibraryApi> libraries;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final store = PreferenceStore();
    await store.init();

    userDataSync.reset();
    libraries = {};
    final factory = _MockFactory();
    for (final serverId in ['a', 'b']) {
      final api = _MockUserLibraryApi();
      when(() => api.markFavorite(any())).thenAnswer((_) async {});
      when(() => api.unmarkFavorite(any())).thenAnswer((_) async {});
      when(() => api.markPlayed(any())).thenAnswer((_) async {});
      when(() => api.unmarkPlayed(any())).thenAnswer((_) async {});
      final client = _MockClient();
      when(() => client.userLibraryApi).thenReturn(api);
      when(() => client.serverType).thenReturn(ServerType.emby);
      when(() => client.baseUrl).thenReturn('http://$serverId');
      when(() => client.itemsApi).thenReturn(_ItemsApi());
      when(() => factory.clientForServerOrActive(serverId)).thenReturn(client);
      when(() => factory.getClientIfExists(serverId)).thenReturn(client);
      libraries[serverId] = api;
      if (serverId == 'a') {
        GetIt.instance.registerSingleton<MediaServerClient>(client);
        GetIt.instance.registerSingleton<ItemMutationRepository>(
          ItemMutationRepository(client),
        );
      }
    }
    final auth = _MockAuthStore();
    when(auth.getServers).thenReturn([_server('a'), _server('b')]);

    final users = UserRepository();
    users.setCurrentUser(
      PrivateUser(
        id: 'u1',
        name: 'Test',
        serverId: 'a',
        accessToken: 'token',
        lastUsed: DateTime(2026),
      ),
    );
    GetIt.instance.registerSingleton<MediaServerClientFactory>(factory);
    GetIt.instance.registerSingleton<AuthenticationStore>(auth);
    GetIt.instance.registerSingleton<UserRepository>(users);
    GetIt.instance.registerSingleton<UserPreferences>(UserPreferences(store));
  });

  tearDown(() async {
    userDataSync.reset();
    await GetIt.instance.reset();
  });

  /// One title both servers hold, under the same numeric id unless [idOnB]
  /// says otherwise, as Emby's ids often are.
  AggregatedItem sharedTitle(
    String id, {
    String? idOnB,
    bool initialState = false,
  }) {
    AggregatedItem copy(String serverId, String copyId) => AggregatedItem(
      id: copyId,
      serverId: serverId,
      rawData: {
        'Id': copyId,
        'Type': 'Movie',
        'Name': 'Movie',
        'ProviderIds': {'Tmdb': '603'},
        'UserData': {
          'IsFavorite': initialState,
          'Played': initialState,
          'PlaybackPositionTicks': 123,
          'PlayedPercentage': 50,
        },
      },
    );
    return foldCopies([copy('a', id), copy('b', idOnB ?? id)]).single;
  }

  Future<ItemContextAction> action(
    WidgetTester tester,
    AggregatedItem item, {
    bool played = false,
    VoidCallback? onChanged,
  }) async {
    late List<ItemContextAction> actions;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) {
              actions = contextActionsFor(context, item, onChanged: onChanged);
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    final icon = played
        ? (item.isPlayed
              ? Icons.visibility_off_outlined
              : Icons.visibility_outlined)
        : (item.isFavorite ? Icons.favorite : Icons.favorite_border);
    return actions.firstWhere((a) => a.icon == icon);
  }

  Future<void> select(
    WidgetTester tester,
    AggregatedItem item, {
    bool played = false,
  }) async {
    final selected = await action(tester, item, played: played);
    await selected.onSelect();
    await tester.pump();
  }

  for (final played in [false, true]) {
    for (final fails in [false, true]) {
      for (final initialState in [false, true]) {
        testWidgets(
          'a pending merged ${played ? 'watched' : 'favorite'} change from $initialState stops after ${fails ? 'profile switching' : 'logout'} (${fails ? 'failure' : 'success'})',
          (tester) async {
            final held = Completer<void>();
            final api = libraries['a']!;
            Future<void> firstRequest() => played
                ? (initialState ? api.unmarkPlayed('8') : api.markPlayed('8'))
                : (initialState
                      ? api.unmarkFavorite('8')
                      : api.markFavorite('8'));
            when(firstRequest).thenAnswer((_) => held.future);
            final item = sharedTitle(
              '8',
              idOnB: '9',
              initialState: initialState,
            );
            var changes = 0;
            final selected = await action(
              tester,
              item,
              played: played,
              onChanged: () => changes++,
            );
            final run = selected.onSelect();
            await tester.pump();
            verify(firstRequest).called(1);
            userDataSync.reset();
            GetIt.instance<UserRepository>().setCurrentUser(
              fails
                  ? PrivateUser(
                      id: 'u2',
                      name: 'Other',
                      serverId: 'a',
                      accessToken: 'other',
                      lastUsed: DateTime(2026),
                    )
                  : null,
            );
            final prefs = GetIt.instance<UserPreferences>();
            await prefs.setItemSubtitleStreamIndex('8', 6);
            await prefs.setItemAudioStreamIndex('8', 7);
            for (final copy in copiesOf(item)) {
              userDataSync.publish(copy.id, {
                'IsFavorite': false,
                'Played': false,
                'PlaybackPositionTicks': 456,
              }, serverId: copy.serverId);
            }
            final revision = userDataSync.revision;
            if (fails) {
              held.completeError(StateError('old profile refused'));
            } else {
              held.complete();
            }
            await run;
            await tester.pump();
            verifyNever(() => libraries['b']!.markPlayed(any()));
            verifyNever(() => libraries['b']!.markFavorite(any()));
            verifyNever(() => libraries['b']!.unmarkPlayed(any()));
            verifyNever(() => libraries['b']!.unmarkFavorite(any()));
            expect(userDataSync.revision, revision);
            expect(changes, 0);
            expect(prefs.getItemSubtitleStreamIndex('8'), 6);
            expect(prefs.getItemAudioStreamIndex('8'), 7);
            expect(find.byType(SnackBar), findsNothing);
          },
        );
      }
    }
  }

  for (final pendingServer in ['a', 'b']) {
    testWidgets(
      'a remove while copy $pendingServer is pending wins on every server',
      (tester) async {
        final held = Completer<void>();
        final state = {'a': false, 'b': false};
        final bChanges = <bool>[];
        for (final server in ['a', 'b']) {
          final api = libraries[server]!;
          when(() => api.markFavorite('7')).thenAnswer((_) async {
            if (server == pendingServer) await held.future;
            state[server] = true;
            if (server == 'b') bChanges.add(true);
          });
          when(() => api.unmarkFavorite('7')).thenAnswer((_) async {
            state[server] = false;
            if (server == 'b') bChanges.add(false);
          });
        }
        final item = sharedTitle('7');
        final add = await action(tester, item);
        final adding = add.onSelect();
        await tester.pump();
        verify(() => libraries[pendingServer]!.markFavorite('7')).called(1);
        final remove = await action(tester, userDataSync.apply(item));
        final removing = remove.onSelect();
        await tester.pump();
        held.complete();
        await Future.wait([adding, removing]);
        await tester.pump();
        expect(state, {'a': false, 'b': false});
        expect(bChanges, pendingServer == 'b' ? [true, false] : [false]);
        expect(userDataSync.favoriteFor('7', serverId: 'a'), isFalse);
        expect(userDataSync.favoriteFor('7', serverId: 'b'), isFalse);
        expect(userDataSync.favoriteChangePending('7', serverId: 'b'), isFalse);
      },
    );
  }

  testWidgets('a newer remove from a differently ordered card also wins', (
    tester,
  ) async {
    final held = Completer<void>();
    final state = {'a': false, 'b': false};
    for (final server in ['a', 'b']) {
      final api = libraries[server]!;
      when(() => api.markFavorite('7')).thenAnswer((_) async {
        if (server == 'a') await held.future;
        state[server] = true;
      });
      when(() => api.unmarkFavorite('7')).thenAnswer((_) async {
        state[server] = false;
      });
    }
    final adding = (await action(tester, sharedTitle('7'))).onSelect();
    await tester.pump();
    // Another view of the same title starts with B's copy instead of A's.
    final fromB = foldCopies(
      copiesOf(sharedTitle('7', initialState: true)).reversed.toList(),
    ).single;
    final removing = (await action(tester, fromB)).onSelect();
    await tester.pump();
    held.complete();
    await Future.wait([adding, removing]);
    expect(state, {'a': false, 'b': false});
    expect(userDataSync.favoriteFor('7', serverId: 'b'), isFalse);
  });

  testWidgets('marking every copy watched clears both saved track choices', (
    tester,
  ) async {
    final prefs = GetIt.instance<UserPreferences>();
    for (final id in ['8', '9']) {
      await prefs.setItemSubtitleStreamIndex(id, 3);
      await prefs.setItemAudioStreamIndex(id, 4);
    }
    await select(tester, sharedTitle('8', idOnB: '9'), played: true);
    for (final id in ['8', '9']) {
      expect(prefs.getItemSubtitleStreamIndex(id), -2);
      expect(prefs.getItemAudioStreamIndex(id), -2);
    }
  });

  testWidgets('a favorite reaches every server even when the ids match', (
    tester,
  ) async {
    await select(tester, sharedTitle('7'));

    verify(() => libraries['a']!.markFavorite('7')).called(1);
    verify(() => libraries['b']!.markFavorite('7')).called(1);
    expect(userDataSync.favoriteFor('7', serverId: 'a'), isTrue);
    expect(userDataSync.favoriteFor('7', serverId: 'b'), isTrue);
  });

  testWidgets('a copy whose id another server already marked a favorite is '
      'still sent', (tester) async {
    // Another title on server a already uses the id of b's copy.
    userDataSync.publish('10', {'IsFavorite': true});

    await select(tester, sharedTitle('9', idOnB: '10'));

    verify(() => libraries['a']!.markFavorite('9')).called(1);
    verify(() => libraries['b']!.markFavorite('10')).called(1);
  });

  for (final played in [false, true]) {
    for (final initialState in [false, true]) {
      for (final refused in ['a', 'b']) {
        testWidgets(
          'partial ${played ? 'watched' : 'favorite'} change from $initialState '
          'only updates the successful copy (refused: $refused)',
          (tester) async {
            final item = sharedTitle(
              '8',
              idOnB: '9',
              initialState: initialState,
            );
            final copies = copiesOf(item);
            final prefs = GetIt.instance<UserPreferences>();
            for (final copy in copies) {
              await prefs.setItemSubtitleStreamIndex(copy.id, 3);
              await prefs.setItemAudioStreamIndex(copy.id, 4);
              userDataSync.publish(
                copy.id,
                Map<String, dynamic>.from(copy.rawData['UserData'] as Map),
                serverId: copy.serverId,
              );
            }
            Future<void> mutate(String server) {
              final api = libraries[server]!;
              final id = server == 'a' ? '8' : '9';
              if (played) {
                return initialState ? api.unmarkPlayed(id) : api.markPlayed(id);
              }
              return initialState
                  ? api.unmarkFavorite(id)
                  : api.markFavorite(id);
            }

            when(() => mutate(refused)).thenThrow(StateError('refused'));

            await select(tester, item, played: played);

            for (final copy in copies) {
              verify(() => mutate(copy.serverId)).called(1);
              final resetTracks =
                  played && !initialState && copy.serverId != refused;
              expect(
                prefs.getItemSubtitleStreamIndex(copy.id),
                resetTracks ? -2 : 3,
              );
              expect(
                prefs.getItemAudioStreamIndex(copy.id),
                resetTracks ? -2 : 4,
              );
              final updated = userDataSync.apply(copy);
              final expected = copy.serverId == refused
                  ? initialState
                  : !initialState;
              expect(played ? updated.isPlayed : updated.isFavorite, expected);
              expect(
                updated.playbackPositionTicks,
                played && copy.serverId != refused ? 0 : 123,
              );
              expect(
                updated.playedPercentage,
                played && copy.serverId != refused ? null : 50,
              );
            }
            expect(find.text('Not changed on Server $refused'), findsOneWidget);
          },
        );
      }
    }
  }
}
