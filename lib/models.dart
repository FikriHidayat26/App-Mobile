// models.dart — model data, konstanta pilihan, dan format struk.

const List<String> kSatuanDasar = [
  'kg', 'gram', 'ons', 'buah', 'biji', 'ikat', 'pack', 'bungkus',
  'keping', 'porsi', 'ml', 'liter', 'saset', 'siung', 'lembar',
];

const List<String> kKuah = [
  'Kuah banyak',
  'Kuah sedang',
  'Kuah sedikit',
  'Nyemek (kuah kental sedikit)',
];

const List<String> kRasa = [
  'Original/Sedang',
  'Gurih',
  'Asin',
  'Manis',
  'Gurih manis',
  'Asin manis',
  'Asin gurih manis',
];

const List<String> kMetodeBayar = ['TUNAI', 'QRIS', 'TRANSFER'];

String rupiah(num v) {
  final neg = v < 0;
  final s = v.abs().round().toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write('.');
    b.write(s[i]);
  }
  return '${neg ? '-' : ''}Rp ${b.toString()}';
}

String fmtQty(double v) {
  if ((v - v.roundToDouble()).abs() < 1e-9) return v.round().toString();
  var s = v.toStringAsFixed(3);
  s = s.replaceFirst(RegExp(r'0+$'), '');
  return s.replaceFirst(RegExp(r'\.$'), '');
}

double _d(Object? v) => (v as num?)?.toDouble() ?? 0;

// ---------------------------------------------------------------- MASTER

class Bahan {
  int? id;
  String nama;
  String satuanDasar;
  double stok;
  double stokMinimum;
  double hppPerDasar;
  bool aktif;
  bool bisaPrasmanan;
  int hargaPrasmanan; // harga jual per 1 pilihan (rupiah)
  double qtyPrasmanan; // stok terpakai per 1 pilihan (satuan dasar)

  Bahan({
    this.id,
    required this.nama,
    required this.satuanDasar,
    this.stok = 0,
    this.stokMinimum = 0,
    this.hppPerDasar = 0,
    this.aktif = true,
    this.bisaPrasmanan = false,
    this.hargaPrasmanan = 0,
    this.qtyPrasmanan = 1,
  });

  factory Bahan.fromMap(Map<String, Object?> m) => Bahan(
        id: m['id'] as int?,
        nama: m['nama'] as String,
        satuanDasar: m['satuan_dasar'] as String,
        stok: _d(m['stok']),
        stokMinimum: _d(m['stok_minimum']),
        hppPerDasar: _d(m['hpp_per_dasar']),
        aktif: (m['aktif'] as int? ?? 1) == 1,
        bisaPrasmanan: (m['bisa_prasmanan'] as int? ?? 0) == 1,
        hargaPrasmanan: (m['harga_prasmanan'] as num?)?.toInt() ?? 0,
        qtyPrasmanan: (m['qty_prasmanan'] as num?)?.toDouble() ?? 1,
      );

  bool get stokRendah => stok <= stokMinimum;
}

class Menu {
  final int? id;
  final String nama;
  final String? kategori;
  final int hargaJual;
  const Menu({this.id, required this.nama, this.kategori, required this.hargaJual});

  factory Menu.fromMap(Map<String, Object?> m) => Menu(
        id: m['id'] as int?,
        nama: m['nama'] as String,
        kategori: m['kategori'] as String?,
        hargaJual: (m['harga_jual'] as num?)?.toInt() ?? 0,
      );
}

class ResepItem {
  final int bahanId;
  final String nama;
  final String satuan;
  final double qty; // per 1 porsi
  const ResepItem({
    required this.bahanId,
    required this.nama,
    required this.satuan,
    required this.qty,
  });
}

// ---------------------------------------------------------------- KERANJANG

class ToppingDipilih {
  final Bahan bahan;
  int pick;
  ToppingDipilih(this.bahan, this.pick);

  int get harga => bahan.hargaPrasmanan * pick;
  double get qtyDasar => bahan.qtyPrasmanan * pick;
}

class CartItem {
  final Menu? menu; // null = seblak prasmanan
  final List<ResepItem> resep;
  final Set<int> resepDihapus; // bahanId resep yang tidak dipakai
  final List<ToppingDipilih> topping;
  final int biayaDasar; // hanya untuk prasmanan
  int levelPedas;
  String? levelCustom;
  String kuah;
  String rasa;
  String catatan;
  int qty;

  CartItem({
    this.menu,
    this.resep = const [],
    Set<int>? resepDihapus,
    List<ToppingDipilih>? topping,
    this.biayaDasar = 0,
    this.levelPedas = 0,
    this.levelCustom,
    this.kuah = 'Kuah sedang',
    this.rasa = 'Original/Sedang',
    this.catatan = '',
    this.qty = 1,
  })  : resepDihapus = resepDihapus ?? <int>{},
        topping = topping ?? <ToppingDipilih>[];

  bool get prasmanan => menu == null;
  String get namaItem => prasmanan ? 'Seblak Prasmanan' : menu!.nama;

  String get levelLabel {
    final c = levelCustom?.trim() ?? '';
    return c.isNotEmpty ? c : 'Level $levelPedas';
  }

  int get hargaSatuan {
    final t = topping.fold<int>(0, (a, e) => a + e.harga);
    return prasmanan ? biayaDasar + t : menu!.hargaJual + t;
  }

  int get subtotal => hargaSatuan * qty;

