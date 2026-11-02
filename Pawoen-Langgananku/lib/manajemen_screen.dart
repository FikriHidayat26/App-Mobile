
// manajemen_screen.dart
// Tab: Menu (+ editor resep pecahan), Bahan (+ satuan beli), Kulak (pembelian).
// Pakai PosRepository dari pos_repository.dart (tanpa paket tambahan).
//
//   Navigator.push(context, MaterialPageRoute(
//     builder: (_) => ManajemenScreen(repo: repo)));

import 'package:flutter/material.dart';
import 'pos_repository.dart';

// ---------- Helper ----------
String rp(num v) {
  final s = v.round().abs().toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write('.');
    b.write(s[i]);
  }
  return '${v < 0 ? '-' : ''}Rp$b';
}

String qtyFmt(num v) {
  final r = (v * 100).round() / 100;
  return r == r.roundToDouble() ? r.toInt().toString() : r.toString();
}

num n(Object? v) => (v as num?) ?? 0;

void snack(BuildContext c, String msg) =>
    ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(msg)));

// ---------- Query tambahan ----------
extension ManajemenQueries on PosRepository {
  Future<List<Map<String, Object?>>> daftarMenu() => db.rawQuery('''
      SELECT m.id, m.nama, m.harga_jual, m.aktif, h.hpp_bahan
      FROM menu m JOIN v_hpp_menu h ON h.menu_id = m.id
      ORDER BY m.aktif DESC, m.nama''');

  Future<List<Map<String, Object?>>> daftarBahan({bool semua = false}) => db.query('bahan',
      where: semua ? null : 'aktif = 1', orderBy: 'aktif DESC, nama');

  Future<List<Map<String, Object?>>> satuanBeli(int bahanId) =>
      db.query('bahan_satuan_beli', where: 'bahan_id = ?', whereArgs: [bahanId]);

  Future<List<Map<String, Object?>>> resepMenu(int menuId) => db.rawQuery('''
      SELECT r.bahan_id, b.nama, b.satuan_dasar, r.qty_num, r.qty_den,
             r.qty_dec * b.hpp_per_dasar AS biaya
      FROM resep_item r JOIN bahan b ON b.id = r.bahan_id
      WHERE r.menu_id = ? ORDER BY b.nama''', [menuId]);

  Future<void> updateMenu(int id, {String? nama, int? harga, bool? aktif}) => db.update(
      'menu',
      {
        if (nama != null) 'nama': nama,
        if (harga != null) 'harga_jual': harga,
        if (aktif != null) 'aktif': aktif ? 1 : 0,
      },
      where: 'id = ?',
      whereArgs: [id]).then((_) {});

  Future<void> updateBahan(int id, {double? stokMin, bool? aktif}) => db.update(
      'bahan',
      {
        if (stokMin != null) 'stok_minimum': stokMin,
        if (aktif != null) 'aktif': aktif ? 1 : 0,
      },
      where: 'id = ?',
      whereArgs: [id]).then((_) {});
}

// ---------- Layar utama ----------
class ManajemenScreen extends StatelessWidget {
  final PosRepository repo;
  const ManajemenScreen({super.key, required this.repo});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Kelola Menu & Bahan'),
          bottom: const TabBar(tabs: [
            Tab(text: 'Menu'),
            Tab(text: 'Bahan'),
            Tab(text: 'Kulak'),
          ]),
        ),
        body: TabBarView(children: [
          MenuTab(repo: repo),
          BahanTab(repo: repo),
          KulakTab(repo: repo),
        ]),
      ),
    );
  }
}

// =====================================================
// TAB MENU
// =====================================================
class MenuTab extends StatefulWidget {
  final PosRepository repo;
  const MenuTab({super.key, required this.repo});
  @override
  State<MenuTab> createState() => _MenuTabState();
}

class _MenuTabState extends State<MenuTab> {
  late Future<List<Map<String, Object?>>> _f = widget.repo.daftarMenu();
  void _refresh() => setState(() => _f = widget.repo.daftarMenu());

