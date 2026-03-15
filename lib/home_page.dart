import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:usb_serial/transaction.dart';
import 'package:usb_serial/usb_serial.dart';

// ── Palette ───────────────────────────────────────────────────────────────────
const _bg      = Color(0xFF0A0E14);
const _surface = Color(0xFF111820);
const _card    = Color(0xFF161D27);
const _border  = Color(0xFF1E2A38);
const _accent  = Color(0xFF00D4AA);
const _green   = Color(0xFF39D353);
const _red     = Color(0xFFFF5F57);
const _amber   = Color(0xFFFFB347);
const _blue    = Color(0xFF58A6FF);
const _textPri = Color(0xFFD4E4F7);
const _textSub = Color(0xFF5A7A96);
const _mono    = 'monospace';

// ═════════════════════════════════════════════════════════════════════════════
// FileLogger — pure Dart, zero method channels
//
// Log is written to: <app-documents>/gps_debug.log
// Pull via adb:  adb pull /data/data/<your.package>/files/gps_debug.log
// Or tap "Share" in the debug toolbar to send via any Android share target.
// ═════════════════════════════════════════════════════════════════════════════
class FileLogger {
  static File? _file;
  static const _maxBytes = 512 * 1024; // rotate after 512 KB

  static Future<void> init() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      _file = File('${dir.path}/gps_debug.log');
      if (await _file!.exists() && await _file!.length() > _maxBytes) {
        await _file!.delete();
      }
      await _write('════ Session start ${DateTime.now().toIso8601String()} ════');
    } catch (_) {}
  }

  static Future<void> log(String tag, String msg) async {
    final line = '[${DateTime.now().toIso8601String()}] [$tag] $msg';
    debugPrint(line);
    await _write(line);
  }

  static Future<void> _write(String line) async {
    try {
      await _file?.writeAsString('$line\n', mode: FileMode.append, flush: true);
    } catch (_) {}
  }

  static Future<String?> get path async => _file?.path;

  static Future<void> clear() async {
    try { await _file?.writeAsString(''); } catch (_) {}
  }
}

// ────────────────────────────────────────────────────────────────────────────
// ═════════════════════════════════════════════════════════════════════════════
class GpsMonitorPage extends StatefulWidget {
  const GpsMonitorPage({super.key});
  @override
  State<GpsMonitorPage> createState() => _GpsMonitorPageState();
}

