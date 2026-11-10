// variasi_picker.dart — bagian "variasi" di editor item kasir (ItemEditorPage).
// Tampilan mengikuti TIPE kelompok (diatur di Kelola > Variasi):
//  - RADIO  : pilih satu opsi.
//  - TEKS   : kolom ketik bebas.
//  - BANYAK : tiap opsi punya tombol - / + (default 0); satu opsi boleh lebih dari 1
//             dan boleh dicampur dengan opsi lain. Batas maksimal = TOTAL jumlah di kelompok.
// State dipegang editor: dipilih (grupId -> opsiId -> jumlah) dan teks (grupId -> isian).
import 'package:flutter/material.dart';

import 'models.dart' show rupiah;
import 'variasi_models.dart';

/// Total jumlah item terpilih di satu kelompok.
int jumlahVariasi(Map<int, int>? m) => m == null ? 0 : m.values.fold(0, (a, b) => a + b);

bool _teksKosong(Map<int, String> teks, int gid) => (teks[gid] ?? '').trim().isEmpty;

class VariasiPilihan extends StatelessWidget {
  final List<VariasiGrup> grup;
  final Map<int, Map<int, int>> dipilih;
  final Map<int, String> teks;
  final void Function(VariasiGrup g, VariasiOpsi o) onTambah;
  final void Function(VariasiGrup g, VariasiOpsi o) onKurang;
  final void Function(VariasiGrup g, String nilai) onTeks;

  /// Info stok untuk baris tipe Banyak item, mis. "sisa 46 pcs". null = tidak ditampilkan.
  final String? Function(VariasiOpsi o)? infoStok;
  const VariasiPilihan({
    super.key,
    required this.grup,
    required this.dipilih,
    required this.teks,
    required this.onTambah,
    required this.onKurang,
    required this.onTeks,
    this.infoStok,
  });

  @override
  Widget build(BuildContext context) {
    final warna = Theme.of(context).colorScheme.primary;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final g in grup) ...[
        _judul(g),
        if (g.isTeks)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: TextFormField(
              key: ValueKey('teks-${g.id}'),
              initialValue: teks[g.id] ?? '',
              maxLength: 100,
              minLines: 1,
              maxLines: 2,
              decoration: InputDecoration(
                hintText: 'Ketik ${g.nama.toLowerCase()}',
                isDense: true,
                border: const OutlineInputBorder(),
              ),
              onChanged: (v) => onTeks(g, v),
            ),
          )
        else
          for (final o in g.opsi) _baris(g, o, warna),
      ],
    ]);
  }

  Widget _judul(VariasiGrup g) {
    final total = jumlahVariasi(dipilih[g.id]);
    final kurang = g.isTeks ? (g.wajib && _teksKosong(teks, g.id)) : total < g.minEfektif;
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(g.nama, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            Text(
              g.isTeks ? (g.wajib ? 'Wajib diisi' : 'Boleh dikosongkan') : g.aturan,
              style: TextStyle(fontSize: 12, color: kurang ? Colors.red : Colors.grey.shade700),
            ),
          ]),
        ),
        if (g.isBanyak)
          Text(
            g.maksPilih > 0 ? '$total/${g.maksPilih}' : '$total dipilih',
            style: const TextStyle(fontSize: 12),
          ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: g.wajib ? Colors.red.shade50 : Colors.grey.shade200,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(g.wajib ? 'Wajib' : 'Opsional',
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: g.wajib ? Colors.red.shade700 : Colors.grey.shade700)),
        ),
      ]),
    );
  }

  Widget _baris(VariasiGrup g, VariasiOpsi o, Color warna) {
    final qty = dipilih[g.id]?[o.id] ?? 0;

    // Radio: pilih satu.
    if (g.pilihSatu) {
      return ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        onTap: () => qty > 0 ? onKurang(g, o) : onTambah(g, o),
        leading: Icon(
          qty > 0 ? Icons.radio_button_checked : Icons.radio_button_unchecked,
          color: qty > 0 ? warna : null,
        ),
        title: Text(o.nama),
        trailing: o.hargaTambah > 0 ? Text('+${rupiah(o.hargaTambah)}') : null,
      );
    }

    // Banyak item: stepper - 0 +.
    final penuh = g.maksPilih > 0 && jumlahVariasi(dipilih[g.id]) >= g.maksPilih;
    final info = infoStok?.call(o);
    final sub = [
      o.hargaTambah > 0 ? '${rupiah(o.hargaTambah)} / pilihan' : 'Gratis',
      if (info != null) info,
    ].join(' • ');
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(o.nama, style: TextStyle(fontWeight: qty > 0 ? FontWeight.bold : null)),
      subtitle: Text(sub),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(
          onPressed: qty > 0 ? () => onKurang(g, o) : null,
          icon: const Icon(Icons.remove_circle_outline),
        ),
        SizedBox(
          width: 24,
          child: Center(
            child: Text('$qty',
                style: TextStyle(
                    fontWeight: qty > 0 ? FontWeight.bold : null, color: qty > 0 ? warna : null)),
          ),
        ),
        IconButton(
          // Saat penuh tetap bisa diketuk agar muncul pesan batas.
          onPressed: () => onTambah(g, o),
          icon: Icon(Icons.add_circle_outline, color: penuh ? Colors.grey : null),
        ),
      ]),
    );
  }
}