  Future<void> _tambah() async {
    final nama = TextEditingController();
    final harga = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Menu baru'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: nama, decoration: const InputDecoration(labelText: 'Nama menu')),
          TextField(
              controller: harga,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Harga jual (Rp)')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Simpan')),
        ],
      ),
    );
    if (ok != true || nama.text.trim().isEmpty) return;
    try {
      final id = await widget.repo.tambahMenu(nama.text.trim(), int.tryParse(harga.text) ?? 0);
      _refresh();
      if (mounted) _bukaResep(id);
    } catch (_) {
      if (mounted) snack(context, 'Nama menu sudah dipakai');
    }
  }

  Future<void> _bukaResep(int id) async {
    await Navigator.push(context,
        MaterialPageRoute(builder: (_) => ResepEditorScreen(repo: widget.repo, menuId: id)));
    _refresh();
  }

  Future<void> _duplikat(Map<String, Object?> m) async {
    final nama = TextEditingController(text: '${m['nama']} (salinan)');
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Duplikat menu'),
        content: TextField(controller: nama, decoration: const InputDecoration(labelText: 'Nama menu baru')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Duplikat')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await widget.repo.duplikatMenu(m['id'] as int, nama.text.trim(), n(m['harga_jual']).toInt());
      _refresh();
    } catch (_) {
      if (mounted) snack(context, 'Nama menu sudah dipakai');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton:
          FloatingActionButton.extended(onPressed: _tambah, icon: const Icon(Icons.add), label: const Text('Menu')),
      body: FutureBuilder<List<Map<String, Object?>>>(
        future: _f,
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final data = snap.data!;
          if (data.isEmpty) return const Center(child: Text('Belum ada menu.'));
          return ListView(padding: const EdgeInsets.only(bottom: 88), children: data.map((m) {
            final harga = n(m['harga_jual']).toDouble();
            final hpp = n(m['hpp_bahan']).toDouble();
            final margin = harga > 0 ? (harga - hpp) * 100 / harga : 0;
            final aktif = m['aktif'] == 1;
            return ListTile(
              onTap: () => _bukaResep(m['id'] as int),
              title: Text('${m['nama']}${aktif ? '' : ' (nonaktif)'}',
                  style: TextStyle(color: aktif ? null : Colors.grey)),
              subtitle: Text('Jual ${rp(harga)} • HPP bahan ${rp(hpp)}'),
              leading: Text('${margin.toStringAsFixed(0)}%',
                  style: TextStyle(
                      fontWeight: FontWeight.bold, color: margin < 30 ? Colors.red : Colors.green)),
              trailing: PopupMenuButton<String>(
                onSelected: (v) async {
                  if (v == 'dup') await _duplikat(m);
                  if (v == 'toggle') {
                    await widget.repo.updateMenu(m['id'] as int, aktif: !aktif);
                    _refresh();
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'dup', child: Text('Duplikat')),
                  PopupMenuItem(value: 'toggle', child: Text(aktif ? 'Nonaktifkan' : 'Aktifkan')),
                ],
              ),
            );
          }).toList());
        },
      ),
    );
  }
}

// =====================================================
// EDITOR RESEP
// =====================================================
class ResepEditorScreen extends StatefulWidget {
  final PosRepository repo;
  final int menuId;
  const ResepEditorScreen({super.key, required this.repo, required this.menuId});
  @override
  State<ResepEditorScreen> createState() => _ResepEditorScreenState();
}

class _ResepEditorScreenState extends State<ResepEditorScreen> {
  late Future<List<dynamic>> _f = _load();
  double _targetMargin = 40;

  Future<List<dynamic>> _load() async {
    final menu = await widget.repo.db.query('menu', where: 'id = ?', whereArgs: [widget.menuId]);
    final resep = await widget.repo.resepMenu(widget.menuId);
    final oh = await widget.repo.db.query('v_overhead_per_porsi');
    return [menu.first, resep, n(oh.first['per_porsi']).toDouble()];
  }

