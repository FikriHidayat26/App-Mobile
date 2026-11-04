-- =====================================================
-- POS + Inventaris Kedai Seblak (SQLite 3.31+)  -- SKEMA v2
-- Stok selalu dalam SATUAN DASAR. Resep disimpan sebagai pecahan.
-- Semua perubahan stok WAJIB lewat stok_mutasi (buku besar stok).
-- =====================================================
PRAGMA foreign_keys = ON;

-- ---------- MASTER ----------
CREATE TABLE bahan (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  nama            TEXT NOT NULL UNIQUE,
  satuan_dasar    TEXT NOT NULL,
  stok            REAL NOT NULL DEFAULT 0,
  stok_minimum    REAL NOT NULL DEFAULT 0,
  hpp_per_dasar   REAL NOT NULL DEFAULT 0,
  aktif           INTEGER NOT NULL DEFAULT 1,
  bisa_prasmanan  INTEGER NOT NULL DEFAULT 0,
  harga_prasmanan INTEGER NOT NULL DEFAULT 0,
  qty_prasmanan   REAL NOT NULL DEFAULT 1
);

CREATE TABLE bahan_satuan_beli (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  bahan_id    INTEGER NOT NULL REFERENCES bahan(id) ON DELETE CASCADE,
  nama_satuan TEXT NOT NULL,
  isi_dasar   REAL NOT NULL CHECK (isi_dasar > 0),
  UNIQUE (bahan_id, nama_satuan)
);

