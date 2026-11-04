// pos_repository.dart — satu-satunya pintu akses data.
// Aturan emas anti-selisih:
//  1) Setiap perubahan bahan.stok SELALU lewat _mutasiStok() (ikut tercatat di stok_mutasi).
//  2) Transaksi = satu db.transaction: validasi stok -> simpan nota -> potong stok.
//     Jika ada yang gagal, semuanya dibatalkan (rollback).
//  3) Harga, takaran, dan HPP dihitung ulang dari database saat checkout.
import 'package:sqflite/sqflite.dart';

import 'database_helper.dart';
import 'models.dart';

typedef ItemBeli = ({int bahanId, int? satuanBeliId, double qtyBeli, int hargaTotal});

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

  // Database dibuka lewat DatabaseHelper, lalu skema biaya tetap dicek/diperbarui
  // otomatis (idempotent, tanpa perlu menaikkan versi database).
  Future<Database>? _dbSiap;
  Future<Database> get _db => _dbSiap ??= _bukaDb();

  Future<Database> _bukaDb() async {
    try {
      final d = await DatabaseHelper.instance.database;
      await _migrasiMingguan(d);
      return d;
    } catch (_) {
      _dbSiap = null; // coba lagi di pemanggilan berikutnya
      rethrow;
    }
  }

  /// Memastikan tabel overhead menerima periode MINGGUAN dan view overhead
  /// menghitung mingguan (x52/12). Aman dijalankan berulang; data lama tetap.
  Future<void> _migrasiMingguan(Database d) async {
    final t = await d.rawQuery(
        "SELECT sql FROM sqlite_master WHERE type='table' AND name='overhead'");
    final v = await d.rawQuery(
        "SELECT sql FROM sqlite_master WHERE type='view' AND name='v_overhead_per_porsi'");
    final tabelOk = t.isNotEmpty && '${t.first['sql']}'.contains('MINGGUAN');
    final viewOk = v.isNotEmpty && '${v.first['sql']}'.contains('MINGGUAN');
    if (tabelOk && viewOk) return;

    await d.transaction((tx) async {
      await tx.execute('DROP VIEW IF EXISTS v_margin_menu');
      await tx.execute('DROP VIEW IF EXISTS v_overhead_per_porsi');

      if (!tabelOk) {
        await tx.execute('''
          CREATE TABLE overhead_baru (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            nama TEXT NOT NULL,
            nominal INTEGER NOT NULL,
            periode TEXT NOT NULL CHECK (periode IN ('HARIAN','MINGGUAN','BULANAN')),
            aktif INTEGER NOT NULL DEFAULT 1
          )''');
        await tx.execute(
            'INSERT INTO overhead_baru SELECT id,nama,nominal,periode,aktif FROM overhead');
        await tx.execute('DROP TABLE overhead');
        await tx.execute('ALTER TABLE overhead_baru RENAME TO overhead');
      }

      await tx.execute('''
        CREATE VIEW v_overhead_per_porsi AS
        SELECT
          SUM(CASE periode WHEN 'BULANAN' THEN nominal
                           WHEN 'MINGGUAN' THEN nominal * 52.0 / 12
                           ELSE nominal * 30 END) AS overhead_bulanan,
          SUM(CASE periode WHEN 'BULANAN' THEN nominal
                           WHEN 'MINGGUAN' THEN nominal * 52.0 / 12
                           ELSE nominal * 30 END)
            / (SELECT MAX(CAST(nilai AS REAL), 1.0) FROM pengaturan
               WHERE kunci = 'estimasi_porsi_bulanan') AS per_porsi
        FROM overhead WHERE aktif = 1''');

      await tx.execute('''
        CREATE VIEW v_margin_menu AS
        SELECT h.nama, h.harga_jual, h.hpp_bahan,
               h.hpp_bahan + COALESCE(o.per_porsi,0) AS hpp_penuh,
               h.harga_jual - h.hpp_bahan - COALESCE(o.per_porsi,0) AS laba_per_porsi,
               CASE WHEN h.harga_jual > 0
                 THEN (h.harga_jual - h.hpp_bahan - COALESCE(o.per_porsi,0)) * 100.0 / h.harga_jual END AS margin_persen
        FROM v_hpp_menu h, v_overhead_per_porsi o''');
    });
  }

  // Getter publik agar bisa diakses oleh ManajemenQueries di manajemen_screen.dart
  Future<Database> get db => _db;

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

  Future<List<Bahan>> daftarBahan({bool semua = false}) async {
    final database = await _db;
    final r = await database.query('bahan',
        where: semua ? null : 'aktif = 1', orderBy: 'nama COLLATE NOCASE');
    return r.map(Bahan.fromMap).toList();
  }

  /// Tambah satuan beli baru beserta konversinya ke satuan dasar
  Future<int> tambahSatuanBeli(int bahanId, String namaSatuan, double isiDasar) async {
    final database = await _db;
    if (namaSatuan.trim().isEmpty) throw PosException('Nama satuan beli wajib diisi');
    if (isiDasar <= 0) throw PosException('Isi dasar harus lebih dari 0');

    return database.transaction((tx) async {
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
    final database = await _db;
    final nama = b.nama.trim();
    if (nama.isEmpty) throw PosException('Nama bahan wajib diisi');
    if (b.stok < 0) throw PosException('Stok tidak boleh negatif');
    if (b.bisaPrasmanan && b.hargaPrasmanan <= 0) {
      throw PosException('Harga prasmanan wajib diisi untuk bahan prasmanan');
    }
    if (b.qtyPrasmanan <= 0) throw PosException('Takaran per pilihan harus lebih dari 0');

    return database.transaction((tx) async {
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

  /// Hapus aman. Return 'dihapus' atau 'dinonaktifkan' (jika sudah punya riwayat).
  /// Ditolak jika masih dipakai di resep menu.
  Future<String> hapusBahan(int id) async {
    final database = await _db;
    return database.transaction((tx) async {
      final dipakai = await tx.rawQuery(
          'SELECT DISTINCT m.nama FROM resep_item r JOIN menu m ON m.id = r.menu_id WHERE r.bahan_id = ?',
          [id]);
      if (dipakai.isNotEmpty) {
        throw PosException(
            'Bahan masih dipakai di resep: ${dipakai.map((e) => e['nama']).join(', ')}.\n'
            'Hapus dari resep tersebut terlebih dahulu.');
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

  Future<List<Map<String, Object?>>> satuanBeli(int bahanId) async {
    final database = await _db;
    return database.query('bahan_satuan_beli',
        where: 'bahan_id = ?', whereArgs: [bahanId], orderBy: 'nama_satuan COLLATE NOCASE');
  }

  /// Kulak/restock. satuanBeliId null = langsung dalam satuan dasar.
  /// Trigger DB menaikkan stok + HPP rata-rata tertimbang + mutasi BELI.
  Future<void> catatPembelian({String? supplier, required List<ItemBeli> items}) async {
    if (items.isEmpty) throw PosException('Belum ada item pembelian');
    final database = await _db;
    await database.transaction((tx) async {
      final pid = await tx.insert('pembelian', {'supplier': supplier});
      for (final it in items) {
        if (it.qtyBeli <= 0) throw PosException('Jumlah beli harus lebih dari 0');
        if (it.hargaTotal < 0) throw PosException('Harga tidak valid');
        var isi = 1.0;
        if (it.satuanBeliId != null) {
          final r = await tx.query('bahan_satuan_beli',
              where: 'id = ? AND bahan_id = ?', whereArgs: [it.satuanBeliId, it.bahanId]);
          if (r.isEmpty) throw PosException('Satuan beli tidak cocok dengan bahan');
          isi = (r.first['isi_dasar'] as num).toDouble();
        }
        await tx.insert('pembelian_item', {
          'pembelian_id': pid,
          'bahan_id': it.bahanId,
          'satuan_beli_id': it.satuanBeliId,
          'qty_beli': it.qtyBeli,
          'harga_total': it.hargaTotal,
          'qty_dasar': it.qtyBeli * isi,
        });
      }
    });
  }

  // =============================================================== MENU

  Future<List<Menu>> daftarMenu() async {
    final database = await _db;
    final r = await database.query('menu', where: 'aktif = 1', orderBy: 'nama COLLATE NOCASE');
    return r.map(Menu.fromMap).toList();
  }

  Future<List<ResepItem>> resepMenu(int menuId) async {
    final database = await _db;
    final r = await database.rawQuery('''
      SELECT r.bahan_id, b.nama, b.satuan_dasar, r.qty_dec
      FROM resep_item r JOIN bahan b ON b.id = r.bahan_id
      WHERE r.menu_id = ? ORDER BY b.nama COLLATE NOCASE''', [menuId]);
    return r
        .map((e) => ResepItem(
              bahanId: e['bahan_id'] as int,
              nama: e['nama'] as String,
              satuan: e['satuan_dasar'] as String,
              qty: (e['qty_dec'] as num).toDouble(),
            ))
        .toList();
  }

  // =============================================================== PENGATURAN

  Future<String?> getPengaturan(String kunci) async {
    final database = await _db;
    final r = await database.query('pengaturan',
        columns: ['nilai'], where: 'kunci = ?', whereArgs: [kunci]);
    return r.isEmpty ? null : r.first['nilai'] as String;
  }

  Future<void> setPengaturan(String kunci, String nilai) async {
    final database = await _db;
    await database.insert('pengaturan', {'kunci': kunci, 'nilai': nilai},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<int> biayaDasarPrasmanan() async {
    final database = await _db;
    final r = await database.query('pengaturan',
        columns: ['nilai'], where: 'kunci = ?', whereArgs: ['biaya_dasar_prasmanan']);
    return r.isEmpty ? 0 : int.tryParse(r.first['nilai'] as String) ?? 0;
  }

  Future<void> setBiayaDasarPrasmanan(int nilai) async {
    final database = await _db;
    await database.insert('pengaturan', {'kunci': 'biaya_dasar_prasmanan', 'nilai': '$nilai'},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // =============================================================== TRANSAKSI

  Future<HasilTransaksi> simpanTransaksi(List<CartItem> cart, {String metodeBayar = 'TUNAI'}) async {
    if (cart.isEmpty) throw PosException('Keranjang kosong');
    if (!kMetodeBayar.contains(metodeBayar)) throw PosException('Metode bayar tidak valid');
    final database = await _db;

    return database.transaction((tx) async {
      final biayaDasarRow = await tx.query('pengaturan',
          columns: ['nilai'], where: 'kunci = ?', whereArgs: ['biaya_dasar_prasmanan']);
      final biayaDasar =
          biayaDasarRow.isEmpty ? 0 : int.tryParse(biayaDasarRow.first['nilai'] as String) ?? 0;

      final hitung = <_Hitung>[];
      final kebutuhanTotal = <int, double>{};
      final bahanCache = <int, Map<String, Object?>>{};

      Future<Map<String, Object?>> bahanRow(int id) async {
        final c = bahanCache[id];
        if (c != null) return c;
        final r = await tx.query('bahan', where: 'id = ?', whereArgs: [id]);
        if (r.isEmpty) throw PosException('Bahan (id $id) tidak ditemukan');
        return bahanCache[id] = r.first;
      }

      for (final c in cart) {
        if (c.qty <= 0) throw PosException('Jumlah porsi harus lebih dari 0');
        final h = _Hitung(c);
        final perPorsi = <int, double>{};
        var harga = 0;
        var hpp = 0.0;

        if (c.prasmanan) {
          if (!c.topping.any((t) => t.pick > 0)) {
            throw PosException('Seblak prasmanan belum punya topping');
          }
          harga += biayaDasar;
        } else {
          final m = await tx.query('menu', where: 'id = ? AND aktif = 1', whereArgs: [c.menu!.id]);
          if (m.isEmpty) throw PosException('Menu "${c.menu!.nama}" tidak tersedia');
          harga += (m.first['harga_jual'] as num).toInt();
          h.nama = m.first['nama'] as String;

          final resep = await tx.rawQuery(
              'SELECT bahan_id, qty_dec FROM resep_item WHERE menu_id = ?', [c.menu!.id]);
          for (final r in resep) {
            final bid = r['bahan_id'] as int;
            final br = await bahanRow(bid);
            final q = (r['qty_dec'] as num).toDouble();
            if (c.resepDihapus.contains(bid)) {
              h.baris.add(_BarisTopping(bid, br['nama'] as String, 'HAPUS', 0, q, 0, 0));
              continue;
            }
            perPorsi[bid] = (perPorsi[bid] ?? 0) + q;
            hpp += q * (br['hpp_per_dasar'] as num).toDouble();
          }
        }

        for (final t in c.topping.where((t) => t.pick > 0)) {
          final bid = t.bahan.id!;
          final br = await bahanRow(bid);
          final nama = br['nama'] as String;
          if ((br['aktif'] as int) != 1 || (br['bisa_prasmanan'] as int) != 1) {
            throw PosException('"$nama" tidak tersedia untuk prasmanan');
          }
          final hargaPick = (br['harga_prasmanan'] as num).toInt();
          if (hargaPick <= 0) throw PosException('Harga prasmanan "$nama" belum diatur');
          final qty = (br['qty_prasmanan'] as num).toDouble() * t.pick;
          final hppT = qty * (br['hpp_per_dasar'] as num).toDouble();
          perPorsi[bid] = (perPorsi[bid] ?? 0) + qty;
          harga += hargaPick * t.pick;
          hpp += hppT;
          h.baris.add(_BarisTopping(
              bid, nama, c.prasmanan ? 'PRASMANAN' : 'TAMBAH', t.pick, qty, hargaPick * t.pick, hppT));
        }

        h.harga = harga;
        h.hpp = hpp;
        hitung.add(h);
        perPorsi.forEach((bid, q) {
          kebutuhanTotal[bid] = (kebutuhanTotal[bid] ?? 0) + q * c.qty;
        });
      }

      final kurang = <String>[];
      for (final e in kebutuhanTotal.entries) {
        final br = await bahanRow(e.key);
        final stok = (br['stok'] as num).toDouble();
        if (stok + _eps < e.value) {
          kurang.add('• ${br['nama']}: butuh ${fmtQty(e.value)}, sisa ${fmtQty(stok)} ${br['satuan_dasar']}');
        }
      }
      if (kurang.isNotEmpty) throw StokTidakCukupException(kurang);

      final now = DateTime.now();
      String dua(int n) => n.toString().padLeft(2, '0');
      final tgl = '${now.year}${dua(now.month)}${dua(now.day)}';
      final urut = (Sqflite.firstIntValue(await tx
                  .rawQuery('SELECT COUNT(*) FROM transaksi WHERE no_nota LIKE ?', ['KS$tgl-%'])) ??
              0) +
          1;
      final noNota = 'KS$tgl-${urut.toString().padLeft(3, '0')}';

      var total = 0;
      var totalHpp = 0.0;
      for (final h in hitung) {
        total += h.harga * h.item.qty;
        totalHpp += h.hpp * h.item.qty;
      }

      final trxId = await tx.insert('transaksi', {
        'no_nota': noNota,
        'metode_bayar': metodeBayar,
        'total': total,
        'total_hpp': totalHpp,
        'status': 'SELESAI',
      });

      for (final h in hitung) {
        final c = h.item;
        final itemId = await tx.insert('transaksi_item', {
          'transaksi_id': trxId,
          'menu_id': c.menu?.id,
          'tipe': c.prasmanan ? 'PRASMANAN' : 'MENU',
          'nama_item': c.prasmanan ? c.namaItem : h.nama,
          'qty': c.qty,
          'harga_jual': h.harga,
          'hpp_snapshot': h.hpp,
          'level_pedas': c.levelLabel,
          'kuah': c.kuah,
          'rasa': c.rasa,
          'catatan': c.catatan.trim().isEmpty ? null : c.catatan.trim(),
        });
        for (final b in h.baris) {
          await tx.insert('transaksi_item_topping', {
            'item_id': itemId,
            'bahan_id': b.bahanId,
            'nama': b.nama,
            'jenis': b.jenis,
            'jumlah_pick': b.pick,
            'qty_dasar': b.qtyDasar,
            'harga': b.harga,
            'hpp': b.hpp,
          });
        }
      }

      for (final e in kebutuhanTotal.entries) {
        await _mutasiStok(tx, e.key, -e.value, 'JUAL', refId: trxId, catatan: noNota);
      }

      return HasilTransaksi(trxId, noNota, total, totalHpp);
    });
  }

  Future<void> voidTransaksi(int id) async {
    final database = await _db;
    await database.transaction((tx) async {
      final t = await tx.query('transaksi', where: 'id = ?', whereArgs: [id]);
      if (t.isEmpty) throw PosException('Transaksi tidak ditemukan');
      if (t.first['status'] == 'VOID') throw PosException('Transaksi sudah di-void');
      final potong = await tx.rawQuery(
          "SELECT bahan_id, SUM(qty) AS q FROM stok_mutasi WHERE tipe = 'JUAL' AND ref_id = ? GROUP BY bahan_id",
          [id]);
      await tx.update('transaksi', {'status': 'VOID'}, where: 'id = ?', whereArgs: [id]);
      for (final r in potong) {
        await _mutasiStok(tx, r['bahan_id'] as int, -(r['q'] as num).toDouble(), 'VOID',
            refId: id, catatan: t.first['no_nota'] as String);
      }
    });
  }

  Future<List<RingkasTransaksi>> riwayatTransaksi({String? tanggal, int limit = 100}) async {
    final database = await _db;
    final r = await database.query('transaksi',
        where: tanggal == null ? null : 'date(waktu) = ?',
        whereArgs: tanggal == null ? null : [tanggal],
        orderBy: 'id DESC',
        limit: limit);
    return r
        .map((e) => RingkasTransaksi(e['id'] as int, e['no_nota'] as String, e['waktu'] as String,
            e['metode_bayar'] as String, (e['total'] as num).toInt(), e['status'] as String))
        .toList();
  }

  Future<Struk> ambilStruk(int id) async {
    final database = await _db;
    final t = await database.query('transaksi', where: 'id = ?', whereArgs: [id]);
    if (t.isEmpty) throw PosException('Transaksi tidak ditemukan');
    final items = await database.query('transaksi_item', where: 'transaksi_id = ?', whereArgs: [id], orderBy: 'id');
    final out = <StrukItem>[];
    for (final it in items) {
      final tops = await database.query('transaksi_item_topping',
          where: 'item_id = ?', whereArgs: [it['id']], orderBy: 'id');
      out.add(StrukItem(
        tipe: it['tipe'] as String,
        nama: (it['nama_item'] as String).isEmpty ? 'Menu' : it['nama_item'] as String,
        qty: it['qty'] as int,
        hargaSatuan: (it['harga_jual'] as num).toInt(),
        levelPedas: it['level_pedas'] as String?,
        kuah: it['kuah'] as String?,
        rasa: it['rasa'] as String?,
        catatan: it['catatan'] as String?,
        topping: tops
            .map((x) => StrukTopping(x['nama'] as String, x['jenis'] as String,
                x['jumlah_pick'] as int, (x['harga'] as num).toInt()))
            .toList(),
      ));
    }
    final h = t.first;
    return Struk(
      id: id,
      noNota: h['no_nota'] as String,
      waktu: h['waktu'] as String,
      metode: h['metode_bayar'] as String,
      total: (h['total'] as num).toInt(),
      status: h['status'] as String,
      items: out,
    );
  }

  // =============================================================== AUDIT

  Future<List<SelisihStok>> auditStok() async {
    final database = await _db;
    final r = await database.rawQuery('''
      SELECT b.id, b.nama, b.satuan_dasar, b.stok, COALESCE(SUM(m.qty), 0) AS ledger
      FROM bahan b LEFT JOIN stok_mutasi m ON m.bahan_id = b.id
      GROUP BY b.id ORDER BY b.nama COLLATE NOCASE''');
    return r
        .map((e) => SelisihStok(e['id'] as int, e['nama'] as String, e['satuan_dasar'] as String,
            (e['stok'] as num).toDouble(), (e['ledger'] as num).toDouble()))
        .where((s) => s.selisih.abs() > 1e-6)
        .toList();
  }

  Future<void> sinkronkanLedger(int bahanId) async {
    final database = await _db;
    await database.transaction((tx) async {
      final r = await tx.rawQuery('''
        SELECT b.stok, COALESCE(SUM(m.qty), 0) AS ledger
        FROM bahan b LEFT JOIN stok_mutasi m ON m.bahan_id = b.id WHERE b.id = ? GROUP BY b.id''',
          [bahanId]);
      if (r.isEmpty) return;
      final selisih = (r.first['stok'] as num).toDouble() - (r.first['ledger'] as num).toDouble();
      if (selisih.abs() < 1e-9) return;
      await tx.insert('stok_mutasi', {
        'bahan_id': bahanId,
        'tipe': 'KOREKSI',
        'qty': selisih,
        'catatan': 'Sinkron buku besar',
      });
    });
  }

  Future<KeuanganHarian> cekKeuanganHarian(String tanggal) async {
    final database = await _db;
    final h = await database.rawQuery(
        "SELECT COALESCE(SUM(total),0) AS o, COALESCE(SUM(total_hpp),0) AS h FROM transaksi WHERE status='SELESAI' AND date(waktu)=?",
        [tanggal]);
    final i = await database.rawQuery('''
      SELECT COALESCE(SUM(ti.qty*ti.harga_jual),0) AS o, COALESCE(SUM(ti.qty*ti.hpp_snapshot),0) AS h
      FROM transaksi_item ti JOIN transaksi t ON t.id = ti.transaksi_id
      WHERE t.status='SELESAI' AND date(t.waktu)=?''', [tanggal]);
    return KeuanganHarian(
      tanggal,
      (h.first['o'] as num).toInt(),
      (i.first['o'] as num).toInt(),
      (h.first['h'] as num).toDouble(),
      (i.first['h'] as num).toDouble(),
    );
  }

  // =============================================================== MENU & RESEP (admin)

  Future<List<Map<String, Object?>>> daftarMenuLengkap() async {
    final database = await _db;
    return database.rawQuery('''
      SELECT m.id, m.nama, m.harga_jual, m.aktif, h.hpp_bahan
      FROM menu m JOIN v_hpp_menu h ON h.menu_id = m.id
      ORDER BY m.aktif DESC, m.nama COLLATE NOCASE''');
  }

  Future<Map<String, Object?>?> menuById(int id) async {
    final database = await _db;
    final r = await database.query('menu', where: 'id = ?', whereArgs: [id]);
    return r.isEmpty ? null : r.first;
  }

  Future<void> _cekNamaMenu(DatabaseExecutor tx, String nama, int? selfId) async {
    if (nama.trim().isEmpty) throw PosException('Nama menu wajib diisi');
    final d = await tx.query('menu',
        where: 'nama = ? COLLATE NOCASE AND id != ?', whereArgs: [nama.trim(), selfId ?? -1], limit: 1);
    if (d.isNotEmpty) throw PosException('Menu "${nama.trim()}" sudah ada');
  }

  Future<int> tambahMenu(String nama, int harga) async {
    final database = await _db;
    return database.transaction((tx) async {
      await _cekNamaMenu(tx, nama, null);
      return tx.insert('menu', {'nama': nama.trim(), 'kategori': 'Seblak', 'harga_jual': harga});
    });
  }

  Future<int> duplikatMenu(int sumberId, String nama, int harga) async {
    final database = await _db;
    return database.transaction((tx) async {
      await _cekNamaMenu(tx, nama, null);
      final id = await tx.insert('menu', {'nama': nama.trim(), 'kategori': 'Seblak', 'harga_jual': harga});
      await tx.rawInsert(
          'INSERT INTO resep_item (menu_id, bahan_id, qty_num, qty_den) '
          'SELECT ?, bahan_id, qty_num, qty_den FROM resep_item WHERE menu_id = ?',
          [id, sumberId]);
      return id;
    });
  }

  Future<void> updateMenu(int id, {String? nama, int? harga, bool? aktif}) async {
    final database = await _db;
    await database.transaction((tx) async {
      if (nama != null) await _cekNamaMenu(tx, nama, id);
      await tx.update(
          'menu',
          {
            if (nama != null) 'nama': nama.trim(),
            if (harga != null) 'harga_jual': harga,
            if (aktif != null) 'aktif': aktif ? 1 : 0,
          },
          where: 'id = ?',
          whereArgs: [id]);
    });
  }

  Future<List<Map<String, Object?>>> resepDetail(int menuId) async {
    final database = await _db;
    return database.rawQuery('''
      SELECT r.bahan_id, b.nama, b.satuan_dasar, r.qty_num, r.qty_den,
             r.qty_dec * b.hpp_per_dasar AS biaya
      FROM resep_item r JOIN bahan b ON b.id = r.bahan_id
      WHERE r.menu_id = ? ORDER BY b.nama COLLATE NOCASE''', [menuId]);
  }

  /// Takaran pecahan: "1/3", "0.5", "2". Tambah baru atau perbarui.
  Future<void> setResepItem(int menuId, int bahanId, String takaran) async {
    final t = Takaran.tryParse(takaran);
    if (t == null || t.nilai <= 0) throw PosException('Takaran tidak valid (contoh: 1/3, 0.5, 2)');
    final database = await _db;
    await database.transaction((tx) async {
      final ada = await tx.query('resep_item',
          columns: ['id'], where: 'menu_id = ? AND bahan_id = ?', whereArgs: [menuId, bahanId]);
      if (ada.isEmpty) {
        await tx.insert('resep_item',
            {'menu_id': menuId, 'bahan_id': bahanId, 'qty_num': t.pembilang, 'qty_den': t.penyebut});
      } else {
        await tx.update(
            'resep_item', {'qty_num': t.pembilang, 'qty_den': t.penyebut, 'qty_dec': t.nilai},
            where: 'id = ?', whereArgs: [ada.first['id']]);
      }
    });
  }

  Future<void> hapusResepItem(int menuId, int bahanId) async {
    final database = await _db;
    await database.delete('resep_item',
        where: 'menu_id = ? AND bahan_id = ?', whereArgs: [menuId, bahanId]);
  }

  Future<double> overheadPerPorsi() async {
    final database = await _db;
    final r = await database.query('v_overhead_per_porsi');
    return r.isEmpty ? 0 : ((r.first['per_porsi'] as num?)?.toDouble() ?? 0);
  }

  // =============================================================== HPP & OVERHEAD

  Future<List<Map<String, Object?>>> daftarOverhead() async {
    final database = await _db;
    return database.query('overhead', orderBy: 'aktif DESC, nama COLLATE NOCASE');
  }

  Future<void> simpanOverhead({
    int? id,
    required String nama,
    required int nominal,
    required String periode,
    bool aktif = true,
  }) async {
    if (nama.trim().isEmpty) throw PosException('Nama biaya wajib diisi');
    if (nominal < 0) throw PosException('Nominal tidak valid');
    if (periode != 'HARIAN' && periode != 'MINGGUAN' && periode != 'BULANAN') {
      throw PosException('Periode tidak valid');
    }
    final database = await _db;
    final data = {'nama': nama.trim(), 'nominal': nominal, 'periode': periode, 'aktif': aktif ? 1 : 0};
    if (id == null) {
      await database.insert('overhead', data);
    } else {
      await database.update('overhead', data, where: 'id = ?', whereArgs: [id]);
    }
  }

  Future<void> hapusOverhead(int id) async {
    final database = await _db;
    await database.delete('overhead', where: 'id = ?', whereArgs: [id]);
  }

  Future<int> estimasiPorsiBulanan() async =>
      int.tryParse(await getPengaturan('estimasi_porsi_bulanan') ?? '') ?? 1500;

  /// Pembagi overhead per porsi. Harus > 0 (jika 0 hasil view menjadi kosong).
  Future<void> setEstimasiPorsiBulanan(int v) async {
    if (v <= 0) throw PosException('Estimasi porsi harus lebih dari 0');
    await setPengaturan('estimasi_porsi_bulanan', '$v');
  }

  /// Porsi terjual 30 hari terakhir (dasar untuk estimasi yang realistis).
  Future<int> porsiTerjual30Hari() async {
    final database = await _db;
    final r = await database.rawQuery('''
      SELECT COALESCE(SUM(ti.qty), 0) AS q
      FROM transaksi t JOIN transaksi_item ti ON ti.transaksi_id = t.id
      WHERE t.status = 'SELESAI' AND date(t.waktu) >= date('now','localtime','-30 day')''');
    return (r.first['q'] as num).toInt();
  }

  Future<double> targetMargin() async =>
      double.tryParse(await getPengaturan('target_margin') ?? '') ?? 40;

  Future<void> setTargetMargin(double v) async {
    if (v < 0 || v >= 95) throw PosException('Target margin harus antara 0 dan 94');
    await setPengaturan('target_margin', '$v');
  }

  // =============================================================== STOK MANUAL

  /// Set stok sesuai hitungan fisik; selisih dicatat sebagai OPNAME.
  Future<void> opname(int bahanId, double stokFisik, {String? catatan}) async {
    if (stokFisik < 0) throw PosException('Stok fisik tidak boleh negatif');
    final database = await _db;
    await database.transaction((tx) async {
      final r = await tx.query('bahan', columns: ['stok'], where: 'id = ?', whereArgs: [bahanId]);
      if (r.isEmpty) throw PosException('Bahan tidak ditemukan');
      final lama = (r.first['stok'] as num).toDouble();
      await _mutasiStok(tx, bahanId, stokFisik - lama, 'OPNAME', catatan: catatan);
    });
  }

  /// Bahan rusak/terbuang: stok berkurang, tercatat BUANG.
  Future<void> buangBahan(int bahanId, double qty, {String? catatan}) async {
    if (qty <= 0) throw PosException('Jumlah harus lebih dari 0');
    final database = await _db;
    await database.transaction((tx) async {
      final r = await tx.query('bahan', columns: ['stok'], where: 'id = ?', whereArgs: [bahanId]);
      if (r.isEmpty) throw PosException('Bahan tidak ditemukan');
      if ((r.first['stok'] as num).toDouble() + _eps < qty) {
        throw PosException('Jumlah melebihi stok yang ada');
      }
      await _mutasiStok(tx, bahanId, -qty, 'BUANG', catatan: catatan);
    });
  }

  // =============================================================== DASHBOARD

  Future<Map<String, Object?>> ringkasanHariIni() async {
    final database = await _db;
    final r = await database
        .rawQuery("SELECT * FROM v_rekap_harian WHERE tanggal = date('now','localtime')");
    return r.isEmpty
        ? {'jumlah_transaksi': 0, 'porsi_terjual': 0, 'omzet': 0, 'total_hpp': 0, 'laba_kotor': 0}
        : r.first;
  }

  Future<double> overheadHarian() async {
    final database = await _db;
    final r = await database.rawQuery('''
      SELECT COALESCE(SUM(CASE periode WHEN 'BULANAN' THEN nominal / 30.0 WHEN 'MINGGUAN' THEN nominal / 7.0 ELSE nominal END),0) AS v
      FROM overhead WHERE aktif = 1''');
    return (r.first['v'] as num).toDouble();
  }

  /// Menu tetap DAN seblak prasmanan (dikelompokkan per nama_item).
  Future<List<Map<String, Object?>>> menuTerlarisHariIni() async {
    final database = await _db;
    return database.rawQuery('''
      SELECT ti.nama_item AS nama, SUM(ti.qty) AS qty, SUM(ti.qty * ti.harga_jual) AS omzet
      FROM transaksi t JOIN transaksi_item ti ON ti.transaksi_id = t.id
      WHERE t.status = 'SELESAI' AND date(t.waktu) = date('now','localtime')
      GROUP BY ti.nama_item ORDER BY qty DESC LIMIT 5''');
  }

  Future<List<Map<String, Object?>>> sisaPorsi() async {
    final database = await _db;
    return database.query('v_sisa_porsi_menu', orderBy: 'nama');
  }

  Future<List<Map<String, Object?>>> stokRealtime() async {
    final database = await _db;
    return database.query('v_stok', orderBy: 'nama COLLATE NOCASE');
  }

  Future<List<Map<String, Object?>>> rekapHarian({int hari = 30}) async {
    final database = await _db;
    return database.query('v_rekap_harian', orderBy: 'tanggal DESC', limit: hari);
  }

  Future<List<Map<String, Object?>>> marginMenu() async {
    final database = await _db;
    return database.query('v_margin_menu', orderBy: 'margin_persen');
  }

}

class _BarisTopping {
  final int bahanId;
  final String nama;
  final String jenis;
  final int pick;
  final double qtyDasar;
  final int harga;
  final double hpp;
  _BarisTopping(this.bahanId, this.nama, this.jenis, this.pick, this.qtyDasar, this.harga, this.hpp);
}

class _Hitung {
  final CartItem item;
  String nama;
  int harga = 0;
  double hpp = 0;
  final List<_BarisTopping> baris = [];
  _Hitung(this.item) : nama = item.namaItem;
}
