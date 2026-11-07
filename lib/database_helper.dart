// database_helper.dart — membuka SQLite, membuat skema v2, dan memigrasi
// database lama (v1) secara otomatis tanpa menghapus data.
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

class DatabaseHelper {
  DatabaseHelper._();
  static final DatabaseHelper instance = DatabaseHelper._();

  /// Nama file DB yang dipakai versi lama aplikasi (data lama tetap terbaca & dimigrasi).
  static const String dbName = 'kedai.db';
  static const int dbVersion = 2;

  Database? _db;
  Future<Database> get database async => _db ??= await _buka();

  /// Dipakai saat restore: buang referensi DB lama (yang sudah ditutup) agar
  /// pembukaan berikutnya membaca berkas hasil pemulihan.
  void lepas() => _db = null;

  Future<Database> _buka() async {
    final path = p.join(await getDatabasesPath(), dbName);
    return openDatabase(
      path,
      version: dbVersion,
      onConfigure: (db) async => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (db, v) async {
        final sql = await rootBundle.loadString('assets/schema.sql');
        for (final stmt in _pecahSql(sql)) {
          await db.execute(stmt);
        }
      },
      // Idempotent: aman dijalankan setiap kali DB dibuka.
      onOpen: _pastikanSkemaV2,
    );
  }

  /// Memecah skrip SQL; trigger (BEGIN..END;) dijaga utuh.
  static List<String> _pecahSql(String sql) {
    final hasil = <String>[];
    final buf = StringBuffer();
    var dalamTrigger = false;
    for (final raw in sql.split('\n')) {
      final idx = raw.indexOf('--');
      final line = (idx >= 0 ? raw.substring(0, idx) : raw).trimRight();
      if (line.trim().isEmpty) continue;
      if (buf.isEmpty && line.trimLeft().toUpperCase().startsWith('CREATE TRIGGER')) {
        dalamTrigger = true;
      }
      buf.writeln(line);
      final akhir = line.trim().toUpperCase();
      final selesai = dalamTrigger ? akhir == 'END;' : akhir.endsWith(';');
      if (selesai) {
        final s = buf.toString().trim();
        if (!s.toUpperCase().startsWith('PRAGMA')) hasil.add(s);
        buf.clear();
        dalamTrigger = false;
      }
    }
    return hasil;
  }

  Future<bool> _punyaKolom(DatabaseExecutor db, String tabel, String kolom) async {
    final r = await db.rawQuery('PRAGMA table_info($tabel)');
    return r.any((e) => e['name'] == kolom);
  }

  static const String _sqlTopping = '''
CREATE TABLE IF NOT EXISTS transaksi_item_topping (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  item_id      INTEGER NOT NULL REFERENCES transaksi_item(id) ON DELETE CASCADE,
  bahan_id     INTEGER NOT NULL REFERENCES bahan(id),
  nama         TEXT NOT NULL,
  jenis        TEXT NOT NULL CHECK (jenis IN ('PRASMANAN','TAMBAH','HAPUS')),
  jumlah_pick  INTEGER NOT NULL DEFAULT 1,
  qty_dasar    REAL NOT NULL DEFAULT 0,
  harga        INTEGER NOT NULL DEFAULT 0,
  hpp          REAL NOT NULL DEFAULT 0
)''';

  static const String _sqlRekapHarian = '''
CREATE VIEW v_rekap_harian AS
SELECT date(t.waktu) AS tanggal,
       COUNT(DISTINCT t.id)           AS jumlah_transaksi,
       SUM(ti.qty)                    AS porsi_terjual,
       SUM(ti.qty * ti.harga_jual)    AS omzet,
       SUM(ti.qty * ti.hpp_snapshot)  AS total_hpp,
       SUM(ti.qty * (ti.harga_jual - ti.hpp_snapshot)) AS laba_kotor
FROM transaksi t JOIN transaksi_item ti ON ti.transaksi_id = t.id
WHERE t.status = 'SELESAI'
GROUP BY date(t.waktu)''';

  Future<void> _pastikanSkemaV2(Database db) async {
    final perluBahan = !await _punyaKolom(db, 'bahan', 'bisa_prasmanan');
    final perluItem = !await _punyaKolom(db, 'transaksi_item', 'tipe');

    if (!perluBahan && !perluItem) {
      await db.execute(_sqlTopping);
      await db.execute(
          "INSERT OR IGNORE INTO pengaturan (kunci, nilai) VALUES ('biaya_dasar_prasmanan','0')");
      return;
    }

    await db.execute('PRAGMA foreign_keys = OFF');
    try {
      await db.transaction((tx) async {
        if (perluBahan) {
          await tx.execute('ALTER TABLE bahan ADD COLUMN bisa_prasmanan INTEGER NOT NULL DEFAULT 0');
          await tx.execute('ALTER TABLE bahan ADD COLUMN harga_prasmanan INTEGER NOT NULL DEFAULT 0');
          await tx.execute('ALTER TABLE bahan ADD COLUMN qty_prasmanan REAL NOT NULL DEFAULT 1');
        }
        if (perluItem) {
          // menu_id harus boleh NULL (prasmanan) -> tabel dibangun ulang.
          await tx.execute('DROP VIEW IF EXISTS v_rekap_harian');
          await tx.execute('''
CREATE TABLE transaksi_item_baru (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  transaksi_id  INTEGER NOT NULL REFERENCES transaksi(id) ON DELETE CASCADE,
  menu_id       INTEGER REFERENCES menu(id),
  tipe          TEXT NOT NULL DEFAULT 'MENU' CHECK (tipe IN ('MENU','PRASMANAN')),
  nama_item     TEXT NOT NULL DEFAULT '',
  qty           INTEGER NOT NULL CHECK (qty > 0),
  harga_jual    INTEGER NOT NULL,
  hpp_snapshot  REAL NOT NULL,
  level_pedas   TEXT,
  kuah          TEXT,
  rasa          TEXT,
  catatan       TEXT
)''');
          await tx.execute('''
INSERT INTO transaksi_item_baru (id, transaksi_id, menu_id, tipe, nama_item, qty, harga_jual, hpp_snapshot)
SELECT ti.id, ti.transaksi_id, ti.menu_id, 'MENU', COALESCE(m.nama, ''), ti.qty, ti.harga_jual, ti.hpp_snapshot
FROM transaksi_item ti LEFT JOIN menu m ON m.id = ti.menu_id''');
          await tx.execute('DROP TABLE transaksi_item');
          await tx.execute('ALTER TABLE transaksi_item_baru RENAME TO transaksi_item');
          await tx.execute(_sqlRekapHarian);
        }
        await tx.execute(_sqlTopping);
        await tx.execute(
            "INSERT OR IGNORE INTO pengaturan (kunci, nilai) VALUES ('biaya_dasar_prasmanan','0')");
      });
    } finally {
      await db.execute('PRAGMA foreign_keys = ON');
    }
  }
}