  void _refresh() => setState(() => _f = _load());

  Future<void> _ubahHarga(Map<String, Object?> menu) async {
    final c = TextEditingController(text: '${menu['harga_jual']}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Harga jual'),
        content: TextField(controller: c, keyboardType: TextInputType.number),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Simpan')),
        ],
      ),
    );
    if (ok == true) {
      await widget.repo.updateMenu(widget.menuId, harga: int.tryParse(c.text) ?? 0);
      _refresh();
    }
  }

  Future<void> _tambahBahan() async {
    final bahan = await widget.repo.daftarBahan();
    if (!mounted) return;
    if (bahan.isEmpty) {
      snack(context, 'Tambah bahan dulu di tab Bahan');
      return;
    }
    int? pilih = bahan.first['id'] as int;
    final takaran = TextEditingController();
    String? error;

    await showDialog<void>(
      context: context,
      builder: (d) => StatefulBuilder(builder: (d, set) {
        final satuan = bahan.firstWhere((b) => b['id'] == pilih)['satuan_dasar'];
        return AlertDialog(
          title: const Text('Tambah bahan ke resep'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            DropdownButtonFormField<int>(
              value: pilih,
              items: bahan
                  .map((b) => DropdownMenuItem(value: b['id'] as int, child: Text('${b['nama']}')))
                  .toList(),
              onChanged: (v) => set(() => pilih = v),
            ),
            TextField(
              controller: takaran,
              keyboardType: TextInputType.text,
              decoration: InputDecoration(
                  labelText: 'Takaran ($satuan)',
                  hintText: 'contoh: 1, 0.5, 1/3, 1/12',
                  errorText: error),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d), child: const Text('Batal')),
            FilledButton(
              onPressed: () async {
                try {
                  await widget.repo.setResepItem(widget.menuId, pilih!, takaran.text);
                  if (d.mounted) Navigator.pop(d);
                  _refresh();
                } on FormatException {
                  set(() => error = 'Format salah. Pakai 0.5 atau 1/3');
                }
              },
              child: const Text('Simpan'),
            ),
          ],
        );
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<dynamic>>(
      future: _f,
      builder: (context, snap) {
        if (!snap.hasData) return const Scaffold(body: Center(child: CircularProgressIndicator()));
        final menu = snap.data![0] as Map<String, Object?>;
        final resep = snap.data![1] as List<Map<String, Object?>>;
        final overhead = snap.data![2] as double;

        final hpp = resep.fold<double>(0, (a, r) => a + n(r['biaya']));
        final hargaJual = n(menu['harga_jual']).toDouble();
        final hppPenuh = hpp + overhead;
        final laba = hargaJual - hppPenuh;
        final saran = hppPenuh / (1 - _targetMargin / 100);

        return Scaffold(
          appBar: AppBar(title: Text('${menu['nama']}')),
          floatingActionButton: FloatingActionButton.extended(
              onPressed: _tambahBahan, icon: const Icon(Icons.add), label: const Text('Bahan')),
          body: ListView(padding: const EdgeInsets.only(bottom: 96), children: [
            ...resep.map((r) {
              final t = Takaran(r['qty_num'] as int, r['qty_den'] as int);
              return Dismissible(
                key: ValueKey(r['bahan_id']),
                direction: DismissDirection.endToStart,
                background: Container(
                    color: Colors.red,
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 16),
                    child: const Icon(Icons.delete, color: Colors.white)),
                onDismissed: (_) async {
                  await widget.repo.hapusResepItem(widget.menuId, r['bahan_id'] as int);
                  _refresh();
                },
                child: ListTile(
                  title: Text('${r['nama']}'),
                  subtitle: Text('$t ${r['satuan_dasar']}'),
                  trailing: Text(rp(n(r['biaya']))),
                  onTap: () => _tambahBahanDengan(r),
                ),
              );
            }),
            if (resep.isEmpty)
              const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: Text('Resep kosong. Tekan "+ Bahan" untuk mengisi.'))),
            const Divider(),
            _baris('HPP bahan', rp(hpp)),
            _baris('Overhead per porsi', rp(overhead)),
            _baris('HPP penuh', rp(hppPenuh), tebal: true),
            ListTile(
              title: const Text('Harga jual'),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(rp(hargaJual), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                const Icon(Icons.edit, size: 16),
              ]),
              onTap: () => _ubahHarga(menu),
            ),
            _baris('Laba per porsi', rp(laba), warna: laba < 0 ? Colors.red : Colors.green),
            const Divider(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text('Target margin: ${_targetMargin.round()}%  →  saran harga ${rp((saran / 500).ceil() * 500)}'),
            ),
            Slider(
              value: _targetMargin,
              min: 10,
              max: 70,
              divisions: 12,
              label: '${_targetMargin.round()}%',
              onChanged: (v) => setState(() => _targetMargin = v),
            ),
          ]),
        );
      },
    );
  }

  // ketuk baris resep -> edit takaran (dialog tambah dengan bahan terpilih)
  Future<void> _tambahBahanDengan(Map<String, Object?> r) async {
    final c = TextEditingController(text: Takaran(r['qty_num'] as int, r['qty_den'] as int).toString());
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('Takaran ${r['nama']}'),
        content: TextField(controller: c, decoration: const InputDecoration(hintText: '1/12 atau 0.5')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Simpan')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await widget.repo.setResepItem(widget.menuId, r['bahan_id'] as int, c.text);
      _refresh();
    } on FormatException {
      if (mounted) snack(context, 'Format takaran salah');
    }
  }

  Widget _baris(String l, String v, {bool tebal = false, Color? warna}) => ListTile(
        dense: true,
        title: Text(l),
        trailing: Text(v,
            style: TextStyle(
                fontWeight: tebal ? FontWeight.bold : null, color: warna, fontSize: tebal ? 16 : null)),
      );
}