CREATE TABLE menu (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  nama        TEXT NOT NULL UNIQUE,
  kategori    TEXT,
  harga_jual  INTEGER NOT NULL DEFAULT 0,
  aktif       INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE resep_item (
  id        INTEGER PRIMARY KEY AUTOINCREMENT,
  menu_id   INTEGER NOT NULL REFERENCES menu(id) ON DELETE CASCADE,
  bahan_id  INTEGER NOT NULL REFERENCES bahan(id),
  qty_num   INTEGER NOT NULL CHECK (qty_num > 0),
  qty_den   INTEGER NOT NULL DEFAULT 1 CHECK (qty_den > 0),
  qty_dec   REAL NOT NULL DEFAULT 0,
  UNIQUE (menu_id, bahan_id)
);

-- ---------- PEMBELIAN ----------
CREATE TABLE pembelian (
  id        INTEGER PRIMARY KEY AUTOINCREMENT,
  tanggal   TEXT NOT NULL DEFAULT (datetime('now','localtime')),
  supplier  TEXT,
  catatan   TEXT
);

CREATE TABLE pembelian_item (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  pembelian_id   INTEGER NOT NULL REFERENCES pembelian(id) ON DELETE CASCADE,
  bahan_id       INTEGER NOT NULL REFERENCES bahan(id),
  satuan_beli_id INTEGER REFERENCES bahan_satuan_beli(id),
  qty_beli       REAL NOT NULL CHECK (qty_beli > 0),
  harga_total    INTEGER NOT NULL,
  qty_dasar      REAL NOT NULL CHECK (qty_dasar > 0)
);

-- ---------- PENJUALAN ----------
CREATE TABLE transaksi (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  no_nota       TEXT NOT NULL UNIQUE,
  waktu         TEXT NOT NULL DEFAULT (datetime('now','localtime')),
  metode_bayar  TEXT NOT NULL DEFAULT 'TUNAI',
  total         INTEGER NOT NULL DEFAULT 0,
  total_hpp     REAL NOT NULL DEFAULT 0,
  status        TEXT NOT NULL DEFAULT 'SELESAI'
);

-- Satu baris = satu pesanan (menu tetap ATAU seblak prasmanan).
-- harga_jual & hpp_snapshot = PER 1 PORSI (sudah termasuk topping tambahan).
CREATE TABLE transaksi_item (
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
);

-- Rincian topping / perubahan bahan per pesanan (per 1 porsi item).
-- jenis: PRASMANAN (pilihan prasmanan), TAMBAH (topping tambahan di menu),
--        HAPUS (bahan resep tidak dipakai -> stok tidak dipotong)
CREATE TABLE transaksi_item_topping (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  item_id      INTEGER NOT NULL REFERENCES transaksi_item(id) ON DELETE CASCADE,
  bahan_id     INTEGER NOT NULL REFERENCES bahan(id),
  nama         TEXT NOT NULL,
  jenis        TEXT NOT NULL CHECK (jenis IN ('PRASMANAN','TAMBAH','HAPUS')),
  jumlah_pick  INTEGER NOT NULL DEFAULT 1,
  qty_dasar    REAL NOT NULL DEFAULT 0,
  harga        INTEGER NOT NULL DEFAULT 0,
  hpp          REAL NOT NULL DEFAULT 0
);

-- ---------- BUKU BESAR STOK ----------
CREATE TABLE stok_mutasi (
  id        INTEGER PRIMARY KEY AUTOINCREMENT,
  bahan_id  INTEGER NOT NULL REFERENCES bahan(id),
  waktu     TEXT NOT NULL DEFAULT (datetime('now','localtime')),
  tipe      TEXT NOT NULL CHECK (tipe IN ('BELI','JUAL','VOID','OPNAME','BUANG','KOREKSI')),
  qty       REAL NOT NULL,
  ref_id    INTEGER,
  catatan   TEXT
);
CREATE INDEX idx_mutasi_bahan ON stok_mutasi(bahan_id, waktu);

-- ---------- OVERHEAD ----------
CREATE TABLE overhead (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  nama          TEXT NOT NULL,
  nominal       INTEGER NOT NULL,
  periode       TEXT NOT NULL CHECK (periode IN ('HARIAN','MINGGUAN','BULANAN')),
  aktif         INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE pengaturan (
  kunci  TEXT PRIMARY KEY,
  nilai  TEXT NOT NULL
);
INSERT INTO pengaturan VALUES ('estimasi_porsi_bulanan', '1500');
INSERT INTO pengaturan VALUES ('biaya_dasar_prasmanan', '0');

-- =====================================================
-- TRIGGER
-- =====================================================
CREATE TRIGGER trg_pembelian_item_ai
AFTER INSERT ON pembelian_item
BEGIN
  UPDATE bahan SET
    hpp_per_dasar = CASE
      WHEN MAX(stok,0) + NEW.qty_dasar > 0
      THEN (MAX(stok,0) * hpp_per_dasar + NEW.harga_total) / (MAX(stok,0) + NEW.qty_dasar)
      ELSE hpp_per_dasar END,
    stok = stok + NEW.qty_dasar
  WHERE id = NEW.bahan_id;

  INSERT INTO stok_mutasi (bahan_id, tipe, qty, ref_id)
  VALUES (NEW.bahan_id, 'BELI', NEW.qty_dasar, NEW.pembelian_id);
END;

CREATE TRIGGER trg_resep_item_ai
AFTER INSERT ON resep_item
BEGIN
  UPDATE resep_item SET qty_dec = 1.0 * qty_num / qty_den WHERE id = NEW.id;
END;

-- =====================================================
-- VIEW
-- =====================================================
CREATE VIEW v_hpp_rincian AS
SELECT r.menu_id, m.nama AS menu, b.nama AS bahan,
       r.qty_num || '/' || r.qty_den AS takaran,
       r.qty_dec * b.hpp_per_dasar AS biaya
FROM resep_item r
JOIN menu m  ON m.id = r.menu_id
JOIN bahan b ON b.id = r.bahan_id;

CREATE VIEW v_hpp_menu AS
SELECT m.id AS menu_id, m.nama, m.harga_jual,
       COALESCE(SUM(r.qty_dec * b.hpp_per_dasar), 0) AS hpp_bahan
FROM menu m
LEFT JOIN resep_item r ON r.menu_id = m.id
LEFT JOIN bahan b ON b.id = r.bahan_id
GROUP BY m.id;

CREATE VIEW v_overhead_per_porsi AS
SELECT
  SUM(CASE periode WHEN 'BULANAN' THEN nominal ELSE nominal * 30 END) AS overhead_bulanan,
  SUM(CASE periode WHEN 'BULANAN' THEN nominal ELSE nominal * 30 END)
    / (SELECT CAST(nilai AS REAL) FROM pengaturan WHERE kunci = 'estimasi_porsi_bulanan') AS per_porsi
FROM overhead WHERE aktif = 1;

CREATE VIEW v_margin_menu AS
SELECT h.nama, h.harga_jual, h.hpp_bahan,
       h.hpp_bahan + COALESCE(o.per_porsi,0) AS hpp_penuh,
       h.harga_jual - h.hpp_bahan - COALESCE(o.per_porsi,0) AS laba_per_porsi,
       CASE WHEN h.harga_jual > 0
         THEN (h.harga_jual - h.hpp_bahan - COALESCE(o.per_porsi,0)) * 100.0 / h.harga_jual END AS margin_persen
FROM v_hpp_menu h, v_overhead_per_porsi o;

CREATE VIEW v_rekap_harian AS
SELECT date(t.waktu) AS tanggal,
       COUNT(DISTINCT t.id)           AS jumlah_transaksi,
       SUM(ti.qty)                    AS porsi_terjual,
       SUM(ti.qty * ti.harga_jual)    AS omzet,
       SUM(ti.qty * ti.hpp_snapshot)  AS total_hpp,
       SUM(ti.qty * (ti.harga_jual - ti.hpp_snapshot)) AS laba_kotor
FROM transaksi t JOIN transaksi_item ti ON ti.transaksi_id = t.id
WHERE t.status = 'SELESAI'
GROUP BY date(t.waktu);

CREATE VIEW v_stok AS
SELECT id, nama, satuan_dasar, stok, stok_minimum,
       stok * hpp_per_dasar AS nilai_stok,
       CASE WHEN stok <= stok_minimum THEN 1 ELSE 0 END AS perlu_beli
FROM bahan WHERE aktif = 1;

CREATE VIEW v_sisa_porsi_menu AS
SELECT m.id AS menu_id, m.nama,
       CAST(MIN(b.stok / r.qty_dec) AS INTEGER) AS sisa_porsi
FROM menu m
JOIN resep_item r ON r.menu_id = m.id
JOIN bahan b ON b.id = r.bahan_id
GROUP BY m.id;

-- =====================================================
-- DATA AWAL (harga = ASUMSI, ganti dengan harga asli)
-- =====================================================
INSERT INTO bahan (id,nama,satuan_dasar,hpp_per_dasar,stok_minimum) VALUES
 (1,'Sayur','batang',500,20),
 (2,'Mie','keping',3000,10),
 (3,'Kerupuk','pcs',50,200),
 (4,'Sosis ayam','pcs',1500,20),
 (5,'Sosis jumbo','pcs',3000,10),
 (6,'Cikuwa','pcs',1500,20),
 (7,'Tofu','pcs',1000,20),
 (8,'Kembang cumi','pcs',1200,20),
 (9,'Dumpling keju','pcs',1800,20),
 (10,'Enoki','bungkus',6000,3);

-- Pengaturan prasmanan (ASUMSI): harga per 1 pilihan & stok terpakai per pilihan
UPDATE bahan SET bisa_prasmanan=1, harga_prasmanan=1000, qty_prasmanan=1   WHERE id=1;
UPDATE bahan SET bisa_prasmanan=1, harga_prasmanan=3000, qty_prasmanan=0.5 WHERE id=2;
UPDATE bahan SET bisa_prasmanan=1, harga_prasmanan=1000, qty_prasmanan=5   WHERE id=3;
UPDATE bahan SET bisa_prasmanan=1, harga_prasmanan=2500, qty_prasmanan=1   WHERE id=4;
UPDATE bahan SET bisa_prasmanan=1, harga_prasmanan=4500, qty_prasmanan=1   WHERE id=5;
UPDATE bahan SET bisa_prasmanan=1, harga_prasmanan=2500, qty_prasmanan=1   WHERE id=6;
UPDATE bahan SET bisa_prasmanan=1, harga_prasmanan=2000, qty_prasmanan=1   WHERE id=7;
UPDATE bahan SET bisa_prasmanan=1, harga_prasmanan=2000, qty_prasmanan=1   WHERE id=8;
UPDATE bahan SET bisa_prasmanan=1, harga_prasmanan=2500, qty_prasmanan=1   WHERE id=9;
UPDATE bahan SET bisa_prasmanan=1, harga_prasmanan=2000, qty_prasmanan=0.25 WHERE id=10;

INSERT INTO bahan_satuan_beli (bahan_id,nama_satuan,isi_dasar) VALUES
 (1,'ikat',10),(2,'dus',40),(3,'bal',1000),(4,'pack',20),(5,'pack',10),
 (6,'pack',10),(7,'pack',10),(8,'pack',20),(9,'pack',20),(10,'bungkus',1);

INSERT INTO menu (id,nama,kategori,harga_jual) VALUES
 (1,'Seblak Umume','Seblak',12000),
 (2,'Seblak Special','Seblak',20000);

INSERT INTO resep_item (menu_id,bahan_id,qty_num,qty_den) VALUES
 (1,1,1,1),(1,2,1,3),(1,3,5,1),(1,4,1,2),(1,6,1,1),(1,10,1,12);

INSERT INTO resep_item (menu_id,bahan_id,qty_num,qty_den) VALUES
 (2,4,1,1),(2,6,1,1),(2,7,1,1),(2,8,1,1),(2,9,1,1),
 (2,5,1,2),(2,10,1,12),(2,2,1,3),(2,1,1,1),(2,3,5,1);

INSERT INTO overhead (nama,nominal,periode) VALUES
 ('Sewa',1500000,'BULANAN'),('Listrik & air',500000,'BULANAN'),
 ('Gas',20000,'HARIAN');
