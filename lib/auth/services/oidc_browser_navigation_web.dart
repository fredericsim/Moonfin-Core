import 'package:web/web.dart' as web;

String? oidcBrowserPageOrigin() {
  final uri = Uri.tryParse(web.window.location.href);
  return uri?.origin;
}

bool openOidcInCurrentTab(Uri uri) {
  web.window.location.assign(uri.toString());
  return true;
}