// =====================================================
// TAB BAHAN
// =====================================================
class BahanTab extends StatefulWidget {
  final PosRepository repo;
  const BahanTab({super.key, required this.repo});
  @override
  State<BahanTab> createState() => _BahanTabState();
}

class _BahanTabState extends State<BahanTab> {
  late Future<List<Map<String, Object?>>> _f = widget.repo.daftarBahan(semua: true);
  void _refresh() => setState(() => _f = widget.repo.daftarBahan(semua: true));

  Future<void> _tambah() async {
    final nama = TextEditingController();
    final satuan = TextEditingController(text: 'pcs');
    final min = TextEditingController(text: '0');
    final beli = TextEditingController();
    final isi = TextEditingController();

    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Bahan baru'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: nama, decoration: const InputDecoration(labelText: 'Nama bahan')),
            TextField(
                controller: satuan,
                decoration: const InputDecoration(labelText: 'Satuan dasar (pcs, keping, bungkus, gram)')),
            TextField(
                controller: min,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Stok minimum')),
            const SizedBox(height: 8),
            const Text('Satuan beli (opsional)', style: TextStyle(fontWeight: FontWeight.bold)),
            TextField(controller: beli, decoration: const InputDecoration(labelText: 'Nama (dus, pack, ikat)')),
            TextField(
                controller: isi,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Isi per satuan beli (dalam satuan dasar)')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Simpan')),
        ],
      ),
    );
    if (ok != true || nama.text.trim().isEmpty) return;
    try {
      final id = await widget.repo.tambahBahan(
          nama: nama.text.trim(),
          satuanDasar: satuan.text.trim(),
          stokMinimum: double.tryParse(min.text.replaceAll(',', '.')) ?? 0);
      final isiVal = double.tryParse(isi.text.replaceAll(',', '.'));
      if (beli.text.trim().isNotEmpty && isiVal != null && isiVal > 0) {
        await widget.repo.tambahSatuanBeli(id, beli.text.trim(), isiVal);
      }
      _refresh();
    } catch (_) {
      if (mounted) snack(context, 'Nama bahan sudah ada');
    }
  }

  Future<void> _detail(Map<String, Object?> b) async {
    final id = b['id'] as int;
    final satuan = await widget.repo.satuanBeli(id);
    final min = TextEditingController(text: qtyFmt(n(b['stok_minimum'])));
    final namaS = TextEditingController();
    final isiS = TextEditingController();
    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (c) => Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.of(c).viewInsets.bottom + 16),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${b['nama']}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            Text('Stok ${qtyFmt(n(b['stok']))} ${b['satuan_dasar']} • modal ${rp(n(b['hpp_per_dasar']))}/${b['satuan_dasar']}'),
            const SizedBox(height: 8),
            const Text('Satuan beli & konversi', style: TextStyle(fontWeight: FontWeight.bold)),
            if (satuan.isEmpty) const Text('Belum ada.'),
            ...satuan.map((s) => Text('• 1 ${s['nama_satuan']} = ${qtyFmt(n(s['isi_dasar']))} ${b['satuan_dasar']}')),
            Row(children: [
              Expanded(child: TextField(controller: namaS, decoration: const InputDecoration(labelText: 'Satuan baru'))),
              const SizedBox(width: 8),
              Expanded(
                  child: TextField(
                      controller: isiS,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Isi'))),
              IconButton(
                icon: const Icon(Icons.add_circle),
                onPressed: () async {
                  final v = double.tryParse(isiS.text.replaceAll(',', '.'));
                  if (namaS.text.trim().isEmpty || v == null || v <= 0) return;
                  try {
                    await widget.repo.tambahSatuanBeli(id, namaS.text.trim(), v);
                    if (c.mounted) Navigator.pop(c);
                  } catch (_) {
                    if (c.mounted) snack(c, 'Satuan itu sudah ada');
                  }
                },
              ),
            ]),
            TextField(
                controller: min,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Stok minimum')),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () async {
                    await widget.repo.updateBahan(id, aktif: b['aktif'] != 1);
                    if (c.mounted) Navigator.pop(c);
                  },
                  child: Text(b['aktif'] == 1 ? 'Nonaktifkan' : 'Aktifkan'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  onPressed: () async {
                    await widget.repo.updateBahan(id,
                        stokMin: double.tryParse(min.text.replaceAll(',', '.')) ?? 0);
                    if (c.mounted) Navigator.pop(c);
                  },
                  child: const Text('Simpan'),
                ),
              ),
            ]),
          ]),
        ),
      ),
    );
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton:
          FloatingActionButton.extended(onPressed: _tambah, icon: const Icon(Icons.add), label: const Text('Bahan')),
      body: FutureBuilder<List<Map<String, Object?>>>(
        future: _f,
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final data = snap.data!;
          if (data.isEmpty) return const Center(child: Text('Belum ada bahan.'));
          return ListView(padding: const EdgeInsets.only(bottom: 88), children: data.map((b) {
            final aktif = b['aktif'] == 1;
            return ListTile(
              onTap: () => _detail(b),
              title: Text('${b['nama']}${aktif ? '' : ' (nonaktif)'}',
                  style: TextStyle(color: aktif ? null : Colors.grey)),
              subtitle: Text('Modal ${rp(n(b['hpp_per_dasar']))}/${b['satuan_dasar']}'),
              trailing: Text('${qtyFmt(n(b['stok']))} ${b['satuan_dasar']}',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
            );
          }).toList());
        },
      ),
    );
  }
}

