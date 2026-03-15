import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'usbserial_platform_interface.dart';

/// An implementation of [UsbserialPlatform] that uses method channels.
class MethodChannelUsbserial extends UsbserialPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('usbserial');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>('getPlatformVersion');
    return version;
  }
}
