// models.dart — model data, konstanta pilihan, dan format struk.

const List<String> kSatuanDasar = [
  'kg', 'gram', 'ons', 'buah', 'biji', 'ikat', 'pcs','pack', 'bungkus',
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

/// Baris "kiri ... kanan" (nama + harga). Nama yang kepanjangan dibungkus per kata ke
/// baris berikutnya (tidak dipotong); harga tetap rata kanan di baris terakhir.
/// Hasilnya bisa berisi beberapa baris (dipisah '\n').
String _kanan(String kiri, String kanan, {int lebar = 32}) {
  final ind0 = kiri.length - kiri.trimLeft().length;
  // Baris lanjutan menjorok 3 spasi dari awal baris pertama (sejajar setelah "1x ").
  final indent = ' ' * (ind0 + 3 > lebar ~/ 2 ? ind0 : ind0 + 3);
  final maksKata = lebar - indent.length;

  final lines = <String>[];
  var pre = ' ' * ind0;
  var cur = pre;
  var ada = false;

  void tutup() {
    lines.add(cur);
    pre = indent;
    cur = pre;
    ada = false;
  }

  for (final k in kiri.trim().split(RegExp(r'\s+'))) {
    var sisa = k;
    // Satu kata lebih panjang dari baris: potong paksa.
    while (maksKata > 0 && sisa.length > maksKata) {
      if (ada) tutup();
      cur = pre + sisa.substring(0, maksKata);
      ada = true;
      tutup();
      sisa = sisa.substring(maksKata);
    }
    if (!ada) {
      cur = pre + sisa;
      ada = true;
    } else if (cur.length + 1 + sisa.length <= lebar) {
      cur = '$cur $sisa';
    } else {
      tutup();
      cur = pre + sisa;
      ada = true;
    }
  }

  if (cur.length + 1 + kanan.length <= lebar) {
    lines.add('$cur${' ' * (lebar - cur.length - kanan.length)}$kanan');
  } else {
    lines.add(cur);
    final pad = lebar - kanan.length;
    lines.add('${' ' * (pad < 0 ? 0 : pad)}$kanan');
  }
  return lines.join('\n');
}

String teksStruk(Struk s,
    {String namaKedai = 'KEDAI SEBLAK', int? bayar, int lebar = 32, String footer = 'Terima kasih!'}) {
  final b = StringBuffer();
  b.writeln(namaKedai);
  b.writeln('No   : ${s.noNota}');
  b.writeln('Waktu: ${s.waktu}');
  b.writeln('Bayar: ${s.metode}${s.status == 'VOID' ? '  [VOID]' : ''}');
  b.writeln('-' * lebar);
  for (final it in s.items) {
    b.writeln(_kanan('${it.qty}x ${it.nama}', rupiah(it.hargaSatuan * it.qty), lebar: lebar));
    final hapus = it.topping.where((t) => t.jenis == 'HAPUS').map((t) => t.nama);
    if (hapus.isNotEmpty) b.writeln('   Tanpa: ${hapus.join(', ')}');
    for (final t in it.topping.where((t) => t.jenis != 'HAPUS')) {
      b.writeln(_kanan('   + ${t.nama} x${t.pick}', rupiah(t.harga * it.qty), lebar: lebar));
    }
    if (it.levelPedas != null) b.writeln('   Pedas: ${it.levelPedas}');
    if (it.kuah != null) b.writeln('   Kuah : ${it.kuah}');
    if (it.rasa != null) b.writeln('   Rasa : ${it.rasa}');
    if ((it.catatan ?? '').trim().isNotEmpty) b.writeln('   Cat  : ${it.catatan}');
  }
  b.writeln('-' * lebar);
  b.writeln(_kanan('TOTAL', rupiah(s.total), lebar: lebar));
  if (bayar != null && s.metode == 'TUNAI') {
    b.writeln(_kanan('Bayar', rupiah(bayar), lebar: lebar));
    b.writeln(_kanan('Kembali', rupiah(bayar - s.total), lebar: lebar));
  }
  if (footer.trim().isNotEmpty) b.writeln(footer.trim());
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

// ---------------------------------------------------------------- TAKARAN (pecahan)

/// Takaran resep sebagai pecahan agar akurat (mis. 1/3 mie), tanpa selisih pembulatan.
/// Input yang diterima: "1/3", "2 1/2", "0.5", "0,25", "3".
class Takaran {
  final int pembilang;
  final int penyebut;
  const Takaran(this.pembilang, this.penyebut);

  double get nilai => pembilang / penyebut;

  static int _fpb(int a, int b) => b == 0 ? a.abs() : _fpb(b, a % b);

  static Takaran _rapikan(int a, int b) {
    final g = _fpb(a, b);
    return g <= 1 ? Takaran(a, b) : Takaran(a ~/ g, b ~/ g);
  }

  static Takaran? tryParse(String input) {
    final s = input.trim().replaceAll(',', '.');
    if (s.isEmpty) return null;
    try {
      if (s.contains('/')) {
        final bagian = s.split(RegExp(r'\s+'));
        var bulat = 0;
        var pecahan = bagian.last;
        if (bagian.length == 2) bulat = int.parse(bagian.first);
        final ab = pecahan.split('/');
        if (ab.length != 2) return null;
        final a = int.parse(ab[0]);
        final b = int.parse(ab[1]);
        if (b <= 0 || a < 0 || bulat < 0) return null;
        return _rapikan(bulat * b + a, b);
      }
      final d = double.parse(s);
      if (d.isNaN || d.isInfinite || d < 0) return null;
      return _rapikan((d * 1000).round(), 1000);
    } catch (_) {
      return null;
    }
  }

  @override
  String toString() => penyebut == 1 ? '$pembilang' : '$pembilang/$penyebut';
}
