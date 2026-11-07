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

class VariasiGrup {
  final int id;
  final String nama;
  final bool wajib;

  /// 1 = pilih satu, >1 = batas jumlah pilihan, 0 = tanpa batas.
  final int maksPilih;
  final bool aktif;
  final List<VariasiOpsi> opsi;
  final List<int> menuIds;
  const VariasiGrup({
    required this.id,
    required this.nama,
    required this.wajib,
    required this.maksPilih,
    required this.aktif,
    this.opsi = const [],
    this.menuIds = const [],
  });

  bool get pilihSatu => maksPilih == 1;

  String get keterangan {
    final aturan = wajib ? 'Wajib' : 'Opsional';
    final batas = maksPilih == 1
        ? 'pilih 1'
        : (maksPilih == 0 ? 'pilih bebas' : 'maks $maksPilih');
    return '$aturan • $batas';
  }
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
