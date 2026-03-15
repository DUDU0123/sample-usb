import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:usb_serial/transaction.dart';
import 'package:usb_serial/usb_serial.dart';

// ── Palette ───────────────────────────────────────────────────────────────────
const _bg      = Color(0xFF0A0E14);
const _surface = Color(0xFF111820);
const _card    = Color(0xFF161D27);
const _border  = Color(0xFF1E2A38);
const _accent  = Color(0xFF00D4AA);  // teal-green terminal vibe
const _green   = Color(0xFF39D353);
const _red     = Color(0xFFFF5F57);
const _amber   = Color(0xFFFFB347);
const _textPri = Color(0xFFD4E4F7);
const _textSub = Color(0xFF5A7A96);
const _mono    = 'monospace';

void main() => runApp(const _App());

class _App extends StatelessWidget {
  const _App();
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'USB GPS Monitor',
    theme: ThemeData.dark().copyWith(
      scaffoldBackgroundColor: _bg,
      colorScheme: const ColorScheme.dark(primary: _accent),
    ),
    home: const GpsMonitorPage(),
  );
}

// ═════════════════════════════════════════════════════════════════════════════
class GpsMonitorPage extends StatefulWidget {
  const GpsMonitorPage({super.key});
  @override
  State<GpsMonitorPage> createState() => _GpsMonitorPageState();
}

