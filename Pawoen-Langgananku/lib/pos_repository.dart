// pos_repository.dart
// Dependensi (pubspec.yaml): sqflite, path
// Jalankan schema.sql saat onCreate database.

import 'package:sqflite/sqflite.dart';

/// Parser takaran: "1/12", "0.5", "0,5", "5" -> (num, den)
class Takaran {
  final int num;
  final int den;
  const Takaran(this.num, this.den);

  double get nilai => num / den;
  @override
  String toString() => den == 1 ? '$num' : '$num/$den';

  factory Takaran.parse(String input) {
    final s = input.trim().replaceAll(',', '.');
    if (s.contains('/')) {
      final p = s.split('/');
      final n = int.parse(p[0].trim());
      final d = int.parse(p[1].trim());
      if (n <= 0 || d <= 0) throw FormatException('Takaran harus > 0');
      return Takaran._reduce(n, d);
    }
    // desimal -> pecahan (maks 4 angka di belakang koma)
    final v = double.parse(s);
    if (v <= 0) throw FormatException('Takaran harus > 0');
    const den = 10000;
    return Takaran._reduce((v * den).round(), den);
  }

  static Takaran _reduce(int n, int d) {
    int a = n, b = d;
    while (b != 0) {
      final t = a % b;
      a = b;
      b = t;
    }
    return Takaran(n ~/ a, d ~/ a);
  }
}

class ItemKeranjang {
  final int menuId;
  int qty;
  ItemKeranjang(this.menuId, this.qty);
}

class StokKurang {
  final String bahan;
  final double butuh;
  final double tersedia;
  StokKurang(this.bahan, this.butuh, this.tersedia);
}

class PosRepository {
  final Database db;
  PosRepository(this.db);

  // ---------- BAHAN ----------
  Future<int> tambahBahan({
    required String nama,
    required String satuanDasar,
    double stokMinimum = 0,
  }) =>
      db.insert('bahan', {
        'nama': nama,
        'satuan_dasar': satuanDasar,
        'stok_minimum': stokMinimum,
      });

  Future<int> tambahSatuanBeli(int bahanId, String nama, double isiDasar) =>
      db.insert('bahan_satuan_beli',
          {'bahan_id': bahanId, 'nama_satuan': nama, 'isi_dasar': isiDasar});

  Future<void> nonaktifkanBahan(int id) =>
      db.update('bahan', {'aktif': 0}, where: 'id = ?', whereArgs: [id]).then((_) {});

  // ---------- MENU & RESEP ----------
  Future<int> tambahMenu(String nama, int hargaJual, {String? kategori}) =>
      db.insert('menu', {'nama': nama, 'harga_jual': hargaJual, 'kategori': kategori});

  Future<void> setResepItem(int menuId, int bahanId, String takaran) async {
    final t = Takaran.parse(takaran);
    await db.insert(
      'resep_item',
      {'menu_id': menuId, 'bahan_id': bahanId, 'qty_num': t.num, 'qty_den': t.den},
      conflictAlgorithm: ConflictAlgorithm.replace, // update jika sudah ada
    );
  }

  Future<void> hapusResepItem(int menuId, int bahanId) => db.delete('resep_item',
      where: 'menu_id = ? AND bahan_id = ?', whereArgs: [menuId, bahanId]);

  /// Salin resep (mis. Seblak Umume -> Seblak Special lalu tambah bahan)
  Future<void> duplikatMenu(int menuId, String namaBaru, int hargaBaru) async {
    await db.transaction((txn) async {
      final newId = await txn.insert('menu', {'nama': namaBaru, 'harga_jual': hargaBaru});
      await txn.rawInsert('''
        INSERT INTO resep_item (menu_id, bahan_id, qty_num, qty_den)
        SELECT ?, bahan_id, qty_num, qty_den FROM resep_item WHERE menu_id = ?
      ''', [newId, menuId]);
    });
  }

  Future<double> hppMenu(DatabaseExecutor ex, int menuId) async {
    final r = await ex.rawQuery(
        'SELECT hpp_bahan FROM v_hpp_menu WHERE menu_id = ?', [menuId]);
    return r.isEmpty ? 0 : (r.first['hpp_bahan'] as num).toDouble();
  }

  // ---------- PEMBELIAN ----------
  /// items: {bahanId, satuanBeliId, qtyBeli, hargaTotal}
  Future<int> catatPembelian({
    String? supplier,
    required List<({int bahanId, int satuanBeliId, double qtyBeli, int hargaTotal})> items,
  }) async {
    return db.transaction((txn) async {
      final pid = await txn.insert('pembelian', {'supplier': supplier});
      for (final it in items) {
        final s = await txn.query('bahan_satuan_beli',
            columns: ['isi_dasar'], where: 'id = ?', whereArgs: [it.satuanBeliId]);
        final isi = (s.first['isi_dasar'] as num).toDouble();
        await txn.insert('pembelian_item', {
          'pembelian_id': pid,
          'bahan_id': it.bahanId,
          'satuan_beli_id': it.satuanBeliId,
          'qty_beli': it.qtyBeli,
          'harga_total': it.hargaTotal,
          'qty_dasar': it.qtyBeli * isi, // trigger SQL yang menaikkan stok & HPP
        });
      }
      return pid;
    });
  }

