// pos_repository.dart — satu-satunya pintu akses data.
// Aturan emas anti-selisih:
//  1) Setiap perubahan bahan.stok SELALU lewat _mutasiStok() (ikut tercatat di stok_mutasi).
//  2) Transaksi = satu db.transaction: validasi stok -> simpan nota -> potong stok.
//     Jika ada yang gagal, semuanya dibatalkan (rollback).
//  3) Harga, takaran, dan HPP dihitung ulang dari database saat checkout.
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'database_helper.dart';
import 'models.dart';
import 'variasi_models.dart';

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
      await _migrasiVariasi(d);
      await _migrasiKategori(d);
      return d;
    } catch (_) {
      _dbSiap = null; // coba lagi di pemanggilan berikutnya
      rethrow;
    }
  }

  /// Tabel master kategori menu (Seblak, Minuman, Es, Jajanan, dst).
  /// Kolom menu.kategori (teks) tetap menjadi penghubung, sehingga data lama,
  /// filter dashboard, dan backup lama tetap berfungsi. Idempotent.
  Future<void> _migrasiKategori(Database d) async {
    await d.transaction((tx) async {
      await tx.execute('''
        CREATE TABLE IF NOT EXISTS menu_kategori (
          id          INTEGER PRIMARY KEY AUTOINCREMENT,
          nama        TEXT NOT NULL UNIQUE COLLATE NOCASE,
          urutan      INTEGER NOT NULL DEFAULT 0,
          opsi_seblak INTEGER NOT NULL DEFAULT 0
        )''');
      final kolomMenu = await tx.rawQuery('PRAGMA table_info(menu)');
      if (!kolomMenu.any((c) => c['name'] == 'kategori_id')) {
        // Foreign key ke master kategori. Kategori dihapus -> menu jadi tanpa kategori.
        await tx.execute(
            'ALTER TABLE menu ADD COLUMN kategori_id INTEGER REFERENCES menu_kategori(id) ON DELETE SET NULL');
      }
      // Kategori teks yang belum ada di master (data lama / hasil restore backup lama)
      // dijadikan master. Perilaku lama dipertahankan (opsi seblak tetap tampil).
      await tx.execute('''
        INSERT OR IGNORE INTO menu_kategori (nama, urutan, opsi_seblak)
        SELECT TRIM(kategori), MIN(id), 1 FROM menu
        WHERE kategori_id IS NULL AND TRIM(COALESCE(kategori, '')) <> ''
        GROUP BY TRIM(kategori) COLLATE NOCASE''');
      await tx.execute('''
        UPDATE menu SET kategori_id = (
          SELECT k.id FROM menu_kategori k WHERE k.nama = TRIM(menu.kategori) COLLATE NOCASE)
        WHERE TRIM(COALESCE(kategori, '')) <> '' AND kategori_id IS NULL''');
      await tx.execute(
          'CREATE INDEX IF NOT EXISTS idx_menu_kategori_id ON menu(kategori_id)');
    });
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
    final r = await database.rawQuery('''
      SELECT m.id, m.nama, k.nama AS kategori, m.harga_jual,
             COALESCE(k.opsi_seblak, 1) AS opsi_seblak
      FROM menu m LEFT JOIN menu_kategori k ON k.id = m.kategori_id
      WHERE m.aktif = 1 ORDER BY m.nama COLLATE NOCASE''');
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

        // ---- VARIASI (grup/opsi): harga tambahan + bahan yang ikut terpotong ----
        if (c.prasmanan || c.menu == null) {
          if (c.variasi.isNotEmpty) {
            throw PosException('Variasi hanya berlaku untuk menu tetap');
          }
        } else {
          final grupRows = await tx.rawQuery('''
            SELECT g.id, g.nama, g.wajib, g.min_pilih, g.maks_pilih, g.tipe
            FROM variasi_grup g JOIN menu_variasi_grup mg ON mg.grup_id = g.id
            WHERE mg.menu_id = ? AND g.aktif = 1''', [c.menu!.id]);
          final grupById = {for (final g in grupRows) g['id'] as int: g};
          // Satu opsi boleh dipilih berkali-kali (stepper di kasir):
          // jumlah dihitung per kelompok (total) dan per opsi.
          final perGrup = <int, int>{};
          final jmlOpsi = <int, int>{};
          final contoh = <int, PilihanVariasi>{};
          final teksList = <PilihanVariasi>[]; // jawaban kelompok bertipe Teks (opsiId = 0)
          for (final pv in c.variasi) {
            final gr = grupById[pv.grupId];
            if (gr == null) {
              throw PosException('Variasi "${pv.grupNama}" tidak berlaku untuk ${h.nama}');
            }
            final tipeGrup = (gr['tipe'] as String?) ?? 'RADIO';
            if (pv.opsiId == 0) {
              if (tipeGrup != 'TEKS') throw PosException('"${pv.grupNama}" bukan isian teks');
              final t = pv.opsiNama.trim();
              if (t.isEmpty) continue;
              if (t.length > 100) throw PosException('Isian "${pv.grupNama}" maksimal 100 karakter');
              teksList.add(pv);
              perGrup[pv.grupId] = (perGrup[pv.grupId] ?? 0) + 1;
            } else {
              if (tipeGrup == 'TEKS') throw PosException('"${pv.grupNama}" hanya berupa isian teks');
              perGrup[pv.grupId] = (perGrup[pv.grupId] ?? 0) + 1;
              jmlOpsi[pv.opsiId] = (jmlOpsi[pv.opsiId] ?? 0) + 1;
              contoh.putIfAbsent(pv.opsiId, () => pv);
            }
          }
          for (final g in grupRows) {
            final gid = g['id'] as int;
            final jumlah = perGrup[gid] ?? 0;
            final maks = g['maks_pilih'] as int; // 0 = tanpa batas
            final minDb = (g['min_pilih'] as int?) ?? 0;
            final minimal = (g['wajib'] as int) == 1 ? (minDb < 1 ? 1 : minDb) : 0;
            if (jumlah < minimal) {
              throw PosException(minimal == 1
                  ? 'Pilih "${g['nama']}" untuk ${h.nama}'
                  : 'Pilih minimal $minimal "${g['nama']}" untuk ${h.nama}');
            }
            if (maks > 0 && jumlah > maks) {
              throw PosException('"${g['nama']}" maksimal $maks pilihan');
            }
          }
          // Harga & bahan SELALU dibaca dari database, bukan dari keranjang.
          for (final pv in contoh.values) {
            final n = jmlOpsi[pv.opsiId]!;
            final o = await tx.query('variasi_opsi',
                where: 'id = ? AND grup_id = ? AND aktif = 1', whereArgs: [pv.opsiId, pv.grupId]);
            if (o.isEmpty) throw PosException('Opsi "${pv.opsiNama}" tidak tersedia lagi');
            final tambah = (o.first['harga_tambah'] as num).toInt();
            final namaGrup = grupById[pv.grupId]!['nama'] as String;
            final namaOpsi = o.first['nama'] as String;
            var hppOpsi = 0.0;
            final bahanOpsi = await tx.rawQuery(
                'SELECT bahan_id, qty_dasar FROM variasi_opsi_bahan WHERE opsi_id = ?', [pv.opsiId]);
            for (final ob in bahanOpsi) {
              final bid = ob['bahan_id'] as int;
              final br = await bahanRow(bid);
              final q = (ob['qty_dasar'] as num).toDouble();
              perPorsi[bid] = (perPorsi[bid] ?? 0) + q * n;
              hppOpsi += q * (br['hpp_per_dasar'] as num).toDouble();
            }
            harga += tambah * n;
            hpp += hppOpsi * n;
            // harga & hpp disimpan TOTAL untuk n item (sama seperti topping); jumlah = n.
            h.variasi.add(_BarisVariasi(
                pv.grupId, pv.opsiId, namaGrup, namaOpsi, tambah * n, hppOpsi * n, n));
          }
          // Jawaban teks: tanpa harga & tanpa efek stok.
          for (final pv in teksList) {
            h.variasi.add(_BarisVariasi(
                pv.grupId, 0, grupById[pv.grupId]!['nama'] as String, pv.opsiNama.trim(), 0, 0.0, 1));
          }
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
          'level_pedas': c.tampilkanLegacy ? c.levelLabel : null,
          'kuah': c.tampilkanLegacy ? c.kuah : null,
          'rasa': c.tampilkanLegacy ? c.rasa : null,
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
        for (final v in h.variasi) {
          await tx.insert('transaksi_item_variasi', {
            'item_id': itemId,
            'grup_id': v.grupId,
            'opsi_id': v.opsiId == 0 ? null : v.opsiId, // null = jawaban teks
            'grup_nama': v.grupNama,
            'opsi_nama': v.opsiNama,
            'jumlah': v.jumlah,
            'harga': v.harga,
            'hpp': v.hpp,
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
      final vars = await database.query('transaksi_item_variasi',
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
        topping: [
          ...tops.map((x) => StrukTopping(x['nama'] as String, x['jenis'] as String,
              x['jumlah_pick'] as int, (x['harga'] as num).toInt())),
          // Variasi tampil sebagai baris tambahan: "Level Pedas: Level 3"
          ...vars.map((x) => StrukTopping('${x['grup_nama']}: ${x['opsi_nama']}', 'VARIASI',
              (x['jumlah'] as int?) ?? 1, (x['harga'] as num).toInt())),
        ],
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
      SELECT m.id, m.nama, k.nama AS kategori, m.kategori_id, m.harga_jual, m.aktif, h.hpp_bahan
      FROM menu m JOIN v_hpp_menu h ON h.menu_id = m.id
      LEFT JOIN menu_kategori k ON k.id = m.kategori_id
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

  Future<int> tambahMenu(String nama, int harga, {String? kategori}) async {
    final database = await _db;
    return database.transaction((tx) async {
      await _cekNamaMenu(tx, nama, null);
      final k = await _kategoriKanonis(tx, kategori);
      return tx.insert('menu', {
        'nama': nama.trim(),
        'kategori': k.nama,
        'kategori_id': k.id,
        'harga_jual': harga,
      });
    });
  }

  Future<int> duplikatMenu(int sumberId, String nama, int harga, {String? kategori}) async {
    final database = await _db;
    return database.transaction((tx) async {
      await _cekNamaMenu(tx, nama, null);
      final k = await _kategoriKanonis(tx, kategori);
      final id = await tx.insert('menu', {
        'nama': nama.trim(),
        'kategori': k.nama,
        'kategori_id': k.id,
        'harga_jual': harga,
      });
      await tx.rawInsert(
          'INSERT INTO resep_item (menu_id, bahan_id, qty_num, qty_den) '
          'SELECT ?, bahan_id, qty_num, qty_den FROM resep_item WHERE menu_id = ?',
          [id, sumberId]);
      await tx.rawInsert(
          'INSERT OR IGNORE INTO menu_variasi_grup (menu_id, grup_id, urutan) '
          'SELECT ?, grup_id, urutan FROM menu_variasi_grup WHERE menu_id = ?',
          [id, sumberId]);
      return id;
    });
  }

  /// Hapus permanen. Resep & pemasangan variasi ikut terhapus. Riwayat penjualan TETAP utuh
  /// (nota menyimpan nama & harga sendiri); hanya kaitan ke menu yang dilepas.
  /// Mengembalikan jumlah baris penjualan yang pernah memakai menu ini.
  /// Untuk sekadar menyembunyikan dari kasir, pakai updateMenu(aktif: false).
  Future<int> hapusMenu(int id) async {
    final database = await _db;
    return database.transaction((tx) async {
      final ada = await tx.query('menu', columns: ['id'], where: 'id = ?', whereArgs: [id]);
      if (ada.isEmpty) throw PosException('Menu tidak ditemukan');
      final terjual =
          await tx.rawUpdate('UPDATE transaksi_item SET menu_id = NULL WHERE menu_id = ?', [id]);
      await tx.delete('resep_item', where: 'menu_id = ?', whereArgs: [id]);
      await tx.delete('menu_variasi_grup', where: 'menu_id = ?', whereArgs: [id]);
      await tx.delete('menu', where: 'id = ?', whereArgs: [id]);
      return terjual;
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
      SELECT COALESCE(SUM(CASE periode WHEN 'BULANAN' THEN nominal / 30.0 WHEN 'MINGGUAN' THEN nominal * 52.0 / 12 / 30 ELSE nominal END),0) AS v
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


  // ---------- CADANGAN DATA (EKSPOR / IMPOR) ----------

  /// Membuat salinan database yang konsisten di folder cache, lalu
  /// mengembalikan path-nya (siap dibagikan ke Drive/WhatsApp/Files).
  Future<String> eksporDatabase() async {
    final d = await _db;
    final tmp = await getTemporaryDirectory();
    final t = DateTime.now();
    String dua(int x) => x.toString().padLeft(2, '0');
    final nama =
        'pawon_cadangan_${t.year}${dua(t.month)}${dua(t.day)}_${dua(t.hour)}${dua(t.minute)}.db';
    final tujuan = '${tmp.path}/$nama';
    final f = File(tujuan);
    if (await f.exists()) await f.delete();
    try {
      await d.execute("VACUUM INTO '${tujuan.replaceAll("'", "''")}'");
    } catch (_) {
      // Android lama tanpa VACUUM INTO: salin file setelah checkpoint.
      try {
        await d.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
      } catch (_) {}
      await File(d.path).copy(tujuan);
    }
    return tujuan;
  }

  /// Mengganti seluruh data aplikasi dengan berkas cadangan.
  /// Setelah selesai, aplikasi HARUS ditutup lalu dibuka lagi.
  Future<void> imporDatabase(String sumber) async {
    final berkas = File(sumber);
    if (!await berkas.exists()) {
      throw PosException('Berkas cadangan tidak ditemukan');
    }

    // 1) Validasi: harus database SQLite yang berisi tabel inti kedai.
    Database? cek;
    try {
      cek = await openDatabase(sumber, readOnly: true);
      final r = await cek.rawQuery("SELECT name FROM sqlite_master WHERE type='table'");
      final ada = r.map((e) => '${e['name']}').toSet();
      for (final wajib in ['bahan', 'menu', 'transaksi', 'pengaturan']) {
        if (!ada.contains(wajib)) {
          throw PosException('Bukan cadangan data kedai (tabel $wajib tidak ada)');
        }
      }
    } on PosException {
      rethrow;
    } catch (_) {
      throw PosException('Berkas bukan database yang valid');
    } finally {
      await cek?.close();
    }

    // 2) Tutup koneksi lama, simpan salinan darurat, lalu timpa.
    final d = await _db;
    final path = d.path;
    await d.close();
    _dbSiap = null;
    DatabaseHelper.instance.lepas();
    for (final akhiran in ['-wal', '-shm', '-journal']) {
      final x = File('$path$akhiran');
      if (await x.exists()) await x.delete();
    }
    final lama = File(path);
    if (await lama.exists()) await lama.copy('$path.sebelum_impor');
    await berkas.copy(path);
  }


  // =============================================================== VARIASI MENU
  // Model: variasi_grup (kelompok) -> variasi_opsi (pilihan, harga tambah)
  //        variasi_opsi_bahan (efek stok per pilihan)
  //        menu_variasi_grup (kelompok mana berlaku di menu mana)
  //        transaksi_item_variasi (snapshot pilihan di nota; histori tetap utuh)
  // Semua perintah CREATE ... IF NOT EXISTS: aman dijalankan berulang,
  // tidak menyentuh data transaksi yang sudah ada.

  Future<void> _migrasiVariasi(Database d) async {
    await d.transaction((tx) async {
      await tx.execute('''
        CREATE TABLE IF NOT EXISTS variasi_grup (
          id        INTEGER PRIMARY KEY AUTOINCREMENT,
          nama      TEXT NOT NULL,
          wajib     INTEGER NOT NULL DEFAULT 0,
          maks_pilih INTEGER NOT NULL DEFAULT 1,
          urutan    INTEGER NOT NULL DEFAULT 0,
          aktif     INTEGER NOT NULL DEFAULT 1
        )''');
      await tx.execute('''
        CREATE TABLE IF NOT EXISTS variasi_opsi (
          id          INTEGER PRIMARY KEY AUTOINCREMENT,
          grup_id     INTEGER NOT NULL REFERENCES variasi_grup(id) ON DELETE CASCADE,
          nama        TEXT NOT NULL,
          harga_tambah INTEGER NOT NULL DEFAULT 0,
          urutan      INTEGER NOT NULL DEFAULT 0,
          aktif       INTEGER NOT NULL DEFAULT 1
        )''');
      await tx.execute('''
        CREATE TABLE IF NOT EXISTS variasi_opsi_bahan (
          id        INTEGER PRIMARY KEY AUTOINCREMENT,
          opsi_id   INTEGER NOT NULL REFERENCES variasi_opsi(id) ON DELETE CASCADE,
          bahan_id  INTEGER NOT NULL REFERENCES bahan(id),
          qty_dasar REAL NOT NULL CHECK (qty_dasar > 0),
          UNIQUE (opsi_id, bahan_id)
        )''');
      await tx.execute('''
        CREATE TABLE IF NOT EXISTS menu_variasi_grup (
          menu_id  INTEGER NOT NULL REFERENCES menu(id) ON DELETE CASCADE,
          grup_id  INTEGER NOT NULL REFERENCES variasi_grup(id) ON DELETE CASCADE,
          urutan   INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (menu_id, grup_id)
        )''');
      await tx.execute('''
        CREATE TABLE IF NOT EXISTS transaksi_item_variasi (
          id        INTEGER PRIMARY KEY AUTOINCREMENT,
          item_id   INTEGER NOT NULL REFERENCES transaksi_item(id) ON DELETE CASCADE,
          grup_id   INTEGER,
          opsi_id   INTEGER,
          grup_nama TEXT NOT NULL,
          opsi_nama TEXT NOT NULL,
          jumlah    INTEGER NOT NULL DEFAULT 1,
          harga     INTEGER NOT NULL DEFAULT 0,
          hpp       REAL NOT NULL DEFAULT 0
        )''');
      // DB lama: tambah kolom jumlah (baris lama otomatis bernilai 1; data tidak berubah).
      final kolomTiv = await tx.rawQuery('PRAGMA table_info(transaksi_item_variasi)');
      if (!kolomTiv.any((c) => c['name'] == 'jumlah')) {
        await tx.execute('ALTER TABLE transaksi_item_variasi ADD COLUMN jumlah INTEGER NOT NULL DEFAULT 1');
      }
      // Aturan pilihan: wajib (is_required), min_pilih (min_select), maks_pilih (max_select).
      final kolomGrup = await tx.rawQuery('PRAGMA table_info(variasi_grup)');
      if (!kolomGrup.any((c) => c['name'] == 'min_pilih')) {
        await tx.execute('ALTER TABLE variasi_grup ADD COLUMN min_pilih INTEGER NOT NULL DEFAULT 0');
      }
      await tx.execute('UPDATE variasi_grup SET min_pilih = 1 WHERE wajib = 1 AND min_pilih < 1');
      // Tipe kelompok: RADIO | TEKS | BANYAK. Kelompok lama: maks 1 -> RADIO, selain itu -> BANYAK.
      if (!kolomGrup.any((c) => c['name'] == 'tipe')) {
        await tx.execute("ALTER TABLE variasi_grup ADD COLUMN tipe TEXT NOT NULL DEFAULT 'RADIO'");
        await tx.execute("UPDATE variasi_grup SET tipe = 'BANYAK' WHERE maks_pilih <> 1");
      }
      await tx.execute(
          'CREATE INDEX IF NOT EXISTS idx_variasi_opsi_grup ON variasi_opsi(grup_id)');
      await tx.execute(
          'CREATE INDEX IF NOT EXISTS idx_menu_variasi_grup ON menu_variasi_grup(grup_id)');
      await tx.execute(
          'CREATE INDEX IF NOT EXISTS idx_tiv_item ON transaksi_item_variasi(item_id)');
    });
  }

  Future<List<VariasiGrup>> _muatGrup(DatabaseExecutor d,
      {int? menuId, bool hanyaAktif = false}) async {
    final grupRows = menuId == null
        ? await d.query('variasi_grup',
            where: hanyaAktif ? 'aktif = 1' : null, orderBy: 'urutan, nama COLLATE NOCASE')
        : await d.rawQuery('''
            SELECT g.* FROM variasi_grup g
            JOIN menu_variasi_grup mg ON mg.grup_id = g.id
            WHERE mg.menu_id = ? ${hanyaAktif ? 'AND g.aktif = 1' : ''}
            ORDER BY mg.urutan, g.id''', [menuId]);
    final out = <VariasiGrup>[];
    for (final g in grupRows) {
      final gid = g['id'] as int;
      final opsiRows = await d.query('variasi_opsi',
          where: hanyaAktif ? 'grup_id = ? AND aktif = 1' : 'grup_id = ?',
          whereArgs: [gid],
          orderBy: 'urutan, id');
      final opsi = <VariasiOpsi>[];
      for (final o in opsiRows) {
        final oid = o['id'] as int;
        final bRows = await d.rawQuery('''
          SELECT ob.bahan_id, ob.qty_dasar, b.nama, b.satuan_dasar
          FROM variasi_opsi_bahan ob JOIN bahan b ON b.id = ob.bahan_id
          WHERE ob.opsi_id = ? ORDER BY b.nama COLLATE NOCASE''', [oid]);
        opsi.add(VariasiOpsi(
          id: oid,
          grupId: gid,
          nama: o['nama'] as String,
          hargaTambah: (o['harga_tambah'] as num).toInt(),
          aktif: (o['aktif'] as int) == 1,
          bahan: bRows
              .map((b) => VariasiBahan(
                    bahanId: b['bahan_id'] as int,
                    nama: b['nama'] as String,
                    satuan: b['satuan_dasar'] as String,
                    qtyDasar: (b['qty_dasar'] as num).toDouble(),
                  ))
              .toList(),
        ));
      }
      final menuRows = await d.query('menu_variasi_grup',
          columns: ['menu_id'], where: 'grup_id = ?', whereArgs: [gid]);
      out.add(VariasiGrup(
        id: gid,
        nama: g['nama'] as String,
        wajib: (g['wajib'] as int) == 1,
        minPilih: (g['min_pilih'] as int?) ?? 0,
        maksPilih: g['maks_pilih'] as int,
        aktif: (g['aktif'] as int) == 1,
        opsi: opsi,
        menuIds: menuRows.map((m) => m['menu_id'] as int).toList(),
        tipe: (g['tipe'] as String?) ?? ((g['maks_pilih'] as int) == 1 ? 'RADIO' : 'BANYAK'),
      ));
    }
    return out;
  }

  /// Semua kelompok variasi (termasuk nonaktif) untuk halaman manajemen.
  Future<List<VariasiGrup>> daftarGrupVariasi() async => _muatGrup(await _db);

  /// Kelompok + opsi AKTIF yang berlaku untuk satu menu (dipakai kasir).
  Future<List<VariasiGrup>> grupUntukMenu(int menuId) async =>
      _muatGrup(await _db, menuId: menuId, hanyaAktif: true);

  Future<int> simpanGrupVariasi({
    int? id,
    required String nama,
    bool wajib = false,
    int minPilih = 0, // hanya berlaku bila wajib; wajib => minimal 1
    int maksPilih = 1, // tipe BANYAK: batas total (0 = tanpa batas); tipe lain selalu 1
    bool aktif = true,
    String tipe = 'RADIO', // RADIO | TEKS | BANYAK
  }) async {
    final n = nama.trim();
    if (n.isEmpty) throw PosException('Nama kelompok variasi wajib diisi');
    if (tipe != 'RADIO' && tipe != 'TEKS' && tipe != 'BANYAK') {
      throw PosException('Tipe variasi tidak valid');
    }
    if (tipe != 'BANYAK') maksPilih = 1;
    if (maksPilih < 0) throw PosException('Batas pilihan tidak valid');
    var minimal = wajib ? (minPilih < 1 ? 1 : minPilih) : 0;
    if (maksPilih == 1 && minimal > 1) minimal = 1;
    if (maksPilih > 1 && minimal > maksPilih) {
      throw PosException('Minimal pilihan ($minimal) tidak boleh lebih besar dari maksimal ($maksPilih)');
    }
    final d = await _db;
    final dup = await d.query('variasi_grup',
        where: 'nama = ? COLLATE NOCASE AND id != ?', whereArgs: [n, id ?? -1]);
    if (dup.isNotEmpty) throw PosException('Kelompok "$n" sudah ada');
    final data = {
      'nama': n,
      'wajib': wajib ? 1 : 0,
      'min_pilih': minimal,
      'maks_pilih': maksPilih,
      'aktif': aktif ? 1 : 0,
      'tipe': tipe,
    };
    if (id == null) return d.insert('variasi_grup', data);
    await d.update('variasi_grup', data, where: 'id = ?', whereArgs: [id]);
    return id;
  }

  /// Histori nota tidak terpengaruh: nota menyimpan salinan nama & harga variasi.
  Future<void> hapusGrupVariasi(int id) async {
    final d = await _db;
    await d.transaction((tx) async {
      await tx.rawDelete(
          'DELETE FROM variasi_opsi_bahan WHERE opsi_id IN (SELECT id FROM variasi_opsi WHERE grup_id = ?)',
          [id]);
      await tx.delete('variasi_opsi', where: 'grup_id = ?', whereArgs: [id]);
      await tx.delete('menu_variasi_grup', where: 'grup_id = ?', whereArgs: [id]);
      await tx.delete('variasi_grup', where: 'id = ?', whereArgs: [id]);
    });
  }

  Future<int> simpanOpsiVariasi({
    int? id,
    required int grupId,
    required String nama,
    int hargaTambah = 0,
    bool aktif = true,
    List<VariasiBahan> bahan = const [],
  }) async {
    final n = nama.trim();
    if (n.isEmpty) throw PosException('Nama opsi wajib diisi');
    if (hargaTambah < 0) throw PosException('Harga tambahan tidak boleh minus');
    final qtyPerBahan = <int, double>{};
    for (final b in bahan) {
      if (b.qtyDasar <= 0) throw PosException('Jumlah bahan harus lebih dari 0');
      qtyPerBahan[b.bahanId] = (qtyPerBahan[b.bahanId] ?? 0) + b.qtyDasar;
    }
    final d = await _db;
    return d.transaction((tx) async {
      final dup = await tx.query('variasi_opsi',
          where: 'grup_id = ? AND nama = ? COLLATE NOCASE AND id != ?',
          whereArgs: [grupId, n, id ?? -1]);
      if (dup.isNotEmpty) throw PosException('Opsi "$n" sudah ada di kelompok ini');
      final data = {
        'grup_id': grupId,
        'nama': n,
        'harga_tambah': hargaTambah,
        'aktif': aktif ? 1 : 0,
      };
      late final int opsiId;
      if (id == null) {
        opsiId = await tx.insert('variasi_opsi', data);
      } else {
        opsiId = id;
        await tx.update('variasi_opsi', data, where: 'id = ?', whereArgs: [id]);
      }
      await tx.delete('variasi_opsi_bahan', where: 'opsi_id = ?', whereArgs: [opsiId]);
      for (final e in qtyPerBahan.entries) {
        await tx.insert('variasi_opsi_bahan',
            {'opsi_id': opsiId, 'bahan_id': e.key, 'qty_dasar': e.value});
      }
      return opsiId;
    });
  }

  Future<void> hapusOpsiVariasi(int id) async {
    final d = await _db;
    await d.transaction((tx) async {
      await tx.delete('variasi_opsi_bahan', where: 'opsi_id = ?', whereArgs: [id]);
      await tx.delete('variasi_opsi', where: 'id = ?', whereArgs: [id]);
    });
  }

  /// Menentukan kelompok ini berlaku di menu mana saja (mengganti seluruh relasi).
  Future<void> setMenuUntukGrup(int grupId, List<int> menuIds) async {
    final d = await _db;
    await d.transaction((tx) async {
      await tx.delete('menu_variasi_grup', where: 'grup_id = ?', whereArgs: [grupId]);
      for (final m in menuIds.toSet()) {
        await tx.insert('menu_variasi_grup', {'menu_id': m, 'grup_id': grupId},
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    });
  }

  /// Membuat variasi standar Seblak (idempotent, aman dipanggil berulang):
  /// Level Pedas, Kuah, Rasa, dan Topping Tambahan (dari bahan prasmanan),
  /// lalu memasangnya ke semua menu aktif. Mengembalikan jumlah kelompok baru.
  Future<int> buatVariasiAwal() async {
    final d = await _db;
    return d.transaction((tx) async {
      var dibuat = 0;

      Future<int> grup(String nama, {int maks = 1}) async {
        final r = await tx.query('variasi_grup',
            where: 'nama = ? COLLATE NOCASE', whereArgs: [nama]);
        if (r.isNotEmpty) return r.first['id'] as int;
        dibuat++;
        return tx.insert('variasi_grup', {
          'nama': nama,
          'wajib': 0,
          'maks_pilih': maks,
          'aktif': 1,
          'tipe': maks == 1 ? 'RADIO' : 'BANYAK',
        });
      }

      Future<void> opsi(int gid, String nama,
          {int harga = 0, int urutan = 0, int? bahanId, double qty = 0}) async {
        final r = await tx.query('variasi_opsi',
            where: 'grup_id = ? AND nama = ? COLLATE NOCASE', whereArgs: [gid, nama]);
        if (r.isNotEmpty) return;
        final oid = await tx.insert('variasi_opsi', {
          'grup_id': gid,
          'nama': nama,
          'harga_tambah': harga,
          'urutan': urutan,
          'aktif': 1,
        });
        if (bahanId != null && qty > 0) {
          await tx.insert('variasi_opsi_bahan',
              {'opsi_id': oid, 'bahan_id': bahanId, 'qty_dasar': qty});
        }
      }

      final gPedas = await grup('Level Pedas');
      for (var i = 0; i <= 10; i++) {
        await opsi(gPedas, 'Level $i', urutan: i);
      }
      final gKuah = await grup('Kuah');
      for (var i = 0; i < kKuah.length; i++) {
        await opsi(gKuah, kKuah[i], urutan: i);
      }
      final gRasa = await grup('Rasa');
      for (var i = 0; i < kRasa.length; i++) {
        await opsi(gRasa, kRasa[i], urutan: i);
      }
      // Ekstra topping: boleh lebih dari satu, opsional, maksimal 5 (ubah di Kelola > Variasi).
      final gTopping = await grup('Topping Tambahan', maks: 5);
      final tb = await tx.query('bahan',
          where: 'aktif = 1 AND bisa_prasmanan = 1 AND harga_prasmanan > 0',
          orderBy: 'nama COLLATE NOCASE');
      for (final b in tb) {
        await opsi(gTopping, b['nama'] as String,
            harga: (b['harga_prasmanan'] as num).toInt(),
            bahanId: b['id'] as int,
            qty: (b['qty_prasmanan'] as num).toDouble());
      }

      // Hanya menu dari kategori dengan "Opsi seblak" aktif (Minuman/Es tidak ikut dipasangi).
      final menus = await tx.rawQuery('''
        SELECT m.id FROM menu m LEFT JOIN menu_kategori k ON k.id = m.kategori_id
        WHERE m.aktif = 1 AND COALESCE(k.opsi_seblak, 1) = 1''');
      for (final g in [gPedas, gKuah, gRasa, gTopping]) {
        for (final m in menus) {
          await tx.insert('menu_variasi_grup', {'menu_id': m['id'], 'grup_id': g},
              conflictAlgorithm: ConflictAlgorithm.ignore);
        }
      }
      return dibuat;
    });
  }

  /// Bahan ringkas (id, nama, satuan_dasar) untuk pilihan di form opsi.
  Future<List<Map<String, Object?>>> daftarBahanRingkas() async {
    final d = await _db;
    return d.rawQuery(
        'SELECT id, nama, satuan_dasar FROM bahan WHERE aktif = 1 ORDER BY nama COLLATE NOCASE');
  }

  // ------------------------------------------------------------ kategori menu

  Future<List<Map<String, Object?>>> daftarMenuKategori() async {
    final d = await _db;
    return d.rawQuery('''
      SELECT m.id, m.nama, k.nama AS kategori, m.aktif
      FROM menu m LEFT JOIN menu_kategori k ON k.id = m.kategori_id
      ORDER BY m.nama COLLATE NOCASE''');
  }

  Future<void> setKategoriMenu(int menuId, String? kategori) async {
    final d = await _db;
    await d.transaction((tx) async {
      final k = await _kategoriKanonis(tx, kategori);
      await tx.update('menu', {'kategori': k.nama, 'kategori_id': k.id},
          where: 'id = ?', whereArgs: [menuId]);
    });
  }

  // ------------------------------------------------------------ master kategori

  static const List<String> _namaKategoriDicadangkan = ['semua', 'prasmanan', 'lainnya'];

  /// Mengembalikan id + nama kategori sesuai master (membuat baru bila belum ada).
  /// null / kosong = tanpa kategori ("Lainnya", id null).
  Future<({int? id, String? nama})> _kategoriKanonis(DatabaseExecutor tx, String? kategori) async {
    final k = kategori?.trim() ?? '';
    if (k.isEmpty) return (id: null, nama: null);
    if (_namaKategoriDicadangkan.contains(k.toLowerCase())) {
      throw PosException('Nama "$k" dicadangkan sistem, pakai nama lain');
    }
    final ada = await tx.query('menu_kategori',
        columns: ['id', 'nama'], where: 'nama = ? COLLATE NOCASE', whereArgs: [k]);
    if (ada.isNotEmpty) return (id: ada.first['id'] as int, nama: ada.first['nama'] as String);
    final maks = Sqflite.firstIntValue(await tx.rawQuery('SELECT MAX(urutan) FROM menu_kategori')) ?? 0;
    final id = await tx.insert('menu_kategori', {'nama': k, 'urutan': maks + 1, 'opsi_seblak': 0});
    return (id: id, nama: k);
  }

  /// Semua kategori (urut sesuai pengaturan) beserta jumlah menunya.
  Future<List<Map<String, Object?>>> daftarKategori() async {
    final d = await _db;
    return d.rawQuery('''
      SELECT k.id, k.nama, k.urutan, k.opsi_seblak,
             (SELECT COUNT(*) FROM menu m WHERE m.kategori_id = k.id) AS jumlah_menu
      FROM menu_kategori k ORDER BY k.urutan, k.nama COLLATE NOCASE''');
  }

  /// Tambah (id null) atau ubah. Mengganti nama ikut memindahkan menu-menunya.
  Future<int> simpanKategori({int? id, required String nama, bool opsiSeblak = false}) async {
    final k = nama.trim();
    if (k.isEmpty) throw PosException('Nama kategori wajib diisi');
    if (k.length > 30) throw PosException('Nama kategori maksimal 30 huruf');
    if (_namaKategoriDicadangkan.contains(k.toLowerCase())) {
      throw PosException('Nama "$k" dicadangkan sistem, pakai nama lain');
    }
    final d = await _db;
    return d.transaction((tx) async {
      final dup = await tx.query('menu_kategori',
          where: 'nama = ? COLLATE NOCASE AND id != ?', whereArgs: [k, id ?? -1]);
      if (dup.isNotEmpty) throw PosException('Kategori "$k" sudah ada');
      if (id == null) {
        final maks =
            Sqflite.firstIntValue(await tx.rawQuery('SELECT MAX(urutan) FROM menu_kategori')) ?? 0;
        return tx.insert(
            'menu_kategori', {'nama': k, 'urutan': maks + 1, 'opsi_seblak': opsiSeblak ? 1 : 0});
      }
      final lama = await tx.query('menu_kategori', where: 'id = ?', whereArgs: [id]);
      if (lama.isEmpty) throw PosException('Kategori tidak ditemukan');
      final namaLama = lama.first['nama'] as String;
      await tx.update('menu_kategori', {'nama': k, 'opsi_seblak': opsiSeblak ? 1 : 0},
          where: 'id = ?', whereArgs: [id]);
      if (namaLama != k) {
        await tx.update('menu', {'kategori': k}, where: 'kategori_id = ?', whereArgs: [id]);
      }
      return id;
    });
  }

  /// Menu di kategori ini tidak dihapus; dipindah ke "Lainnya". Mengembalikan jumlah menu.
  Future<int> hapusKategori(int id) async {
    final d = await _db;
    return d.transaction((tx) async {
      final r = await tx.query('menu_kategori', where: 'id = ?', whereArgs: [id]);
      if (r.isEmpty) return 0;
      final pindah = await tx.update('menu', {'kategori': null, 'kategori_id': null},
          where: 'kategori_id = ?', whereArgs: [id]);
      await tx.delete('menu_kategori', where: 'id = ?', whereArgs: [id]);
      return pindah;
    });
  }

  Future<void> urutkanKategori(List<int> idUrut) async {
    final d = await _db;
    await d.transaction((tx) async {
      for (var i = 0; i < idUrut.length; i++) {
        await tx.update('menu_kategori', {'urutan': i}, where: 'id = ?', whereArgs: [idUrut[i]]);
      }
    });
  }

  /// Menetapkan menu-menu yang masuk kategori ini. Menu yang sebelumnya di kategori ini
  /// tetapi tidak dipilih dipindah ke "Lainnya".
  Future<void> setMenuUntukKategori(int kategoriId, List<int> menuIds) async {
    final d = await _db;
    await d.transaction((tx) async {
      final r = await tx.query('menu_kategori', where: 'id = ?', whereArgs: [kategoriId]);
      if (r.isEmpty) throw PosException('Kategori tidak ditemukan');
      final nama = r.first['nama'] as String;
      await tx.update('menu', {'kategori': null, 'kategori_id': null},
          where: 'kategori_id = ?', whereArgs: [kategoriId]);
      for (final m in menuIds.toSet()) {
        await tx.update('menu', {'kategori': nama, 'kategori_id': kategoriId},
            where: 'id = ?', whereArgs: [m]);
      }
    });
  }

  /// Memasang kelompok variasi / ekstra topping ke satu menu (dari sisi menu).
  Future<void> setGrupUntukMenu(int menuId, List<int> grupIds) async {
    final d = await _db;
    await d.transaction((tx) async {
      await tx.delete('menu_variasi_grup', where: 'menu_id = ?', whereArgs: [menuId]);
      var urut = 0;
      for (final g in grupIds.toSet()) {
        await tx.insert('menu_variasi_grup', {'menu_id': menuId, 'grup_id': g, 'urutan': urut++},
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    });
  }

  /// Daftar kategori untuk filter dashboard (menu tanpa kategori = "Lainnya").
  Future<List<String>> daftarKategoriMenu() async {
    final d = await _db;
    final r = await d.rawQuery('''
      SELECT DISTINCT COALESCE(NULLIF(TRIM(kategori), ''), 'Lainnya') AS k
      FROM menu WHERE aktif = 1 ORDER BY k COLLATE NOCASE''');
    final out = r.map((e) => e['k'] as String).toList();
    if (!out.contains('Prasmanan')) out.add('Prasmanan');
    return out;
  }

  // ------------------------------------------------- ringkasan dashboard terfilter

  ({String where, List<Object?> args}) _filterRingkas(
      String dari, String sampai, int? menuId, String? kategori) {
    final w = StringBuffer("t.status = 'SELESAI' AND date(t.waktu) BETWEEN ? AND ?");
    final a = <Object?>[dari, sampai];
    if (menuId != null) {
      w.write(' AND ti.menu_id = ?');
      a.add(menuId);
    }
    if (kategori != null && kategori.isNotEmpty) {
      w.write(" AND (CASE WHEN ti.tipe = 'PRASMANAN' THEN 'Prasmanan' "
          "ELSE COALESCE(NULLIF(TRIM(m.kategori), ''), 'Lainnya') END) = ?");
      a.add(kategori);
    }
    return (where: w.toString(), args: a);
  }

  /// Total untuk rentang tanggal 'yyyy-MM-dd'. Filter menu/kategori opsional.
  Future<Map<String, Object?>> ringkasTotalMenu(
      {required String dari, required String sampai, int? menuId, String? kategori}) async {
    final d = await _db;
    final f = _filterRingkas(dari, sampai, menuId, kategori);
    final r = await d.rawQuery('''
      SELECT COUNT(DISTINCT t.id) AS jumlah_transaksi,
             COALESCE(SUM(ti.qty), 0) AS qty,
             COALESCE(SUM(ti.qty * ti.harga_jual), 0) AS omzet,
             COALESCE(SUM(ti.qty * ti.hpp_snapshot), 0) AS hpp,
             COALESCE(SUM(ti.qty * (ti.harga_jual - ti.hpp_snapshot)), 0) AS laba
      FROM transaksi t
      JOIN transaksi_item ti ON ti.transaksi_id = t.id
      LEFT JOIN menu m ON m.id = ti.menu_id
      WHERE ${f.where}''', f.args);
    return r.first;
  }

  /// Performa per menu (qty, omzet, hpp, laba), urut omzet terbesar.
  Future<List<Map<String, Object?>>> ringkasPerMenu(
      {required String dari, required String sampai, int? menuId, String? kategori}) async {
    final d = await _db;
    final f = _filterRingkas(dari, sampai, menuId, kategori);
    return d.rawQuery('''
      SELECT ti.menu_id AS menu_id, ti.nama_item AS nama,
             CASE WHEN ti.tipe = 'PRASMANAN' THEN 'Prasmanan'
                  ELSE COALESCE(NULLIF(TRIM(m.kategori), ''), 'Lainnya') END AS kategori,
             SUM(ti.qty) AS qty,
             SUM(ti.qty * ti.harga_jual) AS omzet,
             SUM(ti.qty * ti.hpp_snapshot) AS hpp,
             SUM(ti.qty * (ti.harga_jual - ti.hpp_snapshot)) AS laba
      FROM transaksi t
      JOIN transaksi_item ti ON ti.transaksi_id = t.id
      LEFT JOIN menu m ON m.id = ti.menu_id
      WHERE ${f.where}
      GROUP BY ti.menu_id, ti.nama_item
      ORDER BY omzet DESC''', f.args);
  }

  /// Variasi paling sering dipilih pada rentang & filter yang sama.
  Future<List<Map<String, Object?>>> ringkasVariasiTerjual(
      {required String dari, required String sampai, int? menuId, String? kategori}) async {
    final d = await _db;
    final f = _filterRingkas(dari, sampai, menuId, kategori);
    return d.rawQuery('''
      SELECT v.grup_nama AS grup, v.opsi_nama AS opsi,
             SUM(ti.qty * v.jumlah) AS qty, SUM(ti.qty * v.harga) AS omzet
      FROM transaksi t
      JOIN transaksi_item ti ON ti.transaksi_id = t.id
      JOIN transaksi_item_variasi v ON v.item_id = ti.id
      LEFT JOIN menu m ON m.id = ti.menu_id
      WHERE ${f.where} AND v.opsi_id IS NOT NULL
      GROUP BY v.grup_nama, v.opsi_nama
      ORDER BY qty DESC LIMIT 10''', f.args);
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

class _BarisVariasi {
  final int grupId;
  final int opsiId;
  final String grupNama;
  final String opsiNama;
  final int harga;
  final double hpp;
  final int jumlah;
  _BarisVariasi(this.grupId, this.opsiId, this.grupNama, this.opsiNama, this.harga, this.hpp,
      [this.jumlah = 1]);
}

class _Hitung {
  final CartItem item;
  String nama;
  int harga = 0;
  double hpp = 0;
  final List<_BarisTopping> baris = [];
  final List<_BarisVariasi> variasi = [];
  _Hitung(this.item) : nama = item.namaItem;
}
