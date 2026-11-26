import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:server_core/server_core.dart';

import '../../util/server_url.dart';
import '../models/aggregated_item.dart';
import 'media_server_client_factory.dart';

typedef _UserDataKey = ({String? serverId, String itemId});

/// The newest watched state, resume position and favourite flag this client
/// knows about, for every item a screen is still holding.
/// Item IDs are scoped to their source server. Calls without an explicit
/// server use the active client.
///
/// A list carries the user data the server sent when it was fetched, and a
/// screen parked under a pushed route never asks again, so finishing an episode
/// used to leave every view behind it showing the old ticks until the app was
/// restarted. Anything that changes user data publishes here instead, and the
/// screens patch the items they already hold.
///
/// The socket only reports the changed item and one level above it, so an
/// episode brings its season but never the series holding the unwatched count.
/// That is what [refreshFromServer] is for.
class UserDataSync extends ChangeNotifier {
  /// Ids travel in the query string, so a whole paged-in library goes up in
  /// batches this size.
  static const _refreshChunkSize = 100;

  /// Enough for every list a session realistically keeps alive, and bounded so
  /// a long browse can't grow this without end.
  static const _maxTrackedItems = 2000;

  final Map<_UserDataKey, Map<String, dynamic>> _userData = {};
  final Map<_UserDataKey, int> _itemRevisions = {};
  final Map<_UserDataKey, bool> _pendingFavorites = {};
  final Map<_UserDataKey, bool> _confirmedFavorites = {};
  int _revision = 0;
  int get revision => _revision;
  int revisionFor(String itemId, {String? serverId}) =>
      _itemRevisions[_key(itemId, serverId: serverId)] ?? 0;

  // Older lists carry URLs while merged lists carry saved server IDs. Both
  // must address the same server, without mixing equal item IDs across servers.
  String? _serverScope(String? serverId) {
    final getIt = GetIt.instance;
    if (serverId == null || serverId.isEmpty) {
      return getIt.isRegistered<MediaServerClient>()
          ? normalizeServerBaseUrl(getIt<MediaServerClient>().baseUrl)
          : null;
    }
    if (serverId.contains('://')) return normalizeServerBaseUrl(serverId);
    if (getIt.isRegistered<MediaServerClientFactory>()) {
      final client = getIt<MediaServerClientFactory>().getClientIfExists(
        serverId,
      );
      if (client != null) return normalizeServerBaseUrl(client.baseUrl);
    }
    return serverId;
  }

  _UserDataKey _key(String itemId, {String? serverId}) =>
      (serverId: _serverScope(serverId), itemId: itemId);

  /// Bumped by [reset], so work queued for one user can tell it is stale.
  int get session => _session;
  int _session = 0;

  /// Shows [value] as the favorite flag straight away, before the server
  /// has it, so a quick next toggle starts from what the user last chose.
  void requestFavorite(String itemId, bool value, {String? serverId}) {
    final key = _key(itemId, serverId: serverId);
    if (!_pendingFavorites.containsKey(key)) {
      _confirmedFavorites[key] =
          favoriteFor(itemId, serverId: serverId) ?? !value;
    }
    _pendingFavorites[key] = value;
    publish(itemId, {'IsFavorite': value}, serverId: serverId);
  }

  /// The flag the user last asked for, while the server is catching up.
  bool? pendingFavorite(String itemId, {String? serverId}) =>
      _pendingFavorites[_key(itemId, serverId: serverId)];

  /// The flag the server last confirmed for a change still in progress.
  bool? confirmedFavorite(String itemId, {String? serverId}) =>
      _confirmedFavorites[_key(itemId, serverId: serverId)];

  /// The server now holds [value]. The change ends if that's what was asked.
  void confirmFavorite(String itemId, bool value, {String? serverId}) {
    final key = _key(itemId, serverId: serverId);
    _confirmedFavorites[key] = value;
    if (_pendingFavorites[key] != value) return;
    _pendingFavorites.remove(key);
    _confirmedFavorites.remove(key);
    _itemRevisions[key] = ++_revision;
  }

