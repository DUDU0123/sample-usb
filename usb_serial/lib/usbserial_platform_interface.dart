import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'usbserial_method_channel.dart';

abstract class UsbserialPlatform extends PlatformInterface {
  /// Constructs a UsbserialPlatform.
  UsbserialPlatform() : super(token: _token);

  static final Object _token = Object();

  static UsbserialPlatform _instance = MethodChannelUsbserial();

  /// The default instance of [UsbserialPlatform] to use.
  ///
  /// Defaults to [MethodChannelUsbserial].
  static UsbserialPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [UsbserialPlatform] when
  /// they register themselves.
  static set instance(UsbserialPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
