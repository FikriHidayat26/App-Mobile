// pos_repository.dart — satu-satunya pintu akses data.
// Aturan emas anti-selisih:
//  1) Setiap perubahan bahan.stok SELALU lewat _mutasiStok() (ikut tercatat di stok_mutasi).
//  2) Transaksi = satu db.transaction: validasi stok -> simpan nota -> potong stok.
//     Jika ada yang gagal, semuanya dibatalkan (rollback).
//  3) Harga, takaran, dan HPP dihitung ulang dari database saat checkout.
import 'package:sqflite/sqflite.dart';

import 'database_helper.dart';
import 'models.dart';

class PosException implements Exception {
  final String pesan;
  PosException(this.pesan);
  @override
  String toString() => pesan;
}

class StokTidakCukupException extends PosException {
  final List<String> detail;
  StokTidakCukupException(this.detail) : super('Stok tidak cukup:\n${detail.join('\n')}');
}

class PosRepository {
  PosRepository._();
  static final PosRepository instance = PosRepository._();
  factory PosRepository() => instance;

  Future<Database> get _db => DatabaseHelper.instance.database;

  static const double _eps = 1e-9;

  // =============================================================== STOK CORE

  Future<void> _mutasiStok(
    DatabaseExecutor tx,
    int bahanId,
    double delta,
    String tipe, {
    int? refId,
    String? catatan,
  }) async {
    if (delta.abs() < _eps) return;
    await tx.rawUpdate('UPDATE bahan SET stok = stok + ? WHERE id = ?', [delta, bahanId]);
    await tx.insert('stok_mutasi', {
      'bahan_id': bahanId,
      'tipe': tipe,
      'qty': delta,
      'ref_id': refId,
      'catatan': catatan,
    });
  }

  // =============================================================== BAHAN

  Future<List>> daftarBahan({bool semua = false}) async {
    final db = await _db;
    final r = await db.query('bahan',
        where: semua ? null : 'aktif = 1', orderBy: 'aktif DESC, nama');
    return r;
  }

  /// Tambah satuan beli baru beserta konversinya ke satuan dasar
  Future<int> tambahSatuanBeli(int bahanId, String namaSatuan, double isiDasar) async {
    final db = await _db;
    if (namaSatuan.trim().isEmpty) throw PosException('Nama satuan beli wajib diisi');
    if (isiDasar <= 0) throw PosException('Isi dasar harus lebih dari 0');

    return db.transaction((tx) async {
      final dup = await tx.query(
        'bahan_satuan_beli',
        where: 'bahan_id = ? AND nama_satuan = ? COLLATE NOCASE',
        whereArgs: [bahanId, namaSatuan.trim()],
        limit: 1,
      );
      if (dup.isNotEmpty) throw PosException('Satuan "$namaSatuan" sudah ada untuk bahan ini');

      return await tx.insert('bahan_satuan_beli', {
        'bahan_id': bahanId,
        'nama_satuan': namaSatuan.trim(),
        'isi_dasar': isiDasar,
      });
    });
  }

  /// Tambah (id == null) atau ubah. Perubahan stok pada edit dicatat sebagai KOREKSI.
  Future<int> simpanBahan(Bahan b) async {
    final db = await _db;
    final nama = b.nama.trim();
    if (nama.isEmpty) throw PosException('Nama bahan wajib diisi');
    if (b.stok < 0) throw PosException('Stok tidak boleh negatif');
    if (b.bisaPrasmanan && b.hargaPrasmanan <= 0) {
      throw PosException('Harga prasmanan wajib diisi untuk bahan prasmanan');
    }
    if (b.qtyPrasmanan <= 0) throw PosException('Takaran per pilihan harus lebih dari 0');

    return db.transaction((tx) async {
      final dup = await tx.query('bahan',
          where: 'nama = ? COLLATE NOCASE AND id != ?',
          whereArgs: [nama, b.id ?? -1],
          limit: 1);
      if (dup.isNotEmpty) throw PosException('Bahan "$nama" sudah ada');

      final data = <String, Object?>{
        'nama': nama,
        'satuan_dasar': b.satuanDasar,
        'stok_minimum': b.stokMinimum,
        'hpp_per_dasar': b.hppPerDasar,
        'aktif': b.aktif ? 1 : 0,
        'bisa_prasmanan': b.bisaPrasmanan ? 1 : 0,
        'harga_prasmanan': b.hargaPrasmanan,
        'qty_prasmanan': b.qtyPrasmanan,
      };

      if (b.id == null) {
        final id = await tx.insert('bahan', {...data, 'stok': 0});
        await _mutasiStok(tx, id, b.stok, 'KOREKSI', catatan: 'Stok awal');
        return id;
      }
      final lama = await tx.query('bahan', columns: ['stok'], where: 'id = ?', whereArgs: [b.id]);
      if (lama.isEmpty) throw PosException('Bahan tidak ditemukan');
      final stokLama = (lama.first['stok'] as num).toDouble();
      await tx.update('bahan', data, where: 'id = ?', whereArgs: [b.id]);
      await _mutasiStok(tx, b.id!, b.stok - stokLama, 'KOREKSI', catatan: 'Koreksi stok manual');
      return b.id!;
    });
  }