class _GpsMonitorPageState extends State<GpsMonitorPage>
    with SingleTickerProviderStateMixin {

  UsbPort?                    _port;
  UsbDevice?                  _device;
  StreamSubscription<String>? _sub;
  Transaction<String>?        _tx;

  String _status     = 'IDLE';
  bool   _scanning   = false;
  bool   _connecting = false; // prevents re-entrant connect taps

  List<UsbDevice> _devices = [];
  List<_LogEntry> _log     = [];

  final _scrollCtrl = ScrollController();
  late final AnimationController _scanAnim = AnimationController(
    vsync: this, duration: const Duration(seconds: 2),
  )..repeat();

  bool get _connected => _port != null;

  // ── Scan ─────────────────────────────────────────────────────────────────────

  Future<void> _scan() async {
    await FileLogger.log('SYS', '_scan() start');
    setState(() => _scanning = true);
    try {
      final found = await UsbSerial.listDevices();
      await FileLogger.log('SYS', 'listDevices() → ${found.length} device(s)');
      for (final d in found) {
        await FileLogger.log('SYS',
          'Device: vid=${d.vid} pid=${d.pid} '
          'product="${d.productName}" mfr="${d.manufacturerName}"');
      }
      if (!found.contains(_device)) await _disconnect();
      setState(() { _devices = found; _scanning = false; });
      _addLog('SYS', 'Scan complete — ${found.length} device(s) found', _textSub);
    } catch (e, st) {
      await FileLogger.log('ERR', '_scan() exception: $e\n$st');
      setState(() => _scanning = false);
    }
  }

  // ── Connect ───────────────────────────────────────────────────────────────────
  //
  // Bugs fixed vs original code:
  //   1. _connecting guard — prevents double-tap race condition
  //   2. device.create() null check — create() returns UsbPort? and can be null
  //      when the driver doesn't recognise the device; original code force-unwrapped
  //      this with ! causing a silent NPE crash in release mode
  //   3. 300 ms delay after create() — CH340 / CP2102 chips need the OS to finish
  //      binding the driver before open() will succeed
  //   4. inputStream null check — port.inputStream is nullable; casting null to
  //      Stream<Uint8List> throws an uncaught cast exception in release mode
  //   5. Full try/catch — in release mode Flutter swallows unhandled async
  //      exceptions silently; without this the button appears to "do nothing"
  //   6. Every step logs to file — readable in release mode via Share or adb

  Future<void> _connect(UsbDevice device) async {
    if (_connecting) {
      await FileLogger.log('SYS', '_connect() skipped — already in progress');
      return;
    }
    _connecting = true;
    setState(() {}); // refresh UI to show spinner / disable button

    await FileLogger.log('SYS',
      '_connect() START vid=${device.vid} pid=${device.pid} '
      'product="${device.productName}"');

    try {
      await _disconnect();

      // STEP 1 — create port object
      await FileLogger.log('SYS', 'calling device.create()');
      final port = await device.create();

      if (port == null) {
        // FIX 2: null return means the usb_serial driver doesn't support this VID/PID
        await FileLogger.log('ERR',
          'device.create() returned null — VID/PID not supported by usb_serial driver');
        _addLog('ERR', 'Driver not supported for this device (create=null)', _red);
        setState(() => _status = 'ERR');
        return; // finally block clears _connecting
      }
      _port = port;
      await FileLogger.log('SYS', 'device.create() OK → port=$port');

      // STEP 2 — open port
      // FIX 3: delay so OS finishes USB driver binding
      await Future.delayed(const Duration(milliseconds: 300));
      await FileLogger.log('SYS', 'calling port.open()');
      final opened = await port.open();
      await FileLogger.log('SYS', 'port.open() → $opened');

      if (!opened) {
        await FileLogger.log('ERR', 'port.open() returned false');
        _addLog('ERR', 'port.open() failed — unplug, replug and try again', _red);
        setState(() { _status = 'ERR'; _port = null; });
        return;
      }

      // STEP 3 — configure
      await FileLogger.log('SYS', 'setting DTR=true RTS=true');
      await port.setDTR(true);
      await port.setRTS(true);

      await FileLogger.log('SYS', 'setPortParameters(4800, 8N1)');
      await port.setPortParameters(
        4800, UsbPort.DATABITS_8, UsbPort.STOPBITS_1, UsbPort.PARITY_NONE,
      );
      await FileLogger.log('SYS', 'setPortParameters OK');

      // STEP 4 — wire up receive stream
      await FileLogger.log('SYS', 'accessing port.inputStream');
      final inputStream = port.inputStream;

      if (inputStream == null) {
        // FIX 4: inputStream nullable; null cast crashes silently in release
        await FileLogger.log('ERR', 'port.inputStream is null');
        _addLog('ERR', 'inputStream is null — device may not support RX', _red);
        await port.close();
        setState(() { _status = 'ERR'; _port = null; });
        return;
      }
      await FileLogger.log('SYS', 'inputStream OK — creating Transaction');

      _tx = Transaction.stringTerminated(
        inputStream as Stream<Uint8List>,
        Uint8List.fromList([13, 10]), // \r\n
      );

      _sub = _tx!.stream.listen(
        (line) {
          FileLogger.log('RX', line);
          _addLog('RX', line, _accent);
        },
        onError: (Object e) {
          FileLogger.log('ERR', 'stream onError: $e');
          _addLog('ERR', 'Stream error: $e', _red);
        },
        onDone: () {
          FileLogger.log('SYS', 'stream onDone — device disconnected');
          _addLog('SYS', 'Stream closed by device', _textSub);
          if (mounted) setState(() => _status = 'IDLE');
        },
      );

      // STEP 5 — mark connected
      _device = device;
      setState(() => _status = 'LIVE');
      final msg = 'Connected to ${device.productName ?? "device"} @ 4800 baud';
      _addLog('SYS', msg, _green);
      await FileLogger.log('SYS', '_connect() SUCCESS — $msg');

    } catch (e, st) {
      // FIX 5: catch-all — release builds swallow unhandled async exceptions,
      // making the connect button appear to silently do nothing
      await FileLogger.log('ERR', '_connect() UNHANDLED EXCEPTION: $e\n$st');
      _addLog('ERR', 'Connect exception: $e', _red);
      try { await _port?.close(); } catch (_) {}
      _port = null; _device = null;
      setState(() => _status = 'ERR');

    } finally {
      _connecting = false;
      if (mounted) setState(() {});
    }
  }

  // ── Disconnect ────────────────────────────────────────────────────────────────

  Future<void> _disconnect() async {
    await FileLogger.log('SYS', '_disconnect() called');
    try {
      await _sub?.cancel();
      _tx?.dispose();
      await _port?.close();
    } catch (e) {
      await FileLogger.log('ERR', '_disconnect() error: $e');
    } finally {
      _sub = null; _tx = null; _port = null; _device = null;
      if (mounted) setState(() => _status = 'IDLE');
    }
  }

  // ── Send test data ────────────────────────────────────────────────────────────

  Future<void> _sendTestData() async {
    if (_port == null) return;
    await FileLogger.log('SYS', '_sendTestData() called');
    const sentences = [
      r'\$GPRMC,120000.00,A,0840.4567,N,07652.1234,E,0.00,000.0,150326,,,A*6A',
      r'\$GPGGA,120000.00,0840.4567,N,07652.1234,E,1,08,0.9,7.8,M,-47.3,M,,*72',
      r'\$GPGSV,2,1,08,10,72,054,45,12,60,298,42,25,55,123,40,29,41,210,38*7A',
      r'\$GPVTG,000.0,T,000.0,M,0.000,N,0.000,K,A*23',
    ];
    for (final s in sentences) {
      final clean = s.replaceAll(r'\$', r'$');
      try {
        await _port!.write(Uint8List.fromList('$clean\r\n'.codeUnits));
        _addLog('TX', clean, _amber);
        await FileLogger.log('TX', clean);
      } catch (e) {
        await FileLogger.log('ERR', '_sendTestData write error: $e');
        _addLog('ERR', 'Write failed: $e', _red);
      }
      await Future.delayed(const Duration(milliseconds: 120));
    }
  }

  // ── Logging ───────────────────────────────────────────────────────────────────

  void _addLog(String tag, String msg, Color color) {
    final now = DateTime.now();
    final ts = '${now.hour.toString().padLeft(2, '0')}:'
               '${now.minute.toString().padLeft(2, '0')}:'
               '${now.second.toString().padLeft(2, '0')}';
    setState(() {
      _log.add(_LogEntry(tag: tag, msg: msg, color: color, time: ts));
      if (_log.length > 300) _log.removeAt(0);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _shareLog() async {
    final p = await FileLogger.path;
    if (p == null) return;
    final f = File(p);
    if (await f.exists()) {
      await  SharePlus.instance.share(ShareParams(files: [XFile(p)], subject: 'GPS Monitor Debug Log'));
    }
  }

  Future<void> _copyLogPath() async {
    final p = await FileLogger.path ?? 'unavailable';
    await Clipboard.setData(ClipboardData(text: p));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('adb pull $p',
          style: const TextStyle(fontFamily: _mono, fontSize: 10)),
        backgroundColor: _surface,
        duration: const Duration(seconds: 5),
      ));
    }
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    FileLogger.log('SYS', 'initState');
    UsbSerial.usbEventStream?.listen((UsbEvent e) {
      FileLogger.log('SYS', 'UsbEvent: ${e.event} device=${e.device?.productName}');
      _scan();
    });
    _scan();
  }

  @override
  void dispose() {
    _disconnect();
    _scrollCtrl.dispose();
    _scanAnim.dispose();
    super.dispose();
  }

  // ═══════════════════════════════ Build ════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Scaffold(
        backgroundColor: _bg,
        body: Column(children: [
          _buildTopBar(),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
              child: Column(children: [
                _buildDevicePanel(),
                const SizedBox(height: 10),
                Expanded(child: _buildConsole()),
                const SizedBox(height: 10),
                _buildActionRow(),
                const SizedBox(height: 8),
                _buildLogToolbar(),
              ]),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _buildTopBar() => Container(
    decoration: const BoxDecoration(
      color: _surface,
      border: Border(bottom: BorderSide(color: _border)),
    ),
    padding: EdgeInsets.only(
      top: MediaQuery.of(context).padding.top + 6,
      bottom: 10, left: 16, right: 8,
    ),
    child: Row(children: [
      Container(
        width: 32, height: 32,
        decoration: BoxDecoration(
          color: _accent.withOpacity(0.12),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _accent.withOpacity(0.3)),
        ),
        child: const Icon(Icons.satellite_alt_rounded, color: _accent, size: 17),
      ),
      const SizedBox(width: 10),
      const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('USB GPS Monitor',
            style: TextStyle(color: _textPri, fontSize: 15,
                fontWeight: FontWeight.w700, letterSpacing: 0.3)),
          Text('Serial data terminal',
            style: TextStyle(color: _textSub, fontSize: 11)),
        ],
      ),
      const Spacer(),
      _StatusBadge(status: _status),
      const SizedBox(width: 4),
      IconButton(
        icon: _scanning
          ? AnimatedBuilder(
              animation: _scanAnim,
              builder: (_, child) => RotationTransition(turns: _scanAnim, child: child),
              child: const Icon(Icons.refresh_rounded, size: 19, color: _accent),
            )
          : const Icon(Icons.refresh_rounded, size: 19, color: _textSub),
        onPressed: _scanning ? null : _scan,
        tooltip: 'Refresh USB devices',
        splashRadius: 18,
      ),
    ]),
  );

  Widget _buildDevicePanel() {
    if (_devices.isEmpty) {
      return _Card(
        child: Row(children: [
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              color: _textSub.withOpacity(0.08),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.usb_off_rounded, color: _textSub, size: 18),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('No USB devices detected',
                style: TextStyle(color: _textPri, fontSize: 13,
                    fontWeight: FontWeight.w600)),
              Text('Plug in your GPS device and tap refresh',
                style: TextStyle(color: _textSub, fontSize: 11)),
            ]),
          ),
        ]),
      );
    }

    return Column(
      children: _devices.map((d) {
        final isCurrent = d == _device;
        return _Card(
          highlighted: isCurrent,
          child: Row(children: [
            Container(
              width: 36, height: 36,
              decoration: BoxDecoration(
                color: (isCurrent ? _accent : _textSub).withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: isCurrent
                  ? Border.all(color: _accent.withOpacity(0.3))
                  : null,
              ),
              child: Icon(Icons.usb_rounded,
                color: isCurrent ? _accent : _textSub, size: 18),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(d.productName ?? 'Unknown Device',
                  style: const TextStyle(color: _textPri, fontSize: 13,
                      fontWeight: FontWeight.w600)),
                Text('${d.manufacturerName ?? "Unknown"} · PID ${d.pid}',
                  style: const TextStyle(color: _textSub, fontSize: 11)),
              ]),
            ),
            const SizedBox(width: 10),
            // Show spinner while connecting to this device
            if (_connecting && !isCurrent)
              const SizedBox(
                width: 20, height: 20,
                child: CircularProgressIndicator(strokeWidth: 1.5, color: _accent),
              )
            else
              _PillButton(
                label: isCurrent ? 'Disconnect' : 'Connect',
                color: isCurrent ? _red : _green,
                onTap: _connecting
                  ? null
                  : () => isCurrent ? _disconnect() : _connect(d),
              ),
          ]),
        );
      }).toList(),
    );
  }

  Widget _buildConsole() => Container(
    decoration: BoxDecoration(
      color: _card,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: _border),
    ),
    child: Column(children: [
      Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: _border)),
        ),
        child: Row(children: [
          const Text('SERIAL OUTPUT',
            style: TextStyle(color: _textSub, fontSize: 10,
                letterSpacing: 1.5, fontWeight: FontWeight.w700)),
          const SizedBox(width: 8),
          if (_log.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: _accent.withOpacity(0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text('${_log.length}',
                style: const TextStyle(color: _accent, fontSize: 10,
                    fontWeight: FontWeight.w700)),
            ),
          const Spacer(),
          if (_log.isNotEmpty)
            GestureDetector(
              onTap: () => setState(() => _log.clear()),
              child: const Text('Clear',
                style: TextStyle(color: _textSub, fontSize: 11)),
            ),
        ]),
      ),
      Expanded(
        child: _log.isEmpty
          ? Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.terminal_rounded,
                  color: _textSub.withOpacity(0.3), size: 32),
                const SizedBox(height: 8),
                Text(
                  _connected ? 'Waiting for GPS data…' : 'Connect a device to begin',
                  style: const TextStyle(color: _textSub, fontSize: 12),
                ),
              ]),
            )
          : ListView.builder(
              controller: _scrollCtrl,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              itemCount: _log.length,
              itemBuilder: (_, i) {
                final e = _log[i];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 62,
                        child: Text(e.time,
                          style: const TextStyle(color: _textSub,
                              fontSize: 10, fontFamily: _mono, height: 1.7)),
                      ),
                      Container(
                        width: 28,
                        margin: const EdgeInsets.only(right: 8, top: 2),
                        child: Text(e.tag,
                          style: TextStyle(
                            color: e.color, fontSize: 9,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.5, fontFamily: _mono,
                          )),
                      ),
                      Expanded(
                        child: Text(e.msg,
                          style: TextStyle(
                            color: e.color, fontSize: 11.5,
                            fontFamily: _mono, height: 1.55,
                          )),
                      ),
                    ],
                  ),
                );
              },
            ),
      ),
    ]),
  );

  Widget _buildActionRow() => Row(children: [
    Expanded(
      child: ActionButton(
        icon: Icons.send_rounded,
        label: 'Send Test Data',
        sublabel: '4 NMEA sentences',
        color: _amber,
        enabled: _connected,
        onTap: _sendTestData,
      ),
    ),
    const SizedBox(width: 10),
    Expanded(
      child: ActionButton(
        icon: Icons.link_off_rounded,
        label: 'Disconnect',
        sublabel: _connected ? 'Tap to close port' : 'Not connected',
        color: _red,
        enabled: _connected,
        onTap: _disconnect,
      ),
    ),
  ]);

  Widget _buildLogToolbar() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: _surface,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: _border),
    ),
    child: Row(children: [
      const Icon(Icons.bug_report_rounded, color: _textSub, size: 13),
      const SizedBox(width: 6),
      const Text('Debug log',
        style: TextStyle(color: _textSub, fontSize: 11,
            fontWeight: FontWeight.w600, letterSpacing: 0.3)),
      const Spacer(),
      _SmallBtn(icon: Icons.share_rounded,   label: 'Share',      color: _blue,    onTap: _shareLog),
      const SizedBox(width: 10),
      _SmallBtn(icon: Icons.copy_rounded,    label: 'Copy path',  color: _textSub, onTap: _copyLogPath),
      const SizedBox(width: 10),
      _SmallBtn(icon: Icons.delete_outline_rounded, label: 'Clear', color: _red,
        onTap: () async {
          await FileLogger.clear();
          await FileLogger.log('SYS', 'Log cleared by user');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Log file cleared'),
              backgroundColor: _surface,
              duration: Duration(seconds: 2),
            ));
          }
        }),
    ]),
  );
}

