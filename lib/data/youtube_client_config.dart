// Configuration class for various YouTube client identities used to fetch streams.
class YouTubeClientConfig {
  final String name;
  final String version;
  final String userAgent;
  final String clientId;
  final String? osName;
  final String? osVersion;
  final String? deviceMake;
  final String? deviceModel;
  final String? androidSdkVersion;
  final bool useSignatureTimestamp;

  const YouTubeClientConfig({
    required this.name,
    required this.version,
    required this.userAgent,
    required this.clientId,
    this.osName,
    this.osVersion,
    this.deviceMake,
    this.deviceModel,
    this.androidSdkVersion,
    this.useSignatureTimestamp = false,
  });

  // Client configuration for Chromecast devices.
  static const tvHtml5 = YouTubeClientConfig(
    name: 'TVHTML5',
    version: '7.20190101',
    userAgent: 'Mozilla/5.0 (Chromecast)',
    clientId: '36',
    osName: 'TV', 
    osVersion: '10.0',
    deviceMake: '',
    deviceModel: '',
    useSignatureTimestamp: false,
  );

  // Client configuration for web browsers.
  static const webRemix = YouTubeClientConfig(
    name: 'WEB_REMIX',
    version: '1.20250310.01.00',
    userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:128.0) Gecko/20100101 Firefox/128.0',
    clientId: '67',
    osName: 'Windows',
    osVersion: '10.0',
    deviceMake: '',
    deviceModel: '',
    useSignatureTimestamp: false,
  );

  // Client configuration mimicking the Android VR app for Oculus.
  static const androidVr = YouTubeClientConfig(
    name: 'ANDROID_VR',
    version: '1.61.48',
    userAgent: 'com.google.android.apps.youtube.vr.oculus/1.61.48 (Linux; U; Android 12; en_US; Quest 3; Build/SQ3A.220605.009.A1; Cronet/132.0.6808.3)',
    clientId: '28',
    osName: 'Android',
    osVersion: '12',
    deviceMake: 'Oculus',
    deviceModel: 'Quest 3',
    useSignatureTimestamp: false,
  );

  // Client configuration for iOS devices.
  static const ios = YouTubeClientConfig(
    name: 'IOS',
    version: '20.10.4',
    userAgent: 'com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)',
    clientId: '5',
    osVersion: '18.3.2.22D82',
    useSignatureTimestamp: false,
  );

  // List of all available client configurations.
  static const List<YouTubeClientConfig> all = [tvHtml5, webRemix, androidVr, ios];
}