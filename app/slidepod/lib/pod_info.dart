import 'dart:convert';

/// Who a SlidePod is: its serial (the chip's factory MAC, 12 hex digits),
/// its name, and its firmware. Firmware before 0.3 reports none of this.
class PodInfo {
  final String serial;
  final String name;
  final String? firmware;
  final int? hardware;
  const PodInfo({
    required this.serial,
    required this.name,
    this.firmware,
    this.hardware,
  });

  /// The last 4 digits of the serial: what a new pod's name ends in, and
  /// how the app tells pods with the same name apart.
  String get code => shortCode(serial);

  PodInfo withName(String name) => PodInfo(
    serial: serial,
    name: name,
    firmware: firmware,
    hardware: hardware,
  );

  /// From the pod's info characteristic, e.g.
  /// `{"serial":"7CDFA1E23F2A","fw":"0.3.0","hw":2}`, and its name.
  static PodInfo? fromInfo(List<int> info, String name) {
    try {
      final m = jsonDecode(utf8.decode(info)) as Map<String, dynamic>;
      final serial = m['serial'];
      if (serial is! String || !validSerial(serial)) return null;
      return PodInfo(
        serial: serial.toUpperCase(),
        name: name,
        firmware: m['fw'] as String?,
        hardware: (m['hw'] as num?)?.toInt(),
      );
    } catch (_) {
      return null;
    }
  }
}

/// The company ID the pod's manufacturer data is sent under (0xFFFF, the
/// Bluetooth SIG's "no company" ID for testing).
const podCompanyId = 0xFFFF;

/// Longest pod name, in UTF-8 bytes (the firmware's limit).
const podNameMaxBytes = 20;

bool validSerial(String s) => RegExp(r'^[0-9A-Fa-f]{12}$').hasMatch(s);

String shortCode(String serial) => serial.length >= 4
    ? serial.substring(serial.length - 4).toUpperCase()
    : serial;

/// The serial a pod advertises in its manufacturer data (6 bytes, in the
/// order they're written), or null for older firmware.
String? serialFromAdvert(Map<int, List<int>> manufacturerData) {
  final b = manufacturerData[podCompanyId];
  if (b == null || b.length != 6) return null;
  return [
    for (final x in b) x.toRadixString(16).padLeft(2, '0'),
  ].join().toUpperCase();
}

/// Why [name] can't be a pod's name, or null if it can. The pod applies the
/// same rule (1–20 bytes of UTF-8, no control characters, not blank).
String? podNameProblem(String name) {
  if (name.trim().isEmpty) return 'Give it a name.';
  if (utf8.encode(name).length > podNameMaxBytes) {
    return 'That name is too long.';
  }
  if (name.runes.any((r) => r < 0x20 || r == 0x7F)) {
    return 'That name has characters a SlidePod can\'t show.';
  }
  return null;
}

/// The pod's battery, from firmware 0.4: [percent] is 0–100, or null when
/// it can't tell (no battery fitted). On USB power ([usb]) it's charging and
/// [percent] is the pod's estimate (0.4.1 and up; 0.4.0 just reads high),
/// until [charged].
class PodPower {
  final int? percent;
  final bool usb;
  final bool charged;
  final int millivolts;
  const PodPower(
      {required this.percent,
      required this.usb,
      this.charged = false,
      required this.millivolts});

  /// From the power characteristic: percent (0xFF = unknown), flags (bit 0:
  /// USB), mV (u16 LE).
  static PodPower? fromBytes(List<int> b) {
    if (b.length < 4) return null;
    return PodPower(
      percent: b[0] <= 100 ? b[0] : null,
      usb: b[1] & 1 == 1,
      charged: b[1] & 3 == 3,
      millivolts: b[2] | (b[3] << 8),
    );
  }

  /// Worth warning about: under 15 %, and not charging.
  bool get low => !usb && percent != null && percent! < 15;

  /// As the app shows it: "72 %", "Charging, 64 %", "Charged", or "–"
  /// when unknown.
  String get label => usb
      ? charged
          ? 'Charged'
          : percent == null
              ? 'Charging'
              : 'Charging, $percent\u00A0%'
      : percent == null
          ? '–'
          : '$percent\u00A0%';
}
