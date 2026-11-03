// helpers.dart — fungsi kecil bersama untuk layar Dashboard & Kelola.
import 'package:flutter/material.dart';

String rp(num v) {
  final s = v.round().abs().toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write('.');
    b.write(s[i]);
  }
  return '${v < 0 ? '-' : ''}Rp$b';
}

String qtyFmt(num v) {
  final r = (v * 100).round() / 100;
  return r == r.roundToDouble() ? r.toInt().toString() : r.toString();
}

num n(Object? v) => (v as num?) ?? 0;

void snack(BuildContext c, String msg) =>
    ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(msg)));