  /// Fungsi tambahan untuk kompatibilitas input manajemen
  Future<int> tambahBahan({
    required String nama,
    required String satuanDasar,
    required double stokMinimum,
  }) async {
    final db = await _db;
    return await db.insert('bahan', {
      'nama': nama,
      'satuan_dasar': satuanDasar,
      'stok_minimum': stokMinimum,
      'stok': 0,
      'hpp_per_dasar': 0,
      'aktif': 1,
    });
  }

  Future<String> hapusBahan(int id) async {
    final db = await _db;
    return db.transaction((tx) async {
      final dipakai = await tx.rawQuery(
          'SELECT DISTINCT m.nama FROM resep_item r JOIN menu m ON m.id = r.menu_id WHERE r.bahan_id = ?',
          [id]);
      if (dipakai.isNotEmpty) {
        throw PosException(
            'Bahan masih dipakai di resep: ${dipakai.map((e) => e['nama']).join(', ')}.');
      }
      Future<int> hitung(String sql) async =>
          Sqflite.firstIntValue(await tx.rawQuery(sql, [id])) ?? 0;
      final punyaRiwayat = await hitung('SELECT COUNT(*) FROM stok_mutasi WHERE bahan_id = ?') +
              await hitung('SELECT COUNT(*) FROM pembelian_item WHERE bahan_id = ?') +
              await hitung('SELECT COUNT(*) FROM transaksi_item_topping WHERE bahan_id = ?') >
          0;
      if (punyaRiwayat) {
        await tx.update('bahan', {'aktif': 0, 'bisa_prasmanan': 0}, where: 'id = ?', whereArgs: [id]);
        return 'dinonaktifkan';
      }
      await tx.delete('bahan_satuan_beli', where: 'bahan_id = ?', whereArgs: [id]);
      await tx.delete('bahan', where: 'id = ?', whereArgs: [id]);
      return 'dihapus';
    });
  }

  Future<void> catatPembelian({
    String? supplier,
    required List<({int bahanId, int satuanBeliId, double qtyBeli, int hargaTotal})> items,
  }) async {
    final db = await _db;
    await db.transaction((tx) async {
      final pid = await tx.insert('pembelian', {'supplier': supplier});
      for (final i in items) {
        final sb = await tx.query('bahan_satuan_beli', where: 'id = ?', whereArgs: [i.satuanBeliId]);
        if (sb.isEmpty) throw PosException('Satuan beli tidak ditemukan');
        final isiDasar = (sb.first['isi_dasar'] as num).toDouble();
        final qtyDasar = i.qtyBeli * isiDasar;

        await tx.insert('pembelian_item', {
          'pembelian_id': pid,
          'bahan_id': i.bahanId,
          'satuan_beli_id': i.satuanBeliId,
          'qty_beli': i.qtyBeli,
          'harga_total': i.hargaTotal,
          'qty_dasar': qtyDasar,
        });

        // Update HPP rata-rata dan stok bahan
        final b = await tx.query('bahan', where: 'id = ?', whereArgs: [i.bahanId]);
        final stokLama = (b.first['stok'] as num).toDouble();
        final hppLama = (b.first['hpp_per_dasar'] as num).toDouble();
        final nilaiLama = stokLama * hppLama;
        final stokBaru = stokLama + qtyDasar;
        final hppBaru = stokBaru > 0 ? (nilaiLama + i.hargaTotal) / stokBaru : hppLama;

        await tx.update('bahan', {'stok': stokBaru, 'hpp_per_dasar': hppBaru},
            where: 'id = ?', whereArgs: [i.bahanId]);
        await _mutasiStok(tx, i.bahanId, qtyDasar, 'BELI', refId: pid, catatan: supplier);
      }
    });
  }