// ═══════════════════════════════ Sub-widgets ══════════════════════════════════

class _LogEntry {
  final String tag, msg, time;
  final Color color;
  const _LogEntry({
    required this.tag, required this.msg,
    required this.color, required this.time,
  });
}

class _Card extends StatelessWidget {
  final Widget child;
  final bool highlighted;
  const _Card({required this.child, this.highlighted = false});

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 8),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    decoration: BoxDecoration(
      color: _card,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(
        color: highlighted ? _accent.withOpacity(0.35) : _border,
      ),
      boxShadow: highlighted
        ? [BoxShadow(color: _accent.withOpacity(0.06), blurRadius: 12)]
        : null,
    ),
    child: child,
  );
}

class _PillButton extends StatelessWidget {
  final String label;
  final Color color;
  final VoidCallback? onTap;
  const _PillButton({required this.label, required this.color, this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: onTap != null ? color.withOpacity(0.1) : _border.withOpacity(0.3),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: onTap != null ? color.withOpacity(0.45) : _border,
        ),
      ),
      child: Text(label,
        style: TextStyle(
          color: onTap != null ? color : _textSub,
          fontSize: 11.5, fontWeight: FontWeight.w700, letterSpacing: 0.3,
        )),
    ),
  );
}

class _SmallBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _SmallBtn({
    required this.icon, required this.label,
    required this.color, required this.onTap,
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, color: color, size: 13),
      const SizedBox(width: 3),
      Text(label, style: TextStyle(color: color, fontSize: 11,
          fontWeight: FontWeight.w600)),
    ]),
  );
}

