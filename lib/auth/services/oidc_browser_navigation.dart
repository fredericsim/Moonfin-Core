import 'oidc_browser_navigation_stub.dart'
    if (dart.library.js_interop) 'oidc_browser_navigation_web.dart'
    as impl;

String? oidcBrowserPageOrigin() => impl.oidcBrowserPageOrigin();

bool openOidcInCurrentTab(Uri uri) => impl.openOidcInCurrentTab(uri);
