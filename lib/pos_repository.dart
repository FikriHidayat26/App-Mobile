// pos_repository.dart — Pengelola database & logika utama POS
import 'package:sqflite/sqflite.dart';
import 'models.dart';

class PosException implements Exception {
  final String pesan;
  const PosException(this.pesan);
  @override
  String toString() => pesan;
}

class PosRepository {
  static Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDb();
    return _db!;
  }

  Future<Database> _initDb() async {
    final path = await getDatabasesPath();
    final dbPath = '$path/pawoen_langgananku.db';

    return await openDatabase(
      dbPath,
      version: 2, // versi 2: biaya tetap mendukung periode MINGGUAN
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onUpgrade: (db, oldV, newV) async {
        // sqflite sudah menjalankan onUpgrade di dalam satu transaksi,
        // jadi tidak perlu db.transaction lagi.
        if (oldV < 2) {
          await db.execute('DROP VIEW IF EXISTS v_margin_menu');
          await db.execute('DROP VIEW IF EXISTS v_overhead_per_porsi');

          await db.execute('''
            CREATE TABLE overhead_baru (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              nama TEXT NOT NULL,
              nominal INTEGER NOT NULL,
              periode TEXT NOT NULL CHECK (periode IN ('HARIAN','MINGGUAN','BULANAN')),
              aktif INTEGER NOT NULL DEFAULT 1
            )''');
          await db.execute(
              'INSERT INTO overhead_baru SELECT id,nama,nominal,periode,aktif FROM overhead');
          await db.execute('DROP TABLE overhead');
          await db.execute('ALTER TABLE overhead_baru RENAME TO overhead');

          await db.execute('''
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

          await db.execute('''
            CREATE VIEW v_margin_menu AS
            SELECT h.nama, h.harga_jual, h.hpp_bahan,
                   h.hpp_bahan + COALESCE(o.per_porsi,0) AS hpp_penuh,
                   h.harga_jual - h.hpp_bahan - COALESCE(o.per_porsi,0) AS laba_per_porsi,
                   CASE WHEN h.harga_jual > 0
                     THEN (h.harga_jual - h.hpp_bahan - COALESCE(o.per_porsi,0)) * 100.0 / h.harga_jual END AS margin_persen
            FROM v_hpp_menu h, v_overhead_per_porsi o''');
        }
      },
    );
  }

  // --- OVERHEAD & HPP ---

  Future<List<Map<String, Object?>>> daftarOverhead() async {
    final db = await database;
    return await db.query('overhead', orderBy: 'id');
  }

  Future<double> overheadPerPorsi() async {
    final db = await database;
    final res = await db.rawQuery('SELECT per_porsi FROM v_overhead_per_porsi');
    if (res.isNotEmpty && res.first['per_porsi'] != null) {
      return (res.first['per_porsi'] as num).toDouble();
    }
    return 0.0;
  }

  Future<void> simpanOverhead({
    int? id,
    required String nama,
    required int nominal,
    required String periode,
    required bool aktif,
  }) async {
    if (nama.trim().isEmpty) throw const PosException('Nama biaya tetap wajib diisi');
    if (nominal < 0) throw const PosException('Nominal tidak valid');
    if (periode != 'HARIAN' && periode != 'MINGGUAN' && periode != 'BULANAN') {
      throw const PosException('Periode tidak valid');
    }

    final db = await database;
    final data = {
      'nama': nama.trim(),
      'nominal': nominal,
      'periode': periode,
      'aktif': aktif ? 1 : 0,
    };

    if (id == null) {
      await db.insert('overhead', data);
    } else {
      await db.update('overhead', data, where: 'id = ?', whereArgs: [id]);
    }
  }

  Future<void> hapusOverhead(int id) async {
    final db = await database;
    await db.delete('overhead', where: 'id = ?', whereArgs: [id]);
  }

  Future<int> estimasiPorsiBulanan() async {
    final db = await database;
    final res = await db.query('pengaturan', where: "kunci = 'estimasi_porsi_bulanan'");
    if (res.isNotEmpty) {
      return int.tryParse(res.first['nilai'].toString()) ?? 1500;
    }
    return 1500;
  }

  Future<void> setEstimasiPorsiBulanan(int porsi) async {
    if (porsi <= 0) throw const PosException('Estimasi porsi minimal 1');
    final db = await database;
    await db.insert(
      'pengaturan',
      {'kunci': 'estimasi_porsi_bulanan', 'nilai': porsi.toString()},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<double> targetMargin() async {
    final db = await database;
    final res = await db.query('pengaturan', where: "kunci = 'target_margin'");
    if (res.isNotEmpty) {
      return double.tryParse(res.first['nilai'].toString()) ?? 30.0;
    }
    return 30.0;
  }

  Future<void> setTargetMargin(double target) async {
    if (target < 0 || target >= 100) {
      throw const PosException('Target margin harus antara 0 - 99%');
    }
    final db = await database;
    await db.insert(
      'pengaturan',
      {'kunci': 'target_margin', 'nilai': target.toString()},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<int> biayaDasarPrasmanan() async {
    final db = await database;
    final res = await db.query('pengaturan', where: "kunci = 'biaya_dasar_prasmanan'");
    if (res.isNotEmpty) {
      return int.tryParse(res.first['nilai'].toString()) ?? 0;
    }
    return 0;
  }

  Future<int> porsiTerjual30Hari() async {
    final db = await database;
    final res = await db.rawQuery('''
      SELECT COALESCE(SUM(ti.qty), 0) AS total
      FROM transaksi t
      JOIN transaksi_item ti ON ti.transaksi_id = t.id
      WHERE t.status = 'SELESAI'
        AND t.waktu >= datetime('now','localtime','-30 days')
    ''');
    if (res.isNotEmpty) {
      return (res.first['total'] as num).toInt();
    }
    return 0;
  }

  /// Menu lengkap untuk layar HPP: id, nama, harga_jual, aktif, hpp_bahan.
  Future<List<Map<String, Object?>>> daftarMenuLengkap() async {
    final db = await database;
    return await db.rawQuery('''
      SELECT m.id, m.nama, m.harga_jual, m.aktif, h.hpp_bahan
      FROM menu m
      JOIN v_hpp_menu h ON h.menu_id = m.id
      ORDER BY m.id
    ''');
  }

  Future<List<Bahan>> daftarBahan() async {
    final db = await database;
    final res = await db.query('bahan', where: 'aktif = 1');
    return res.map((m) => Bahan.fromMap(m)).toList();
  }

  Future<void> updateMenu(int id, {required int harga}) async {
    final db = await database;
    await db.update('menu', {'harga_jual': harga}, where: 'id = ?', whereArgs: [id]);
  }
}
