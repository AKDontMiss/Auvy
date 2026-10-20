/// No Dart API: the plugin exists for its Android side, which reports each
/// Flutter engine to the app (see android/.../AuvyEngineHookPlugin.kt). Flutter
/// attaches plugins to every engine it creates, including the one audio_service
/// starts in the background, which an Activity's configureFlutterEngine never
/// sees.
library;
