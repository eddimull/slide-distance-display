// Google's own sign-in button, which web requires (it can't be started
// from app UI there). Only call [renderButton] on web.
export 'google_button_stub.dart'
    if (dart.library.js_interop) 'google_button_web.dart';