  /// Kebutuhan stok per 1 porsi: bahanId -> qty satuan dasar.
  Map<int, double> get kebutuhanPerPorsi {
    final k = <int, double>{};
    for (final r in resep) {
      if (resepDihapus.contains(r.bahanId)) continue;
      k[r.bahanId] = (k[r.bahanId] ?? 0) + r.qty;
    }
    for (final t in topping) {
      if (t.pick <= 0) continue;
      k[t.bahan.id!] = (k[t.bahan.id!] ?? 0) + t.qtyDasar;
    }
    return k;
  }

  /// Baris ringkasan pesanan untuk layar kasir.
  List<String> get ringkasan {
    final out = <String>[];
    final hapus = resep.where((r) => resepDihapus.contains(r.bahanId)).map((r) => r.nama);
    if (hapus.isNotEmpty) out.add('Tanpa: ${hapus.join(', ')}');
    final tops = topping.where((t) => t.pick > 0);
    if (tops.isNotEmpty) {
      out.add('${prasmanan ? 'Pilihan' : 'Tambah'}: ${tops.map((t) => '${t.bahan.nama} x${t.pick}').join(', ')}');
    }
    out.add('Pedas: $levelLabel');
    out.add('Kuah: $kuah');
    out.add('Rasa: $rasa');
    if (catatan.trim().isNotEmpty) out.add('Catatan: ${catatan.trim()}');
    return out;
  }
}

// ---------------------------------------------------------------- HASIL & STRUK

class HasilTransaksi {
  final int id;
  final String noNota;
  final int total;
  final double totalHpp;
  const HasilTransaksi(this.id, this.noNota, this.total, this.totalHpp);
}

class StrukTopping {
  final String nama;
  final String jenis;
  final int pick;
  final int harga;
  const StrukTopping(this.nama, this.jenis, this.pick, this.harga);
}

class StrukItem {
  final String tipe;
  final String nama;
  final int qty;
  final int hargaSatuan;
  final String? levelPedas;
  final String? kuah;
  final String? rasa;
  final String? catatan;
  final List<StrukTopping> topping;
  const StrukItem({
    required this.tipe,
    required this.nama,
    required this.qty,
    required this.hargaSatuan,
    this.levelPedas,
    this.kuah,
    this.rasa,
    this.catatan,
    this.topping = const [],
  });
}

class Struk {
  final int id;
  final String noNota;
  final String waktu;
  final String metode;
  final int total;
  final String status;
  final List<StrukItem> items;
  const Struk({
    required this.id,
    required this.noNota,
    required this.waktu,
    required this.metode,
    required this.total,
    required this.status,
    required this.items,
  });
}

class RingkasTransaksi {
  final int id;
  final String noNota;
  final String waktu;
  final String metode;
  final int total;
  final String status;
  const RingkasTransaksi(this.id, this.noNota, this.waktu, this.metode, this.total, this.status);
}

String _kanan(String kiri, String kanan, {int lebar = 32}) {
  final sisa = lebar - kiri.length - kanan.length;
  return '$kiri${' ' * (sisa > 1 ? sisa : 1)}$kanan';
}

String teksStruk(Struk s, {String namaKedai = 'KEDAI SEBLAK', int? bayar}) {
  final b = StringBuffer();
  b.writeln(namaKedai);
  b.writeln('No   : ${s.noNota}');
  b.writeln('Waktu: ${s.waktu}');
  b.writeln('Bayar: ${s.metode}${s.status == 'VOID' ? '  [VOID]' : ''}');
  b.writeln('-' * 32);
  for (final it in s.items) {
    b.writeln(_kanan('${it.qty}x ${it.nama}', rupiah(it.hargaSatuan * it.qty)));
    final hapus = it.topping.where((t) => t.jenis == 'HAPUS').map((t) => t.nama);
    if (hapus.isNotEmpty) b.writeln('   Tanpa: ${hapus.join(', ')}');
    for (final t in it.topping.where((t) => t.jenis != 'HAPUS')) {
      b.writeln(_kanan('   + ${t.nama} x${t.pick}', rupiah(t.harga * it.qty)));
    }
    if (it.levelPedas != null) b.writeln('   Pedas: ${it.levelPedas}');
    if (it.kuah != null) b.writeln('   Kuah : ${it.kuah}');
    if (it.rasa != null) b.writeln('   Rasa : ${it.rasa}');
    if ((it.catatan ?? '').trim().isNotEmpty) b.writeln('   Cat  : ${it.catatan}');
  }
  b.writeln('-' * 32);
  b.writeln(_kanan('TOTAL', rupiah(s.total)));
  if (bayar != null && s.metode == 'TUNAI') {
    b.writeln(_kanan('Bayar', rupiah(bayar)));
    b.writeln(_kanan('Kembali', rupiah(bayar - s.total)));
  }
  b.writeln('Terima kasih!');
  return b.toString();
}

// ---------------------------------------------------------------- AUDIT

class SelisihStok {
  final int bahanId;
  final String nama;
  final String satuan;
  final double stok;
  final double ledger;
  const SelisihStok(this.bahanId, this.nama, this.satuan, this.stok, this.ledger);
  double get selisih => stok - ledger;
}

class KeuanganHarian {
  final String tanggal;
  final int omzetHeader;
  final int omzetItem;
  final double hppHeader;
  final double hppItem;
  const KeuanganHarian(this.tanggal, this.omzetHeader, this.omzetItem, this.hppHeader, this.hppItem);
  bool get cocok => omzetHeader == omzetItem && (hppHeader - hppItem).abs() < 0.5;
}
