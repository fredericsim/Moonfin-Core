import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/ui/navigation/destinations.dart';
import 'package:moonfin/ui/screens/auth/startup_screen.dart';

void main() {
  test(
    'hosted plugin mode imports browser credentials before user selection',
    () {
      expect(
        unauthenticatedStartupRoute(
          targetServerId: 'known-server',
          webPluginMode: true,
        ),
        Destinations.serverSelect,
      );
    },
  );

  test('normal builds still open a known server directly', () {
    expect(
      unauthenticatedStartupRoute(
        targetServerId: 'known-server',
        webPluginMode: false,
      ),
      '${Destinations.server}?serverId=known-server',
    );
    expect(
      unauthenticatedStartupRoute(targetServerId: null, webPluginMode: false),
      Destinations.serverSelect,
    );
  });
}
