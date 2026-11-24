import 'package:flutter/material.dart';

import '../account.dart';
import '../pod_info.dart';
import 'seventh.dart';

/// The pod's link, as the pill shows it.
enum PodLink { off, connecting, on }

/// The top bar of every tab: the title, the pod pill and your profile.
class SeventhTopBar extends StatelessWidget implements PreferredSizeWidget {
  final String title;
  final Widget? pod;
  final Widget? profile;
  const SeventhTopBar({super.key, required this.title, this.pod, this.profile});

  @override
  Size get preferredSize => const Size.fromHeight(64);

  @override
  Widget build(BuildContext context) => SafeArea(
    bottom: false,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(Seventh.gutter, 14, Seventh.gutter, 4),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                title,
                style: Seventh.tabTitle,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          ?pod,
          if (profile != null) ...[const SizedBox(width: 10), profile!],
        ],
      ),
    ),
  );
}

/// The pod pill: link, name and battery. Tap: connect, or (connected) the
/// pod sheet. [compact] drops the name, for screens mid-task.
class PodPill extends StatelessWidget {
  final PodLink link;
  final String? name;
  final PodPower? power;
  final VoidCallback? onTap;
  final bool compact;
  const PodPill({
    super.key,
    required this.link,
    this.name,
    this.power,
    this.onTap,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final p = power;
    final batteryColor = p == null
        ? Seventh.body
        : p.usb
        ? Seventh.inTune
        : p.low
        ? Seventh.off
        : Seventh.body;
    final children = <Widget>[];
    String semantics;
    switch (link) {
      case PodLink.off:
        children.addAll([_dot(Seventh.faint), const Text('Connect')]);
        semantics = 'SlidePod not connected. Connect';
      case PodLink.connecting:
        children.addAll([_dot(Seventh.close), const Text('Connecting…')]);
        semantics = 'Connecting to SlidePod';
      case PodLink.on:
        children.add(_dot(Seventh.inTune));
        if (!compact) {
          children.add(
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 110),
              child: Text(
                name ?? 'SlidePod',
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
          );
        }
        if (p != null) {
          children.add(
            BatteryGlyph(
              percent: p.percent ?? 0,
              color: batteryColor,
              charging: p.usb,
            ),
          );
          children.add(
            Text(
              p.usb
                  ? (compact ? '' : 'Charging')
                  : p.percent == null
                  ? '–'
                  : '${p.percent} %',
              style: Seventh.mono.copyWith(
                fontSize: compact ? 11 : 12,
                color: p.usb || p.low ? batteryColor : Seventh.muted,
              ),
            ),
          );
        }
        semantics = [
          '${name ?? 'SlidePod'} connected',
          if (p != null) p.usb ? 'charging' : 'battery ${p.label}',
        ].join(', ');
    }
    final off = link == PodLink.off;
    return Semantics(
      button: onTap != null,
      label: semantics,
      excludeSemantics: true,
      child: Material(
        color: off ? Colors.transparent : Seventh.card,
        shape: StadiumBorder(
          side: off ? const BorderSide(color: Seventh.line) : BorderSide.none,
        ),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: compact ? 32 : 40),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: compact ? 10 : 13),
              child: DefaultTextStyle(
                style: const TextStyle(
                  fontFamily: Seventh.bodyFont,
                  fontSize: 13,
                  color: Seventh.text,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < children.length; i++) ...[
                      if (i > 0) SizedBox(width: compact ? 6 : 8),
                      children[i],
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  static Widget _dot(Color c) => Container(
    width: 8,
    height: 8,
    decoration: BoxDecoration(color: c, shape: BoxShape.circle),
  );
}

/// A small battery: outline, nub, and a fill for [percent] (a bolt when
/// charging).
class BatteryGlyph extends StatelessWidget {
  final int percent;
  final Color color;
  final bool charging;
  const BatteryGlyph({
    super.key,
    required this.percent,
    this.color = Seventh.body,
    this.charging = false,
  });

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: const Size(22, 12),
    painter: _BatteryPainter(charging ? 100 : percent, color, charging),
  );
}

class _BatteryPainter extends CustomPainter {
  final int percent;
  final Color color;
  final bool charging;
  _BatteryPainter(this.percent, this.color, this.charging);

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final fill = Paint()..color = color;
    final body = RRect.fromLTRBR(
      0.75,
      0.75,
      size.width - 3.5,
      size.height - 0.75,
      const Radius.circular(2.5),
    );
    canvas.drawRRect(body, stroke);
    canvas.drawRRect(
      RRect.fromLTRBR(
        size.width - 2.5,
        size.height * .32,
        size.width,
        size.height * .68,
        const Radius.circular(1),
      ),
      fill,
    );
    final inner = body.deflate(2);
    final w = inner.width * (percent.clamp(0, 100) / 100);
    if (w > 0) {
      canvas.drawRRect(
        RRect.fromLTRBR(
          inner.left,
          inner.top,
          inner.left + w,
          inner.bottom,
          const Radius.circular(1),
        ),
        fill,
      );
    }
    if (charging) {
      final c = inner.center;
      final bolt = Path()
        ..moveTo(c.dx + 1, c.dy - 4)
        ..lineTo(c.dx - 2.5, c.dy + 0.5)
        ..lineTo(c.dx, c.dy + 0.5)
        ..lineTo(c.dx - 1, c.dy + 4)
        ..lineTo(c.dx + 2.5, c.dy - 0.5)
        ..lineTo(c.dx, c.dy - 0.5)
        ..close();
      canvas.drawPath(bolt, Paint()..color = Seventh.ground);
    }
  }

  @override
  bool shouldRepaint(_BatteryPainter old) =>
      old.percent != percent || old.color != color || old.charging != charging;
}

/// Your profile: your initial when signed in, else a sign-in outline.
class ProfileAvatar extends StatelessWidget {
  final Account? account;
  final VoidCallback? onTap;
  const ProfileAvatar({super.key, required this.account, this.onTap});

  @override
  Widget build(BuildContext context) {
    final a = account;
    if (a == null || !a.available) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: a,
      builder: (context, _) {
        final name = a.player?.displayName;
        final signedIn = a.signedIn;
        return Semantics(
          button: true,
          label: signedIn
              ? 'Account${name == null ? '' : ': $name'}'
              : 'Sign in',
          excludeSemantics: true,
          child: Material(
            color: signedIn ? const Color(0xFF2A3A4E) : Colors.transparent,
            shape: CircleBorder(
              side: signedIn
                  ? BorderSide.none
                  : const BorderSide(color: Seventh.line),
            ),
            child: InkWell(
              key: const Key('account'),
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: SizedBox(
                width: 40,
                height: 40,
                child: Center(
                  child: signedIn && name != null && name.isNotEmpty
                      ? Text(
                          name.characters.first.toUpperCase(),
                          style: const TextStyle(
                            fontFamily: Seventh.titleFont,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: Seventh.accentSoft,
                          ),
                        )
                      : Icon(
                          signedIn ? Icons.person : Icons.person_outline,
                          size: 20,
                          color: signedIn ? Seventh.accentSoft : Seventh.body,
                        ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
