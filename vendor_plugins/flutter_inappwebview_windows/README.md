# flutter\_inappwebview\_windows

The Windows WebView2 implementation of [`flutter_inappwebview`](https://pub.dev/packages/flutter_inappwebview).

## Usage

This package is [endorsed](https://flutter.dev/docs/development/packages-and-plugins/developing-packages#endorsed-federated-plugin),
which means you can simply use `flutter_inappwebview`
normally. This package will be automatically included in your app when you do,
so you do not need to add it to your `pubspec.yaml`.

However, if you `import` this package to use any of its APIs directly, you
should add it to your `pubspec.yaml` as usual.

## Local fixes

`CookieManager.getCookies` and `getCookie` honor `webViewController` by querying
that WebView's `Network.getCookies` DevTools method. The environment's hidden
ordinary WebView cannot read an InPrivate login window's cookies. Reads with a
controller never fall back to another profile, including when the result is
empty or the window has closed. Calls without a controller retain the original
environment-based behavior. DevTools expiry times are converted from seconds
to milliseconds, and HttpOnly cookies remain available to the native caller.

The application keeps Windows authorization popups in the opener's InPrivate
profile; Android retains its separate popup policy.