class _StatusBadge extends StatelessWidget {
  final String status;
  const _StatusBadge({required this.status});

  Color get _color => switch (status) {
    'LIVE' => _green,
    'ERR'  => _red,
    _      => _textSub,
  };

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
    decoration: BoxDecoration(
      color: _color.withOpacity(0.1),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: _color.withOpacity(0.35)),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 5, height: 5,
        decoration: BoxDecoration(color: _color, shape: BoxShape.circle)),
      const SizedBox(width: 5),
      Text(status,
        style: TextStyle(color: _color, fontSize: 10,
            fontWeight: FontWeight.w800, letterSpacing: 0.8)),
    ]),
  );
}

class ActionButton extends StatelessWidget {
  final IconData icon;
  final String label, sublabel;
  final Color color;
  final bool enabled;
  final VoidCallback? onTap;

  const ActionButton({super.key,
    required this.icon, required this.label,
    required this.sublabel, required this.color,
    required this.enabled, this.onTap,
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: enabled ? onTap : null,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: enabled ? color.withOpacity(0.08) : _surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: enabled ? color.withAlpha(150) : _border.withAlpha(200),
        ),
      ),
      child: Row(children: [
        Icon(icon, color: enabled ? color : _textSub.withAlpha(150), size: 18),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label,
              style: TextStyle(
                color: enabled ? color : _textSub.withAlpha(150),
                fontSize: 12.5, fontWeight: FontWeight.w700,
              )),
            Text(sublabel,
              style: TextStyle(
                color: enabled ? color.withOpacity(0.55) : _textSub.withOpacity(0.3),
                fontSize: 10,
              )),
          ]),
        ),
      ]),
    ),
  );
}

