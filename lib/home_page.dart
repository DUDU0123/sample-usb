import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:usb_serial/usb_serial.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  UsbPort? _port;
  bool isConnected = false;

  void showSnack(String message, {Color color = Colors.red}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: color,
      ),
    );
  }

  Future<void> connectUsb() async {
    try {
      final devices = await UsbSerial.listDevices();

      if (devices.isEmpty) {
        showSnack("No USB device found");
        return;
      }

      _port = await devices.first.create();
      if (_port == null) {
        showSnack("Unable to create USB port");
        return;
      }

      final opened = await _port!.open();
      if (!opened) {
        showSnack("Failed to open USB connection");
        return;
      }

      await _port!.setDTR(true);
      await _port!.setRTS(true);

      await _port!.setPortParameters(
        115200,
        UsbPort.DATABITS_8,
        UsbPort.STOPBITS_1,
        UsbPort.PARITY_NONE,
      );

      if (!mounted) return;
      setState(() => isConnected = true);

      showSnack("USB Connected Successfully", color: Colors.green);

      _port!.inputStream?.listen(
        (Uint8List data) {
          debugPrint("Received: $data");
        },
        onDone: () {
          if (mounted) {
            setState(() => isConnected = false);
            showSnack("USB Disconnected");
          }
        },
        onError: (_) {
          showSnack("USB Connection Error");
        },
      );

      await _port!.write(Uint8List.fromList([0x10, 0x00]));
    } catch (e) {
      showSnack("USB Error: $e");
    }
  }

  @override
  void dispose() {
    _port?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              isConnected ? "Connected ✅" : "Connect to USB",
              style: TextStyle(
                color: isConnected ? Colors.green : Colors.red,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: isConnected ? null : connectUsb,
              child: Text(
                isConnected ? "Connected" : "Connect",
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}