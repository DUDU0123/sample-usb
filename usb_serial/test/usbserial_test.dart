// import 'package:flutter_test/flutter_test.dart';
// import 'package:usbserial/usbserial.dart';
// import 'package:usbserial/usbserial_platform_interface.dart';
// import 'package:usbserial/usbserial_method_channel.dart';
// import 'package:plugin_platform_interface/plugin_platform_interface.dart';

// class MockUsbserialPlatform
//     with MockPlatformInterfaceMixin
//     implements UsbserialPlatform {

//   @override
//   Future<String?> getPlatformVersion() => Future.value('42');
// }

// void main() {
//   final UsbserialPlatform initialPlatform = UsbserialPlatform.instance;

//   test('$MethodChannelUsbserial is the default instance', () {
//     expect(initialPlatform, isInstanceOf<MethodChannelUsbserial>());
//   });

//   test('getPlatformVersion', () async {
//     Usbserial usbserialPlugin = Usbserial();
//     MockUsbserialPlatform fakePlatform = MockUsbserialPlatform();
//     UsbserialPlatform.instance = fakePlatform;

//     expect(await usbserialPlugin.getPlatformVersion(), '42');
//   });
// }