  /// Drops the change and shows what the server last confirmed.
  void failFavoriteChange(String itemId, {String? serverId}) {
    final key = _key(itemId, serverId: serverId);
    final confirmed = _confirmedFavorites.remove(key);
    if (_pendingFavorites.remove(key) == null) return;
    _itemRevisions[key] = ++_revision;
    if (confirmed != null) {
      publish(itemId, {'IsFavorite': confirmed}, serverId: serverId);
    }
  }

  bool favoriteChangePending(String itemId, {String? serverId}) =>
      _pendingFavorites.containsKey(_key(itemId, serverId: serverId));
  StreamSubscription<ServerWebSocketMessage>? _socketSubscription;

  /// The synced favorite flag, or null when none is known.
  bool? favoriteFor(String itemId, {String? serverId}) {
    final key = _key(itemId, serverId: serverId);
    return _pendingFavorites[key] ?? _userData[key]?['IsFavorite'] as bool?;
  }

  /// Records this client's own change before the server confirms it. Merges, so
  /// a patch that only carries `Played` leaves a known play count alone.
  void publish(
    String itemId,
    Map<String, dynamic> userData, {
    String? serverId,
  }) {
    publishAll({itemId: userData}, serverId: serverId);
  }

  /// [replace] is for values that came from the server, which always sends an
  /// item's whole user data and is therefore allowed to undo an optimistic
  /// patch that turned out to be wrong.
  void publishAll(
    Map<String, Map<String, dynamic>> changes, {
    bool replace = false,
    String? serverId,
  }) {
    if (changes.isEmpty) return;
    var changed = false;
    changes.forEach((itemId, patch) {
      if (itemId.isEmpty || patch.isEmpty) return;
      final key = _key(itemId, serverId: serverId);
      final existing = _userData[key];
      // The server leaves out a percentage it has cleared, and a missing key
      // would keep the old progress bar on the item it is merged into. Only a
      // whole user data record says that, and every server's record carries
      // the position: a partial one (a Silo event whose read-back failed, only
      // `IsFavorite` or `Played`) says nothing about progress.
      final merged = replace
          ? <String, dynamic>{
              if (patch.containsKey('PlaybackPositionTicks'))
                'PlayedPercentage': null,
              ...patch,
            }
          : <String, dynamic>{...?existing, ...patch};
      if (_pendingFavorites.containsKey(key)) {
        merged['IsFavorite'] = _pendingFavorites[key];
      }
      if (existing != null && mapEquals(existing, merged)) return;
      _userData[key] = merged;
      _itemRevisions[key] = ++_revision;
      changed = true;
    });
    if (!changed) return;
    _evictOverflow();
    notifyListeners();
  }

  /// Returns [item] itself when nothing newer is known, so callers can compare
  /// with `identical` and skip rebuilding a list that did not move.
  AggregatedItem apply(AggregatedItem item) {
    final patch =
        _userData[_key(item.id, serverId: item.serverId)] ??
        // Preserve unbound single-server use before a client is registered.
        (_serverScope(null) == null
            ? _userData[(serverId: null, itemId: item.id)]
            : null);
    if (patch == null) return item;
    final current = item.rawData['UserData'];
    if (current is Map && _alreadyHolds(current, patch)) return item;
    final merged = <String, dynamic>{
      if (current is Map) ...Map<String, dynamic>.from(current),
      ...patch,
    };
    return AggregatedItem(
      id: item.id,
      serverId: item.serverId,
      rawData: {...item.rawData, 'UserData': merged},
    );
  }

  AggregatedItem? applyOrNull(AggregatedItem? item) =>
      item == null ? null : apply(item);

  /// Returns [items] itself when no entry changed, which keeps list identity
  /// stable for the caches that key off it.
  List<AggregatedItem> applyAll(List<AggregatedItem> items) {
    if (_userData.isEmpty || items.isEmpty) return items;
    List<AggregatedItem>? patched;
    for (var i = 0; i < items.length; i++) {
      final updated = apply(items[i]);
      if (identical(updated, items[i])) continue;
      patched ??= List<AggregatedItem>.of(items);
      patched[i] = updated;
    }
    return patched ?? items;
  }