/// Tambah 1 pada opsi. Radio: mengganti pilihan. Banyak item: dibatasi total maksimal.
/// Panggil di dalam setState milik editor.
void tambahVariasi(BuildContext context, VariasiGrup g, VariasiOpsi o, Map<int, Map<int, int>> dipilih) {
  final m = dipilih[g.id] ??= <int, int>{};
  if (g.pilihSatu) {
    m
      ..clear()
      ..[o.id] = 1;
    return;
  }
  if (g.maksPilih > 0 && jumlahVariasi(m) >= g.maksPilih) {
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('"${g.nama}" maksimal ${g.maksPilih} pilihan')));
    return;
  }
  m[o.id] = (m[o.id] ?? 0) + 1;
}

/// Kurangi 1 pada opsi (hilang dari daftar saat 0).
void kurangVariasi(VariasiGrup g, VariasiOpsi o, Map<int, Map<int, int>> dipilih) {
  final m = dipilih[g.id];
  if (m == null) return;
  final n = (m[o.id] ?? 0) - 1;
  if (n <= 0) {
    m.remove(o.id);
  } else {
    m[o.id] = n;
  }
}

/// Kelompok yang belum memenuhi aturan (kosong = lengkap).
/// Contoh isi: "Level Pedas", "Topping (min 2)", "Nama di kotak".
List<String> variasiBelumLengkap(
    List<VariasiGrup> grup, Map<int, Map<int, int>> dipilih, Map<int, String> teks) {
  final out = <String>[];
  for (final g in grup) {
    if (g.isTeks) {
      if (g.wajib && _teksKosong(teks, g.id)) out.add(g.nama);
    } else if (jumlahVariasi(dipilih[g.id]) < g.minEfektif) {
      out.add(g.minEfektif > 1 ? '${g.nama} (min ${g.minEfektif})' : g.nama);
    }
  }
  return out;
}

/// Pilihan terpilih dalam urutan kelompok & opsi, siap ditempel ke CartItem.variasi.
/// Opsi berjumlah N ditulis N kali (harga & stok di keranjang otomatis ikut N kali).
/// Jawaban teks ditulis sebagai satu PilihanVariasi dengan opsiId = 0.
List<PilihanVariasi> susunPilihanVariasi(
    List<VariasiGrup> grup, Map<int, Map<int, int>> dipilih, Map<int, String> teks) {
  final out = <PilihanVariasi>[];
  for (final g in grup) {
    if (g.isTeks) {
      final t = (teks[g.id] ?? '').trim();
      if (t.isNotEmpty) {
        out.add(PilihanVariasi(
            grupId: g.id, opsiId: 0, grupNama: g.nama, opsiNama: t, hargaTambah: 0));
      }
      continue;
    }
    for (final o in g.opsi) {
      final n = dipilih[g.id]?[o.id] ?? 0;
      for (var i = 0; i < n; i++) {
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
