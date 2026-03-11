import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:usb_serial/usb_serial.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: HomePage(),
    );
  }
}

class LocationData {
  final double lat;
  final double lon;
  final DateTime timestamp;

  LocationData({
    required this.lat,
    required this.lon,
    required this.timestamp,
  });
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  UsbPort? _port;
  bool isConnected = false;

  LocationData? currentLocation;

  StreamSubscription<String>? gpsSubscription;

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

      // DEBUG: Show all detected devices first
      for (var d in devices) {
        debugPrint("Device: ${d.deviceName}, VID: ${d.vid ?? ''}, PID: ${d.pid ?? ''}, Serial: ${d.serial ?? ''}");
        showSnack(
          "Device: ${d.deviceName}, VID: ${d.vid} (0x${d.vid?.toRadixString(16)}) | PID: ${d.pid ?? ''} (0x${d.pid?.toRadixString(16)}) | Serial: ${d.serial ?? ''}",
          color: Colors.orange,
        );
        await Future.delayed(const Duration(seconds: 3));
      }

      _port = await devices.first.create();

      if (_port == null) {
        showSnack("Unable to create USB port");
        return;
      }

      bool opened = await _port!.open();

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

      setState(() {
        isConnected = true;
      });

      showSnack("USB Connected Successfully", color: Colors.green);

      startGpsListening();
    } catch (e) {
      showSnack("USB Error: $e");
    }
  }

  void startGpsListening() {
    gpsSubscription = _port!.inputStream!
        .map((data) => data.toList())
        .transform(SystemEncoding().decoder)
        .transform(const LineSplitter())
        .listen((sentence) {
      handleNmeaData(sentence);
    });
  }

  void handleNmeaData(String sentence) {
    if (!sentence.startsWith("\$GPRMC")) {
      return;
    }

    final location = parseNmea(sentence);

    if (location == null) return;

    if (!mounted) return;

    setState(() {
      currentLocation = location;
    });
  }

  LocationData? parseNmea(String sentence) {
    if (!sentence.startsWith("\$GPRMC")) return null;

    final parts = sentence.split(",");

    if (parts.length < 10) return null;

    // Check if GPS fix valid
    if (parts[2] != "A") return null;

    double lat = _convert(parts[3], parts[4]);
    double lon = _convert(parts[5], parts[6]);

    final timeStr = parts[1];
    final dateStr = parts[9];

    final timestamp = parseGpsDateTime(timeStr, dateStr);

    return LocationData(
      lat: lat,
      lon: lon,
      timestamp: timestamp,
    );
  }

  DateTime parseGpsDateTime(String time, String date) {
    final hour = int.parse(time.substring(0, 2));
    final minute = int.parse(time.substring(2, 4));
    final second = int.parse(time.substring(4, 6));

    final day = int.parse(date.substring(0, 2));
    final month = int.parse(date.substring(2, 4));
    final year = 2000 + int.parse(date.substring(4, 6));

    return DateTime.utc(
      year,
      month,
      day,
      hour,
      minute,
      second,
    ).toLocal();
  }

  double _convert(String raw, String direction) {
    double val = double.parse(raw);

    double deg = (val / 100).floorToDouble();
    double min = val - (deg * 100);

    double dec = deg + (min / 60);

    if (direction == "S" || direction == "W") {
      dec *= -1;
    }

    return dec;
  }

  @override
  void dispose() {
    gpsSubscription?.cancel();
    _port?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("USB GPS Reader"),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
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

            if (currentLocation != null) ...[
              Text(
                "Latitude : ${currentLocation!.lat}",
                style: const TextStyle(fontSize: 16),
              ),
              Text(
                "Longitude : ${currentLocation!.lon}",
                style: const TextStyle(fontSize: 16),
              ),
              Text(
                "Time : ${currentLocation!.timestamp}",
                style: const TextStyle(fontSize: 16),
              ),
            ] else
              const Text("Waiting for GPS data..."),

            const SizedBox(height: 30),

            ElevatedButton(
              onPressed: isConnected ? null : connectUsb,
              child: Text(
                isConnected ? "Connected" : "Connect",
                style: const TextStyle(fontSize: 18),
              ),
            ),
          ],
        ),
      ),
    );
  }
}