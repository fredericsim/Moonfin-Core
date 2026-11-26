import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/data/models/aggregated_library.dart';
import 'package:moonfin/l10n/app_localizations.dart';
import 'package:moonfin/l10n/app_localizations_en.dart';
import 'package:moonfin/ui/navigation/destinations.dart';
import 'package:moonfin/ui/widgets/nav_styles/atlas_panel.dart';
import 'package:moonfin/ui/widgets/nav_styles/nav_art.dart';
import 'package:moonfin/ui/widgets/nav_styles/nav_entry.dart';
import 'package:moonfin/ui/widgets/nav_styles/nav_focusable.dart';
import 'package:moonfin/ui/widgets/nav_styles/reel_nav.dart';

void main() {
  group('reelSlots', () {
    test('shows three entries each side and wraps around the list', () {
      final slots = reelSlots(0, 13);
      expect(slots.map((s) => s.distance), [-3, -2, -1, 0, 1, 2, 3]);
      expect(slots.map((s) => s.entry), [10, 11, 12, 0, 1, 2, 3]);
      final window = slots.firstWhere((s) => s.distance == 0);
      expect(window.scale, 1);
      expect(window.opacity, 1);
      expect(window.dy, 0);
      expect(slots.first.dy, lessThan(0));
      expect(slots.last.dy, greaterThan(0));
    });

    test('keys entries by their place on the endless wheel', () {
      final before = reelSlots(5, 13);
      final after = reelSlots(6, 13);
      final movedUp = after.firstWhere((s) => s.absolute == 6);
      expect(before.firstWhere((s) => s.absolute == 6).distance, 1);
      expect(movedUp.distance, 0);
      expect(reelSlots(-1, 13).firstWhere((s) => s.distance == 0).entry, 12);
    });

    test('a short list never shows an entry twice', () {
      for (var count = 1; count <= 7; count++) {
        final entries = reelSlots(4, count).map((s) => s.entry).toList();
        expect(entries.toSet().length, entries.length, reason: '$count');
      }
      expect(reelSlots(0, 0), isEmpty);
    });

    test('phones show four entries each side', () {
      expect(reelSlots(0, 13, phone: true).length, 9);
    });
  });

  test('currentNavEntryIndex picks the page on screen, then Home', () {
    NavEntry entry(String id, {bool current = false, bool home = false}) =>
        NavEntry(
          id: id,
          label: id,
          onSelect: () {},
          current: current,
          kind: home ? NavEntryKind.home : NavEntryKind.other,
        );
    expect(currentNavEntryIndex([]), 0);
    expect(currentNavEntryIndex([entry('a'), entry('b')]), 0);
    expect(currentNavEntryIndex([entry('a'), entry('h', home: true)]), 1);
    expect(
      currentNavEntryIndex([
        entry('h', home: true),
        entry('a'),
        entry('b', current: true),
      ]),
      2,
    );
  });

  group('atlasLibraryLinks', () {
    final l10n = AppLocalizationsEn();
    AggregatedLibrary lib(String type, {String name = 'Lib'}) =>
        AggregatedLibrary(
          id: 'abc',
          name: name,
          collectionType: type,
          serverId: 's1',
        );

    test('movies link to their genres and favorites', () {
      final links = atlasLibraryLinks(l10n, lib('movies'));
      expect(links.map((l) => l.label), [
        l10n.browseAll,
        l10n.genres,
        l10n.favorites,
      ]);
      expect(links.first.route, Destinations.library('abc', serverId: 's1'));
      expect(
        links[1].route,
        Destinations.libraryGenresOf('abc', serverId: 's1'),
      );
      expect(Uri.parse(links[1].route).queryParameters['serverId'], 's1');
    });

    test('music links to its category screens', () {
      final links = atlasLibraryLinks(l10n, lib('music'));
      expect(links.first.route, Destinations.musicLibrary('abc'));
      expect(links.skip(1).map((l) => l.route), [
        for (final c in ['albums', 'artists', 'playlists', 'genres', 'songs'])
          Destinations.musicCategory('abc', c),
      ]);
    });

    test('books only offer their main page', () {
      expect(atlasLibraryLinks(l10n, lib('books')).length, 1);
    });
  });

  test('library covers size to the screen\'s real density', () {
    // A Mosaic tile on a 2.75x phone, past the 2x cap other artwork stops at.
    final phone = navLibraryCoverSize(const Size(154, 81), 2.75);
    expect(phone.decode, 440);
    expect(phone.request, 480);

    // A box taller than 16:9 is covered by the height, so the width follows it.
    final tall = navLibraryCoverSize(const Size(100, 100), 2);
    expect(tall.decode, 360);
    expect(tall.request, 480);
  });

  group('AtlasPanel', () {
    Future<void> open(
      WidgetTester tester,
      AtlasPanelSpec spec, {
      double? panelWidth,
      List<String>? opened,
    }) async {
      final scope = FocusScopeNode();
      final first = FocusNode();
      addTearDown(scope.dispose);
      addTearDown(first.dispose);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.only(top: 80),
              child: Align(
                alignment: Alignment.topCenter,
                child: SizedBox(
                  width: panelWidth,
                  child: AtlasPanel(
                    spec: spec,
                    scopeNode: scope,
                    firstFocus: first,
                    onExit: () {},
                    onOpen: (route, {required topLevel}) => opened?.add(route),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    Future<void> close(WidgetTester tester) =>
        tester.pumpWidget(const SizedBox());

    AtlasPanelSpec spec(String key, Future<AtlasPanelData> Function() load) =>
        AtlasPanelSpec(
          key: key,
          title: 'Movies',
          links: const [AtlasLink('Browse All', '/library')],
          cardsTitle: 'Continue',
          load: load,
        );

    const data = AtlasPanelData(
      cards: [AtlasTile(title: 'Loaded Card', route: '/item')],
    );

    AtlasPanelSpec fullPreview(String key) => AtlasPanelSpec(
      key: key,
      title: 'Movies',
      links: const [
        AtlasLink('Browse All', '/library'),
        AtlasLink('Genres', '/genres'),
        AtlasLink('Favorites', '/favorites'),
      ],
      cardsTitle: 'Continue',
      postersTitle: 'Recently Added',
      load: () async => AtlasPanelData(
        cards: [
          for (var i = 0; i < 2; i++)
            AtlasTile(title: 'Continue $i', route: '/continue/$i'),
        ],
        posters: [
          for (var i = 0; i < 4; i++)
            AtlasTile(title: 'Poster $i', route: '/poster/$i'),
        ],
      ),
    );

    Finder tile(String title) => find.byWidgetPredicate(
      (widget) => widget is NavFocusable && widget.semanticLabel == title,
    );

    testWidgets(
      'desktop preview fits when resizing between wide and 1024 pixel windows',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1920, 1080);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        await open(tester, fullPreview('test:responsive'));
        final first = tester
            .widget<AtlasPanel>(find.byType(AtlasPanel))
            .firstFocus;
        first.requestFocus();
        await tester.pumpAndSettle();
        for (final size in [
          const Size(1920, 1080),
          const Size(1024, 768),
          const Size(1280, 720),
          const Size(1920, 1080),
        ]) {
          tester.view.physicalSize = size;
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(first.hasFocus, isTrue);
          for (final title in [
            'Continue 0',
            'Continue 1',
            'Poster 0',
            'Poster 1',
            'Poster 2',
            'Poster 3',
          ]) {
            final rect = tester.getRect(tile(title));
            expect(rect.left, greaterThanOrEqualTo(0));
            expect(rect.right, lessThanOrEqualTo(size.width));
            expect(rect.bottom, lessThanOrEqualTo(size.height));
            expect(tile(title).hitTestable(), findsOneWidget);
          }
        }
      },
    );

    testWidgets(
      'desktop preview uses its constrained width inside a larger window',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1920, 1080);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        await open(tester, fullPreview('test:constrained'), panelWidth: 1024);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final panel = tester.getRect(find.byType(AtlasPanel));
        expect(panel.width, 1024);
        for (var i = 0; i < 4; i++) {
          final rect = tester.getRect(tile('Poster $i'));
          expect(rect.left, greaterThanOrEqualTo(panel.left));
          expect(rect.right, lessThanOrEqualTo(panel.right));
        }
      },
    );

    testWidgets(
      'short desktop windows can scroll to and open the last poster',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(800, 480);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final opened = <String>[];
        await open(tester, fullPreview('test:short'), opened: opened);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(tile('Poster 3'));
        await tester.pumpAndSettle();
        expect(tester.getRect(tile('Poster 3')).bottom, lessThanOrEqualTo(480));
        await tester.tap(tile('Poster 3'));
        expect(opened, ['/poster/3']);
      },
    );

    testWidgets('a failed load tries again on the next open', (tester) async {
      var calls = 0;
      final failing = spec('test:retry', () async {
        calls++;
        if (calls == 1) throw Exception('offline');
        return data;
      });
      await open(tester, failing);
      expect(find.text('Loaded Card'), findsNothing);
      await close(tester);
      await open(tester, failing);
      expect(calls, 2);
      expect(find.text('Loaded Card'), findsOneWidget);
    });

    testWidgets('a load that worked is kept for the next open', (tester) async {
      var calls = 0;
      final working = spec('test:kept', () async {
        calls++;
        return data;
      });
      await open(tester, working);
      await close(tester);
      await open(tester, working);
      expect(calls, 1);
      expect(find.text('Loaded Card'), findsOneWidget);
    });
  });
}