// import 'dart:async';
// import 'dart:typed_data';

// import 'package:flutter/material.dart';
// import 'package:usb_serial/transaction.dart';
// import 'package:usb_serial/usb_serial.dart';

// class MyApp extends StatefulWidget {
//   @override
//   _MyAppState createState() => _MyAppState();
// }

// class _MyAppState extends State<MyApp> {
//   UsbPort? _port;
//   String _status = "Idle";
//   List<Widget> _ports = [];
//   List<Widget> _serialData = [];

//   StreamSubscription<String>? _subscription;
//   Transaction<String>? _transaction;
//   UsbDevice? _device;

//   TextEditingController _textController = TextEditingController();

//   Future<bool> _connectTo(device) async {
//     _serialData.clear();

//     if (_subscription != null) {
//       _subscription!.cancel();
//       _subscription = null;
//     }

//     if (_transaction != null) {
//       _transaction!.dispose();
//       _transaction = null;
//     }

//     if (_port != null) {
//       _port!.close();
//       _port = null;
//     }

//     if (device == null) {
//       _device = null;
//       setState(() {
//         _status = "Disconnected";
//       });
//       return true;
//     }

//     _port = await device.create('pl2303-MyGPS',-1);
//     if (await (_port!.open()) != true) {
//       print('kkkkkk');
//       setState(() {
//         _status = "Failed to open port";
//       });
//       return false;
//     }
//     _device = device;

