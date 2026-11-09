// variasi_models.dart — model variasi menu (ala GoFood).
// Kelompok (grup)  : "Level Pedas", "Topping Tambahan", "Suhu/Rasa" ...
// Opsi             : pilihan di dalam kelompok, punya harga tambahan + efek stok bahan.
// Relasi           : satu kelompok bisa dipasang ke banyak menu (menuIds).

/// Bahan yang ikut terpotong stoknya bila opsi dipilih (per 1 porsi).
class VariasiBahan {
  final int bahanId;
  final String nama;
  final String satuan;
  final double qtyDasar;
  const VariasiBahan({
    required this.bahanId,
    this.nama = '',
    this.satuan = '',
    required this.qtyDasar,
  });
}

class VariasiOpsi {
  final int id;
  final int grupId;
  final String nama;
  final int hargaTambah;
  final bool aktif;
  final List<VariasiBahan> bahan;
  const VariasiOpsi({
    required this.id,
    required this.grupId,
    required this.nama,
    required this.hargaTambah,
    required this.aktif,
    this.bahan = const [],
  });
}

/// Teks aturan ala GoFood: "Pilih 1", "Pilih minimal 1, maksimal 3", "Maksimal 3", "Bebas pilih".
String aturanVariasi({required bool wajib, required int min, required int maks}) {
  final mn = wajib ? (min < 1 ? 1 : min) : 0;
  if (mn > 0 && mn == maks) return 'Pilih $mn';
  final bagian = <String>[];
  if (mn > 0) bagian.add('minimal $mn');
  if (maks > 0) bagian.add('maksimal $maks');
  if (bagian.isEmpty) return 'Bebas pilih';
  final teks = bagian.join(', ');
  return mn > 0 ? 'Pilih $teks' : '${teks[0].toUpperCase()}${teks.substring(1)}';
}

class VariasiGrup {
  final int id;
  final String nama;
  final bool wajib;

  /// Minimal pilihan (hanya berlaku bila wajib). Selalu >= 1 saat wajib.
  final int minPilih;

  /// Maksimal pilihan: 1 = pilih satu, N = batas, 0 = tanpa batas.
  final int maksPilih;
  final bool aktif;
  final List<VariasiOpsi> opsi;
  final List<int> menuIds;
  const VariasiGrup({
    required this.id,
    required this.nama,
    required this.wajib,
    this.minPilih = 0,
    required this.maksPilih,
    required this.aktif,
    this.opsi = const [],
    this.menuIds = const [],
  });

  bool get pilihSatu => maksPilih == 1;

  /// Minimal yang benar-benar harus dipilih (tidak melebihi jumlah opsi aktif).
  int get minEfektif {
    final mn = wajib ? (minPilih < 1 ? 1 : minPilih) : 0;
    final aktifCount = opsi.where((o) => o.aktif).length;
    return mn > aktifCount ? aktifCount : mn;
  }

  String get aturan => aturanVariasi(wajib: wajib, min: minPilih, maks: maksPilih);

  String get keterangan => '${wajib ? 'Wajib' : 'Opsional'} • $aturan';
}

/// Pilihan variasi yang menempel pada satu item keranjang.
/// Harga & bahan SELALU dihitung ulang dari database saat checkout;
/// hargaTambah di sini hanya untuk tampilan di keranjang.
class PilihanVariasi {
  final int grupId;
  final int opsiId;
  final String grupNama;
  final String opsiNama;
  final int hargaTambah;

  /// Bahan yang terpotong per porsi (untuk cek stok di kasir; hitungan final di repository).
  final List<VariasiBahan> bahan;
  const PilihanVariasi({
    required this.grupId,
    required this.opsiId,
    required this.grupNama,
    required this.opsiNama,
    required this.hargaTambah,
    this.bahan = const [],
  });
}

int totalHargaVariasi(Iterable<PilihanVariasi> v) => v.fold(0, (a, e) => a + e.hargaTambah);
