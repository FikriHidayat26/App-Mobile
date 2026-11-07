// variasi_picker.dart — bagian "variasi" di editor item kasir (ItemEditorPage).
// Widget ini tidak menyimpan state sendiri: state (Map grupId -> Set opsiId)
// dipegang oleh editor, jadi harga/stok di keranjang ikut terhitung langsung.
import 'package:flutter/material.dart';

import 'models.dart' show rupiah;
import 'variasi_models.dart';

class VariasiPilihan extends StatelessWidget {
  final List<VariasiGrup> grup;
  final Map<int, Set<int>> dipilih;
  final void Function(VariasiGrup g, VariasiOpsi o) onKetuk;
  const VariasiPilihan({
    super.key,
    required this.grup,
    required this.dipilih,
    required this.onKetuk,
  });

  @override
  Widget build(BuildContext context) {
    final warna = Theme.of(context).colorScheme.primary;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final g in grup) ...[
        Padding(
          padding: const EdgeInsets.only(top: 16, bottom: 4),
          child: Row(children: [
            Expanded(
              child: Text(g.nama, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            ),
            Text(
              g.keterangan,
              style: TextStyle(
                fontSize: 12,
                color: g.wajib && (dipilih[g.id]?.isEmpty ?? true) ? Colors.red : Colors.grey.shade700,
              ),
            ),
          ]),
        ),
        for (final o in g.opsi)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            onTap: () => onKetuk(g, o),
            leading: Icon(
              (dipilih[g.id]?.contains(o.id) ?? false)
                  ? (g.pilihSatu ? Icons.radio_button_checked : Icons.check_box)
                  : (g.pilihSatu ? Icons.radio_button_unchecked : Icons.check_box_outline_blank),
              color: (dipilih[g.id]?.contains(o.id) ?? false) ? warna : null,
            ),
            title: Text(o.nama),
            trailing: o.hargaTambah > 0 ? Text('+${rupiah(o.hargaTambah)}') : null,
          ),
      ],
    ]);
  }
}

/// Mengubah pilihan saat opsi diketuk (pilih satu / banyak dengan batas).
/// Panggil di dalam setState milik editor.
void ketukVariasi(BuildContext context, VariasiGrup g, VariasiOpsi o, Map<int, Set<int>> dipilih) {
  final set = dipilih[g.id] ??= <int>{};
  if (set.contains(o.id)) {
    set.remove(o.id);
  } else if (g.pilihSatu) {
    set
      ..clear()
      ..add(o.id);
  } else if (g.maksPilih > 0 && set.length >= g.maksPilih) {
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('"${g.nama}" maksimal ${g.maksPilih} pilihan')));
  } else {
    set.add(o.id);
  }
}

/// Nama kelompok WAJIB yang belum dipilih (kosong = lengkap).
List<String> variasiBelumLengkap(List<VariasiGrup> grup, Map<int, Set<int>> dipilih) => [
      for (final g in grup)
        if (g.wajib && (dipilih[g.id]?.isEmpty ?? true)) g.nama,
    ];

/// Pilihan terpilih dalam urutan kelompok & opsi, siap ditempel ke CartItem.variasi.
List<PilihanVariasi> susunPilihanVariasi(List<VariasiGrup> grup, Map<int, Set<int>> dipilih) {
  final out = <PilihanVariasi>[];
  for (final g in grup) {
    for (final o in g.opsi) {
      if (dipilih[g.id]?.contains(o.id) ?? false) {
        out.add(PilihanVariasi(
          grupId: g.id,
          opsiId: o.id,
          grupNama: g.nama,
          opsiNama: o.nama,
          hargaTambah: o.hargaTambah,
          bahan: o.bahan,
        ));
      }
    }
  }
  return out;
}