//     await _port!.setDTR(true);
//     await _port!.setRTS(true);
//     await _port!.setPortParameters(4800, UsbPort.DATABITS_8, UsbPort.STOPBITS_1, UsbPort.PARITY_NONE);

//     _transaction = Transaction.stringTerminated(_port!.inputStream as Stream<Uint8List>, Uint8List.fromList([13, 10]));

//     _subscription = _transaction!.stream.listen((String line) {
//       setState(() {
//         _serialData.add(Text(line));
//         if (_serialData.length > 20) {
//           _serialData.removeAt(0);
//         }
//       });
//     });

//     setState(() {
//       _status = "Connected";
//     });
//     return true;
//   }

//   void _getPorts() async {
//     _ports = [];
//     List<UsbDevice> devices = await UsbSerial.listDevices();
//     if (!devices.contains(_device)) {
//       _connectTo(null);
//     }
//     print(devices);

//     devices.forEach((device) {
//       _ports.add(ListTile(
//           leading: Icon(Icons.usb),
//           title: Text(device.productName!),
//           subtitle: Text(device.manufacturerName!),
//           trailing: ElevatedButton(
//             child: Text(_device == device ? "Disconnect" : "Connect"),
//             onPressed: () {
//               _connectTo(_device == device ? null : device).then((res) {
//                 _getPorts();
//               });
//             },
//           )));
//     });