  // ---------- CEK STOK ----------
  Future<Map<int, double>> _kebutuhan(DatabaseExecutor ex, List<ItemKeranjang> k) async {
    final butuh = <int, double>{};
    for (final item in k) {
      final resep = await ex.query('resep_item',
          where: 'menu_id = ?', whereArgs: [item.menuId]);
      for (final r in resep) {
        final id = r['bahan_id'] as int;
        final per = (r['qty_num'] as int) / (r['qty_den'] as int);
        butuh[id] = (butuh[id] ?? 0) + per * item.qty;
      }
    }
    return butuh;
  }

  Future<List<StokKurang>> cekStok(List<ItemKeranjang> keranjang) async {
    final butuh = await _kebutuhan(db, keranjang);
    final kurang = <StokKurang>[];
    for (final e in butuh.entries) {
      final b = await db.query('bahan', where: 'id = ?', whereArgs: [e.key]);
      final stok = (b.first['stok'] as num).toDouble();
      if (stok + 1e-9 < e.value) {
        kurang.add(StokKurang(b.first['nama'] as String, e.value, stok));
      }
    }
    return kurang;
  }

  // ---------- CHECKOUT ----------
  /// Atomik: semua berhasil atau semua dibatalkan.
  Future<int> checkout(List<ItemKeranjang> keranjang,
      {String metodeBayar = 'TUNAI'}) async {
    return db.transaction((txn) async {
      final noNota = 'N${DateTime.now().millisecondsSinceEpoch}';
      final trxId = await txn.insert('transaksi',
          {'no_nota': noNota, 'metode_bayar': metodeBayar});

      int total = 0;
      double totalHpp = 0;

      for (final item in keranjang) {
        final m = await txn.query('menu', where: 'id = ?', whereArgs: [item.menuId]);
        final harga = m.first['harga_jual'] as int;
        final hpp = await hppMenu(txn, item.menuId); // snapshot saat ini
        await txn.insert('transaksi_item', {
          'transaksi_id': trxId,
          'menu_id': item.menuId,
          'qty': item.qty,
          'harga_jual': harga,
          'hpp_snapshot': hpp,
        });
        total += harga * item.qty;
        totalHpp += hpp * item.qty;
      }

      // potong stok sesuai takaran pecahan
      final butuh = await _kebutuhan(txn, keranjang);
      for (final e in butuh.entries) {
        await txn.rawUpdate('UPDATE bahan SET stok = stok - ? WHERE id = ?',
            [e.value, e.key]);
        await txn.insert('stok_mutasi', {
          'bahan_id': e.key,
          'tipe': 'JUAL',
          'qty': -e.value,
          'ref_id': trxId,
        });
      }

      await txn.update('transaksi', {'total': total, 'total_hpp': totalHpp},
          where: 'id = ?', whereArgs: [trxId]);
      return trxId;
    });
  }

  /// Batalkan transaksi: stok dikembalikan lewat mutasi VOID
  Future<void> voidTransaksi(int trxId) async {
    await db.transaction((txn) async {
      final mut = await txn.query('stok_mutasi',
          where: "tipe = 'JUAL' AND ref_id = ?", whereArgs: [trxId]);
      for (final m in mut) {
        final qty = -(m['qty'] as num).toDouble();
        await txn.rawUpdate('UPDATE bahan SET stok = stok + ? WHERE id = ?',
            [qty, m['bahan_id']]);
        await txn.insert('stok_mutasi',
            {'bahan_id': m['bahan_id'], 'tipe': 'VOID', 'qty': qty, 'ref_id': trxId});
      }
      await txn.update('transaksi', {'status': 'VOID'},
          where: 'id = ?', whereArgs: [trxId]);
    });
  }

  // ---------- STOK OPNAME & BUANG ----------
  Future<void> opname(int bahanId, double stokFisik, {String? catatan}) async {
    await db.transaction((txn) async {
      final b = await txn.query('bahan', where: 'id = ?', whereArgs: [bahanId]);
      final selisih = stokFisik - (b.first['stok'] as num).toDouble();
      await txn.update('bahan', {'stok': stokFisik}, where: 'id = ?', whereArgs: [bahanId]);
      await txn.insert('stok_mutasi', {
        'bahan_id': bahanId, 'tipe': 'OPNAME', 'qty': selisih, 'catatan': catatan,
      });
    });
  }

  Future<void> buangBahan(int bahanId, double qty, {String? catatan}) async {
    await db.transaction((txn) async {
      await txn.rawUpdate('UPDATE bahan SET stok = stok - ? WHERE id = ?', [qty, bahanId]);
      await txn.insert('stok_mutasi', {
        'bahan_id': bahanId, 'tipe': 'BUANG', 'qty': -qty, 'catatan': catatan,
      });
    });
  }

  // ---------- LAPORAN ----------
  Future<List<Map<String, Object?>>> rekapHarian() =>
      db.query('v_rekap_harian', orderBy: 'tanggal DESC', limit: 30);

  Future<List<Map<String, Object?>>> stokRealtime() => db.query('v_stok', orderBy: 'nama');

  Future<List<Map<String, Object?>>> marginMenu() => db.query('v_margin_menu');
}

// ---------- CONTOH PEMAKAIAN ----------
// final repo = PosRepository(db);
// final keranjang = [ItemKeranjang(1, 3)];            // 3x Seblak Umume
// final kurang = await repo.cekStok(keranjang);
// if (kurang.isEmpty) await repo.checkout(keranjang, metodeBayar: 'QRIS');
// // enoki berkurang 3 * 1/12 = 0.25 bungkus