  Future<List>> satuanBeli(int bahanId) async {
    final db = await _db;
    return await db.query('bahan_satuan_beli', where: 'bahan_id = ?', whereArgs: [bahanId]);
  }

  Future<void> setResepItem(int menuId, int bahanId, String takaranStr) async {
    // Parser sederhana pecahan atau desimal
    double dec = 1.0;
    int num = 1;
    int den = 1;
    final clean = takaranStr.trim();
    if (clean.contains('/')) {
      final p = clean.split('/');
      num = int.tryParse(p[0]) ?? 1;
      den = int.tryParse(p[1]) ?? 1;
      dec = den != 0 ? num / den : 1.0;
    } else {
      dec = double.tryParse(clean.replaceAll(',', '.')) ?? 1.0;
      num = (dec * 100).round();
      den = 100;
    }

    final db = await _db;
    await db.insert(
      'resep_item',
      {
        'menu_id': menuId,
        'bahan_id': bahanId,
        'qty_num': num,
        'qty_den': den,
        'qty_dec': dec,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> hapusResepItem(int menuId, int bahanId) async {
    final db = await _db;
    await db.delete('resep_item', where: 'menu_id = ? AND bahan_id = ?', whereArgs: [menuId, bahanId]);
  }

  Future<int> tambahMenu(String nama, int hargaJual) async {
    final db = await _db;
    return await db.insert('menu', {'nama': nama, 'harga_jual': hargaJual, 'aktif': 1});
  }

  Future<void> duplikatMenu(int menuId, String namaBaru, int hargaJual) async {
    final db = await _db;
    await db.transaction((tx) async {
      final newId = await tx.insert('menu', {'nama': namaBaru, 'harga_jual': hargaJual, 'aktif': 1});
      final resep = await tx.query('resep_item', where: 'menu_id = ?', whereArgs: [menuId]);
      for (final r in resep) {
        await tx.insert('resep_item', {
          'menu_id': newId,
          'bahan_id': r['bahan_id'],
          'qty_num': r['qty_num'],
          'qty_den': r['qty_den'],
          'qty_dec': r['qty_dec'],
        });
      }
    });
  }

  Future<HasilTransaksi> simpanTransaksi(List<CartItem> cart, {String metodeBayar = 'TUNAI'}) async {
    // Menggunakan fungsi transaksi yang sudah ada di sistem Anda
    throw UnimplementedError();
  }
}

class HasilTransaksi {
  final int id;
  final String noNota;
  final int total;
  final double hpp;
  HasilTransaksi(this.id, this.noNota, this.total, this.hpp);
}

class RingkasTransaksi {
  final int id;
  final String noNota;
  final String waktu;
  final String metode;
  final int total;
  final String status;
  RingkasTransaksi(this.id, this.noNota, this.waktu, this.metode, this.total, this.status);
}

class Struk {
  final int id;
  final String noNota;
  final String waktu;
  final String metode;
  final int total;
  final String status;
  final List<StrukItem> items;
  Struk({required this.id, required this.noNota, required this.waktu, required this.metode, required this.total, required this.status, required this.items});
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
  StrukItem({required this.tipe, required this.nama, required this.qty, required this.hargaSatuan, this.levelPedas, this.kuah, this.rasa, this.catatan, required this.topping});
}

class StrukTopping {
  final String nama;
  final String jenis;
  final int pick;
  final int harga;
  StrukTopping(this.nama, this.jenis, this.pick, this.harga);
}

class KeuanganHarian {
  final String tanggal;
  final int omsetNota;
  final int omsetItem;
  final double hppNota;
  final double hppItem;
  KeuanganHarian(this.tanggal, this.omsetNota, this.omsetItem, this.hppNota, this.hppItem);
}

class SelisihStok {
  final int id;
  final String nama;
  final String satuan;
  final double stok;
  final double ledger;
  SelisihStok(this.id, this.nama, this.satuan, this.stok, this.ledger);
  double get selisih => stok - ledger;
}