// =====================================================
// TAB KULAK (PEMBELIAN)
// =====================================================
class _BarisKulak {
  int? bahanId;
  int? satuanId;
  final qty = TextEditingController();
  final harga = TextEditingController();
  List<Map<String, Object?>> satuanList = [];
}

class KulakTab extends StatefulWidget {
  final PosRepository repo;
  const KulakTab({super.key, required this.repo});
  @override
  State<KulakTab> createState() => _KulakTabState();
}

class _KulakTabState extends State<KulakTab> {
  late Future<List<Map<String, Object?>>> _bahan = widget.repo.daftarBahan();
  final _supplier = TextEditingController();
  final List<_BarisKulak> _baris = [_BarisKulak()];

  Future<void> _pilihBahan(_BarisKulak r, int id) async {
    r.bahanId = id;
    r.satuanList = await widget.repo.satuanBeli(id);
    r.satuanId = r.satuanList.isEmpty ? null : r.satuanList.first['id'] as int;
    setState(() {});
  }

  Future<void> _simpan() async {
    final items = <({int bahanId, int satuanBeliId, double qtyBeli, int hargaTotal})>[];
    for (final r in _baris) {
      final q = double.tryParse(r.qty.text.replaceAll(',', '.'));
      final h = int.tryParse(r.harga.text.replaceAll('.', ''));
      if (r.bahanId == null || r.satuanId == null || q == null || q <= 0 || h == null) {
        snack(context, 'Lengkapi semua baris (bahan, satuan beli, jumlah, harga)');
        return;
      }
      items.add((bahanId: r.bahanId!, satuanBeliId: r.satuanId!, qtyBeli: q, hargaTotal: h));
    }
    await widget.repo.catatPembelian(
        supplier: _supplier.text.trim().isEmpty ? null : _supplier.text.trim(), items: items);
    if (!mounted) return;
    snack(context, 'Pembelian tersimpan, stok & modal diperbarui');
    setState(() {
      _baris
        ..clear()
        ..add(_BarisKulak());
      _supplier.clear();
      _bahan = widget.repo.daftarBahan();
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Map<String, Object?>>>(
      future: _bahan,
      builder: (context, snap) {
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());
        final bahan = snap.data!;
        return ListView(padding: const EdgeInsets.all(12), children: [
          TextField(controller: _supplier, decoration: const InputDecoration(labelText: 'Supplier / toko (opsional)')),
          const SizedBox(height: 8),
          ..._baris.asMap().entries.map((e) {
            final r = e.value;
            return Card(
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(children: [
                  Row(children: [
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        value: r.bahanId,
                        hint: const Text('Pilih bahan'),
                        items: bahan
                            .map((b) => DropdownMenuItem(value: b['id'] as int, child: Text('${b['nama']}')))
                            .toList(),
                        onChanged: (v) => v == null ? null : _pilihBahan(r, v),
                      ),
                    ),
                    if (_baris.length > 1)
                      IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => setState(() => _baris.removeAt(e.key))),
                  ]),
                  if (r.bahanId != null && r.satuanList.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Text('Bahan ini belum punya satuan beli. Tambahkan di tab Bahan.',
                          style: TextStyle(color: Colors.red, fontSize: 12)),
                    ),
                  if (r.satuanList.isNotEmpty)
                    Row(children: [
                      Expanded(
                        child: TextField(
                          controller: r.qty,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(labelText: 'Jumlah'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: DropdownButtonFormField<int>(
                          value: r.satuanId,
                          items: r.satuanList
                              .map((s) => DropdownMenuItem(
                                  value: s['id'] as int,
                                  child: Text('${s['nama_satuan']} (${qtyFmt(n(s['isi_dasar']))})')))
                              .toList(),
                          onChanged: (v) => setState(() => r.satuanId = v),
                        ),
                      ),
                    ]),
                  if (r.satuanList.isNotEmpty)
                    TextField(
                      controller: r.harga,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Total harga baris ini (Rp)'),
                    ),
                ]),
              ),
            );
          }),
          TextButton.icon(
              onPressed: () => setState(() => _baris.add(_BarisKulak())),
              icon: const Icon(Icons.add),
              label: const Text('Tambah baris')),
          const SizedBox(height: 8),
          FilledButton(onPressed: _simpan, child: const Text('Simpan pembelian')),
        ]);
      },
    );
  }
}