class _GpsMonitorPageState extends State<GpsMonitorPage>
    with SingleTickerProviderStateMixin {

  // USB state
  UsbPort?            _port;
  UsbDevice?          _device;
  StreamSubscription<String>? _sub;
  Transaction<String>? _tx;

  String _status   = 'IDLE';
  bool   _scanning = false;

  List<UsbDevice> _devices   = [];
  List<_LogEntry> _log       = [];

  final _scrollCtrl = ScrollController();
  late final AnimationController _scanAnim = AnimationController(
    vsync: this, duration: const Duration(seconds: 2),
  )..repeat();

  bool get _connected => _port != null;

  // ── USB helpers ─────────────────────────────────────────────────────────────

  Future<void> _scan() async {
    setState(() => _scanning = true);
    final found = await UsbSerial.listDevices();
    if (!found.contains(_device)) await _disconnect();
    setState(() { _devices = found; _scanning = false; });
    _addLog('SYS', 'Scan complete — ${found.length} device(s) found', _textSub);
  }

  Future<void> _connect(UsbDevice device) async {
    await _disconnect();

    _port = await device.create();
    if (await _port!.open() != true) {
      setState(() { _status = 'ERR'; _port = null; });
      _addLog('ERR', 'Failed to open port', _red);
      return;
    }

    _device = device;
    await _port!.setDTR(true);
    await _port!.setRTS(true);
    await _port!.setPortParameters(
      4800, UsbPort.DATABITS_8, UsbPort.STOPBITS_1, UsbPort.PARITY_NONE,
    );

    _tx = Transaction.stringTerminated(
      _port!.inputStream as Stream<Uint8List>,
      Uint8List.fromList([13, 10]),
    );

    _sub = _tx!.stream.listen((line) {
      _addLog('RX', line, _accent);
    });

    setState(() => _status = 'LIVE');
    _addLog('SYS', 'Connected to ${device.productName ?? "device"} @ 4800 baud', _green);
  }

  Future<void> _disconnect() async {
    await _sub?.cancel();
    _tx?.dispose();
    await _port?.close();
    _sub = null; _tx = null; _port = null; _device = null;
    if (mounted) setState(() => _status = 'IDLE');
  }

  Future<void> _sendTestData() async {
    if (_port == null) return;

    // Realistic NMEA sentences for a GPS fix
    const sentences = [
      r'\$GPRMC,120000.00,A,0840.4567,N,07652.1234,E,0.00,000.0,150326,,,A*6A',
      r'\$GPGGA,120000.00,0840.4567,N,07652.1234,E,1,08,0.9,7.8,M,-47.3,M,,*72',
      r'\$GPGSV,2,1,08,10,72,054,45,12,60,298,42,25,55,123,40,29,41,210,38*7A',
      r'\$GPVTG,000.0,T,000.0,M,0.000,N,0.000,K,A*23',
    ];

    for (final s in sentences) {
      final clean = s.replaceAll(r'\$', r'$');
      await _port!.write(Uint8List.fromList('$clean\r\n'.codeUnits));
      _addLog('TX', clean, _amber);
      await Future.delayed(const Duration(milliseconds: 120));
    }
  }

  void _addLog(String tag, String msg, Color color) {
    final ts = TimeOfDay.now().format(context);
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

  @override
  void initState() {
    super.initState();
    UsbSerial.usbEventStream?.listen((_) => _scan());
    _scan();
  }

  @override
  void dispose() {
    _disconnect();
    _scrollCtrl.dispose();
    _scanAnim.dispose();
    super.dispose();
  }

  // ── Build ────────────────────────────────────────────────────────────────────

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
              ]),
            ),
          ),
        ]),
      ),
    );
  }

  // ── Top bar ──────────────────────────────────────────────────────────────────

  Widget _buildTopBar() => Container(
    decoration: const BoxDecoration(
      color: _surface,
      border: Border(bottom: BorderSide(color: _border)),
    ),
    padding: EdgeInsets.only(
      top: MediaQuery.of(context).padding.top + 6,
      bottom: 10,
      left: 16, right: 8,
    ),
    child: Row(children: [
      // Icon + title
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
      // Status badge
      _StatusBadge(status: _status),
      const SizedBox(width: 4),
      // Refresh
      IconButton(
        icon: _scanning
          ? AnimatedBuilder(
              animation: _scanAnim,
              builder: (_, child) => RotationTransition(
                turns: _scanAnim,
                child: child,
              ),
              child: const Icon(Icons.refresh_rounded, size: 19, color: _accent),
            )
          : const Icon(Icons.refresh_rounded, size: 19, color: _textSub),
        onPressed: _scanning ? null : _scan,
        tooltip: 'Refresh USB devices',
        splashRadius: 18,
      ),
    ]),
  );

  // ── Device panel ─────────────────────────────────────────────────────────────

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
                style: TextStyle(color: _textPri, fontSize: 13, fontWeight: FontWeight.w600)),
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
            _PillButton(
              label: isCurrent ? 'Disconnect' : 'Connect',
              color: isCurrent ? _red : _green,
              onTap: () => isCurrent ? _disconnect() : _connect(d),
            ),
          ]),
        );
      }).toList(),
    );
  }

  // ── Console ──────────────────────────────────────────────────────────────────

  Widget _buildConsole() => Container(
    decoration: BoxDecoration(
      color: _card,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: _border),
    ),
    child: Column(children: [
      // Console header
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
      // Log entries
      Expanded(
        child: _log.isEmpty
          ? Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.terminal_rounded,
                  color: _textSub.withOpacity(0.3), size: 32),
                const SizedBox(height: 8),
                Text(_connected ? 'Waiting for GPS data…' : 'Connect a device to begin',
                  style: const TextStyle(color: _textSub, fontSize: 12)),
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
                      // Timestamp
                      SizedBox(
                        width: 54,
                        child: Text(e.time,
                          style: const TextStyle(color: _textSub,
                              fontSize: 10, fontFamily: _mono, height: 1.7)),
                      ),
                      // Tag
                      Container(
                        width: 28,
                        margin: const EdgeInsets.only(right: 8, top: 2),
                        child: Text(e.tag,
                          style: TextStyle(
                            color: e.color,
                            fontSize: 9,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.5,
                            fontFamily: _mono,
                          )),
                      ),
                      // Message
                      Expanded(
                        child: Text(e.msg,
                          style: TextStyle(
                            color: e.color,
                            fontSize: 11.5,
                            fontFamily: _mono,
                            height: 1.55,
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

  // ── Action row ───────────────────────────────────────────────────────────────

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

// Framed card container
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

// Small pill button
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
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.45)),
      ),
      child: Text(label,
        style: TextStyle(
          color: color,
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
        )),
    ),
  );
}

// Status badge in top bar
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
        style: TextStyle(
          color: _color,
          fontSize: 10,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.8,
        )),
    ]),
  );
}

// Bottom action button
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
        Icon(icon,
          color: enabled ? color : _textSub.withAlpha(150), size: 18),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label,
              style: TextStyle(
                color: enabled ? color : _textSub.withAlpha(150),
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
              )),
            Text(sublabel,
              style: TextStyle(
                color: enabled
                  ? color.withOpacity(0.55)
                  : _textSub.withOpacity(0.3),
                fontSize: 10,
              )),
          ]),
        ),
      ]),
    ),
  );
}