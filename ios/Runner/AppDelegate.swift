import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {

  /// Held for the process's lifetime. The player owns the AVAudioSession, so
  /// letting it deallocate would silence the app.
  private var player: AuvyPlayer?
  private var cookies: AuvyCookies?
  private var systemChannels: AuvySystemChannels?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // What's New's check with Auvy closed. iOS needs the handler registered
    // before launch finishes, including a launch made only to run it.
    AuvyWhatsNewBackground.register()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // `native_player` is hand-rolled rather than a pub plugin, exactly as it is on
    // Android — and registering it is what tells Dart this engine HAS A SCREEN.
    // main() probes the channel before runApp and refuses to start the app when it
    // is missing, so without this line the app launches to a white screen.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "AuvyPlayer") {
      let messenger = registrar.messenger()
      player = AuvyPlayer(messenger: messenger)
      // Sign-in, and the cookies that prove it — see AuvyCookies.
      cookies = AuvyCookies(messenger: messenger)
      // Haptics, toast, region, window, icon, backup, folder, output, and honest
      // answers for the Android-only ones. See AuvySystemChannels.
      systemChannels = AuvySystemChannels(messenger: messenger)
    }
  }
}