  /// Asks the server what it now holds for [itemIds]. Covers the ancestors the
  /// socket never mentions, and changes that landed while the socket was down.
  Future<void> refreshFromServer(
    MediaServerClient client,
    Iterable<String> itemIds, {
    String? serverId,
  }) async {
    final source = serverId ?? client.baseUrl;
    final session = _session;
    final all = <String>{
      for (final id in itemIds)
        if (id.isNotEmpty) id,
    }.toList();
    // A server that reads items one at a time narrows the list to what may
    // have changed (Silo).
    final api = client.itemsApi;
    final ids = api is UserDataRefreshScope
        ? (api as UserDataRefreshScope).userDataMayHaveChanged(all)
        : all;
    if (ids.isEmpty) return;

    for (var start = 0; start < ids.length; start += _refreshChunkSize) {
      final chunk = ids.sublist(
        start,
        min(start + _refreshChunkSize, ids.length),
      );
      try {
        final data = await client.itemsApi.getItems(
          ids: chunk,
          fields: 'UserData',
          recursive: true,
          limit: chunk.length,
          enableTotalRecordCount: false,
        );
        final changes = <String, Map<String, dynamic>>{};
        for (final raw in (data['Items'] as List? ?? const [])) {
          if (raw is! Map) continue;
          final id = raw['Id']?.toString();
          final userData = raw['UserData'];
          if (id == null || id.isEmpty || userData is! Map) continue;
          changes[id] = Map<String, dynamic>.from(userData);
        }
        if (_session != session) return;
        publishAll(changes, replace: true, serverId: source);
      } catch (_) {
        // A dropped connection or a library the user lost access to. The next
        // visit asks again.
      }
    }
  }

  /// Follows the session websocket for the signed-in user. Safe to call again
  /// on a reconnect or a user switch, which drops the previous subscription.
  void bindTo(
    Stream<ServerWebSocketMessage> events, {
    String? userId,
    String? serverId,
  }) {
    _socketSubscription?.cancel();
    final source = _serverScope(serverId);
    final expectedUser = _normalizeId(userId);
    _socketSubscription = events.listen((event) {
      if (event is! UserDataChangedMessage) return;
      // The server only sends this to the owning user's sessions. The check is
      // so a binding left over from the last account can't write over this one.
      final messageUser = _normalizeId(event.userId);
      if (expectedUser != null &&
          messageUser != null &&
          messageUser != expectedUser) {
        return;
      }
      final changes = <String, Map<String, dynamic>>{};
      for (final entry in event.userDataList) {
        final id = entry['ItemId']?.toString();
        if (id == null || id.isEmpty) continue;
        final patch = Map<String, dynamic>.from(entry)..remove('ItemId');
        if (patch.isNotEmpty) changes[id] = patch;
      }
      publishAll(changes, replace: true, serverId: source);
    });
  }

  /// Drops everything on sign-out or a user switch, so one account's watched
  /// state is never painted onto another's library.
  void reset() {
    _socketSubscription?.cancel();
    _socketSubscription = null;
    _session++;
    if (_userData.isEmpty && _pendingFavorites.isEmpty) return;
    _userData.clear();
    _itemRevisions.clear();
    _pendingFavorites.clear();
    _confirmedFavorites.clear();
    _revision++;
    notifyListeners();
  }

  void _evictOverflow() {
    if (_userData.length <= _maxTrackedItems) return;
    // Insertion ordered, so the front is what has gone longest without a
    // change. Anything still on screen is refreshed on the next visit.
    final excess = _userData.length - _maxTrackedItems;
    for (final key in _userData.keys.take(excess).toList()) {
      _userData.remove(key);
      _itemRevisions.remove(key);
    }
  }

  /// Values are flat scalars, so this is a key by key compare. A null in the
  /// patch clears a field, which a missing key already says.
  static bool _alreadyHolds(Map current, Map<String, dynamic> patch) {
    for (final entry in patch.entries) {
      if (!current.containsKey(entry.key)) {
        if (entry.value == null) continue;
        return false;
      }
      if (current[entry.key] != entry.value) return false;
    }
    return true;
  }

  static String? _normalizeId(String? id) {
    if (id == null) return null;
    final normalized = id.replaceAll('-', '').toLowerCase();
    return normalized.isEmpty ? null : normalized;
  }

  @override
  void dispose() {
    _socketSubscription?.cancel();
    super.dispose();
  }
}

/// Process wide, because the lists that need patching outlive any one screen or
/// server client.
final userDataSync = UserDataSync();