//     setState(() {
//       print(_ports);
//     });
//   }

//   @override
//   void initState() {
//     super.initState();

//     UsbSerial.usbEventStream!.listen((UsbEvent event) {
//       _getPorts();
//     });

//     _getPorts();
//   }

//   @override
//   void dispose() {
//     super.dispose();
//     _connectTo(null);
//   }

//   @override
//   Widget build(BuildContext context) {
//     return MaterialApp(
//         home: Scaffold(
//       appBar: AppBar(
//         title: const Text('USB Serial Plugin'),
//       ),
//       body: Center(
//           child: Column(children: <Widget>[
//         Text(_ports.length > 0 ? "Available Serial Ports" : "No serial devices available", style: Theme.of(context).textTheme.headlineLarge),
//         ..._ports,
//         Text('Status: $_status\n'),
//         Text('info: ${_port.toString()}\n'),
//         ListTile(
//           title: TextField(
//             controller: _textController,
//             decoration: InputDecoration(
//               border: OutlineInputBorder(),
//               labelText: 'Text To Send',
//             ),
//           ),
//           trailing: ElevatedButton(
//             child: Text("Send"),
//             onPressed: _port == null
//                 ? null
//                 : () async {
//                     if (_port == null) {
//                       return;
//                     }
//                     String data = _textController.text + "\r\n";
//                     await _port!.write(Uint8List.fromList(data.codeUnits));
//                     _textController.text = "";
//                   },
//           ),
//         ),
//         Expanded(child: SingleChildScrollView(
//           child: Column(
//             children: _serialData,
//           ),
//         )),
//         // Text("Result Data", style: Theme.of(context).textTheme.headline6),
//         // ..._serialData,
//       ])),
//     ));
//   }
// }
