// manajemen_screen.dart — Tab: Menu (+ editor resep pecahan), Bahan (CRUD, satuan,
// pengaturan prasmanan, satuan beli), Kulak (pembelian), Audit (cek selisih stok & keuangan).
import 'package:flutter/material.dart';

import 'backup_screen.dart';
import 'helpers.dart';
import 'hpp_screen.dart';
import 'models.dart';
import 'pos_repository.dart';
import 'printer_screen.dart';
import 'variasi_manajemen_screen.dart';

double? _angka(String s) => double.tryParse(s.trim().replaceAll(',', '.'));
int? _bulat(String s) => int.tryParse(s.trim().replaceAll('.', ''));

class ManajemenScreen extends StatelessWidget {
  final PosRepository repo;
  const ManajemenScreen({super.key, required this.repo});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 7,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Kelola Menu & Bahan'),
          actions: [
            IconButton(
              icon: const Icon(Icons.backup_outlined),
              tooltip: 'Cadangan data',
              onPressed: () => Navigator.push(
                  context, MaterialPageRoute(builder: (_) => const BackupScreen())),
            ),
          ],
          bottom: const TabBar(isScrollable: true, tabs: [
            Tab(text: 'Menu'),
            Tab(text: 'Variasi'),
            Tab(text: 'HPP'),
            Tab(text: 'Bahan'),
            Tab(text: 'Kulak'),
            Tab(text: 'Audit'),
            Tab(text: 'Printer'),
          ]),
        ),
        body: TabBarView(children: [
          MenuTab(repo: repo),
          VariasiTab(repo: repo),
          HppTab(repo: repo),
          BahanTab(repo: repo),
          KulakTab(repo: repo),
          AuditTab(repo: repo),
          PrinterTab(repo: repo),
        ]),
      ),
    );
  }
}

// =====================================================================
// TAB MENU
// =====================================================================
class MenuTab extends StatefulWidget {
  final PosRepository repo;
  const MenuTab({super.key, required this.repo});
  @override
  State<MenuTab> createState() => _MenuTabState();
}

class _MenuTabState extends State<MenuTab> {
  late Future<List<Map<String, Object?>>> _f = widget.repo.daftarMenuLengkap();
  void _refresh() => setState(() => _f = widget.repo.daftarMenuLengkap());

  Future<void> _dialogMenu({Map<String, Object?>? sumber}) async {
    final nama = TextEditingController(text: sumber == null ? '' : '${sumber['nama']} (salinan)');
    final harga = TextEditingController(text: sumber == null ? '' : '${n(sumber['harga_jual']).toInt()}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(sumber == null ? 'Tambah menu' : 'Duplikat menu'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: nama, decoration: const InputDecoration(labelText: 'Nama menu')),
          TextField(
              controller: harga,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Harga jual (Rp)')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Simpan')),
        ],
      ),
    );
    final namaTxt = nama.text;
    final hargaVal = _bulat(harga.text) ?? 0;
    nama.dispose();
    harga.dispose();
    if (ok != true) return;
    try {
      final id = sumber == null
          ? await widget.repo.tambahMenu(namaTxt, hargaVal)
          : await widget.repo.duplikatMenu(sumber['id'] as int, namaTxt, hargaVal);
      if (!mounted) return;
      _refresh();
      await Navigator.push(context,
          MaterialPageRoute(builder: (_) => ResepEditorScreen(repo: widget.repo, menuId: id)));
      _refresh();
    } on PosException catch (e) {
      if (mounted) snack(context, e.pesan);
    }
  }

  Future<void> _ubahKategori(Map<String, Object?> m, List<Map<String, Object?>> semua) async {
    final c = TextEditingController(text: '${m['kategori'] ?? ''}');
    final saran = semua
        .map((e) => '${e['kategori'] ?? ''}'.trim())
        .where((k) => k.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text('Kategori "${m['nama']}"'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            TextField(controller: c, decoration: const InputDecoration(labelText: 'Kategori (Seblak, Minuman...)')),
            if (saran.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(spacing: 6, children: [
                for (final k in saran) ActionChip(label: Text(k), onPressed: () => setD(() => c.text = k)),
              ]),
            ],
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Simpan')),
          ],
        ),
      ),
    );
    final teks = c.text;
    WidgetsBinding.instance.addPostFrameCallback((_) => c.dispose());
    if (ok != true) return;
    try {
      await widget.repo.setKategoriMenu(m['id'] as int, teks);
      _refresh();
    } catch (e) {
      if (mounted) snack(context, 'Gagal: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _dialogMenu(),
        icon: const Icon(Icons.add),
        label: const Text('Menu'),
      ),
      body: FutureBuilder<List<Map<String, Object?>>>(
        future: _f,
        builder: (context, snap) {
          if (snap.hasError) return Center(child: Text('${snap.error}'));
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final data = snap.data!;
          return ListView(padding: const EdgeInsets.only(bottom: 90), children: data.map((m) {
            final aktif = m['aktif'] == 1;
            return ListTile(
              enabled: true,
              title: Text('${m['nama']}',
                  style: TextStyle(color: aktif ? null : Colors.grey, fontWeight: FontWeight.w600)),
              isThreeLine: true,
              subtitle: Text('Jual ${rp(n(m['harga_jual']))} • HPP bahan ${rp(n(m['hpp_bahan']))}\n'
                  'Kategori: ${'${m['kategori'] ?? ''}'.trim().isEmpty ? 'Lainnya' : m['kategori']}'),
              onTap: () async {
                await Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => ResepEditorScreen(repo: widget.repo, menuId: m['id'] as int)));
                _refresh();
              },
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(
                    tooltip: 'Kategori',
                    icon: const Icon(Icons.label_outline),
                    onPressed: () => _ubahKategori(m, data)),
                IconButton(
                    tooltip: 'Duplikat',
                    icon: const Icon(Icons.copy),
                    onPressed: () => _dialogMenu(sumber: m)),
                Switch(
                  value: aktif,
                  onChanged: (v) async {
                    await widget.repo.updateMenu(m['id'] as int, aktif: v);
                    _refresh();
                  },
                ),
              ]),
            );
          }).toList());
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------
class ResepEditorScreen extends StatefulWidget {
  final PosRepository repo;
  final int menuId;
  const ResepEditorScreen({super.key, required this.repo, required this.menuId});
  @override
  State<ResepEditorScreen> createState() => _ResepEditorScreenState();
}

class _ResepEditorScreenState extends State<ResepEditorScreen> {
  late Future<List<Object?>> _f = _muat();
  final _harga = TextEditingController();
  final _takaran = TextEditingController();
  int? _pilihBahan;

  Future<List<Object?>> _muat() async {
    final menu = await widget.repo.menuById(widget.menuId);
    final resep = await widget.repo.resepDetail(widget.menuId);
    final bahan = await widget.repo.daftarBahan();
    final oh = await widget.repo.overheadPerPorsi();
    _harga.text = '${n(menu?['harga_jual']).toInt()}';
    return [menu, resep, bahan, oh];
  }

  void _refresh() => setState(() => _f = _muat());

  @override
  void dispose() {
    _harga.dispose();
    _takaran.dispose();
    super.dispose();
  }

  Future<void> _aman(Future<void> Function() aksi) async {
    try {
      await aksi();
    } on PosException catch (e) {
      if (mounted) snack(context, e.pesan);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Object?>>(
      future: _f,
      builder: (context, snap) {
        if (snap.hasError) return Scaffold(appBar: AppBar(), body: Center(child: Text('${snap.error}')));
        if (!snap.hasData) {
          return Scaffold(appBar: AppBar(), body: const Center(child: CircularProgressIndicator()));
        }
        final menu = snap.data![0] as Map<String, Object?>?;
        final resep = snap.data![1] as List<Map<String, Object?>>;
        final bahan = snap.data![2] as List<Bahan>;
        final oh = snap.data![3] as double;
        final hpp = resep.fold<double>(0, (a, r) => a + n(r['biaya']));
        final harga = _bulat(_harga.text) ?? 0;

        return Scaffold(
          appBar: AppBar(title: Text('Resep: ${menu?['nama'] ?? ''}')),
          body: ListView(padding: const EdgeInsets.all(12), children: [
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _harga,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Harga jual (Rp)'),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => _aman(() async {
                  await widget.repo.updateMenu(widget.menuId, harga: harga);
                  if (mounted) snack(context, 'Harga disimpan');
                }),
                child: const Text('Simpan'),
              ),
            ]),
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('HPP bahan: ${rp(hpp)}'),
                  Text('Overhead / porsi: ${rp(oh)}'),
                  Text('Laba / porsi: ${rp(harga - hpp - oh)}',
                      style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: harga - hpp - oh >= 0 ? Colors.green : Colors.red)),
                ]),
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 12, bottom: 4),
              child: Text('Bahan resep (per 1 porsi)', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            if (resep.isEmpty) const Text('Belum ada bahan.'),
            ...resep.map((r) {
              final t = Takaran(r['qty_num'] as int, r['qty_den'] as int);
              return ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text('${r['nama']}'),
                subtitle: Text('$t ${r['satuan_dasar']} • biaya ${rp(n(r['biaya']))}'),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(icon: const Icon(Icons.edit), onPressed: () => _editTakaran(r, t)),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.red),
                    onPressed: () async {
                      await widget.repo.hapusResepItem(widget.menuId, r['bahan_id'] as int);
                      _refresh();
                    },
                  ),
                ]),
              );
            }),
            const Divider(height: 28),
            const Text('Tambah bahan ke resep', style: TextStyle(fontWeight: FontWeight.bold)),
            DropdownButtonFormField<int>(
              value: _pilihBahan,
              hint: const Text('Pilih bahan'),
              items: bahan
                  .map((b) => DropdownMenuItem(value: b.id, child: Text('${b.nama} (${b.satuanDasar})')))
                  .toList(),
              onChanged: (v) => setState(() => _pilihBahan = v),
            ),
            TextField(
              controller: _takaran,
              decoration: const InputDecoration(labelText: 'Takaran (mis. 1/3, 0.5, 2)'),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('Tambah'),
              onPressed: _pilihBahan == null
                  ? null
                  : () => _aman(() async {
                        await widget.repo.setResepItem(widget.menuId, _pilihBahan!, _takaran.text);
                        _takaran.clear();
                        _pilihBahan = null;
                        _refresh();
                      }),
            ),
          ]),
        );
      },
    );
  }

  Future<void> _editTakaran(Map<String, Object?> r, Takaran t) async {
    final c = TextEditingController(text: t.toString());
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Takaran ${r['nama']}'),
        content: TextField(controller: c, decoration: const InputDecoration(hintText: '1/3, 0.5, 2')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Simpan')),
        ],
      ),
    );
    final teks = c.text;
    c.dispose();
    if (ok != true) return;
    await _aman(() async {
      await widget.repo.setResepItem(widget.menuId, r['bahan_id'] as int, teks);
      _refresh();
    });
  }
}

// =====================================================================
// TAB BAHAN (tambah / ubah / hapus + satuan + prasmanan)
// =====================================================================
class BahanTab extends StatefulWidget {
  final PosRepository repo;
  const BahanTab({super.key, required this.repo});
  @override
  State<BahanTab> createState() => _BahanTabState();
}

class _BahanTabState extends State<BahanTab> {
  late Future<List<Bahan>> _f = widget.repo.daftarBahan(semua: true);
  String _cari = '';

  void _refresh() => setState(() => _f = widget.repo.daftarBahan(semua: true));

  Future<void> _aman(Future<void> Function() aksi) async {
    try {
      await aksi();
      _refresh();
    } on PosException catch (e) {
      if (mounted) snack(context, e.pesan);
    }
  }

  Future<void> _formBahan({Bahan? b}) async {
    final baru = b == null;
    final nama = TextEditingController(text: b?.nama ?? '');
    final stok = TextEditingController(text: b == null ? '' : fmtQty(b.stok));
    final stokMin = TextEditingController(text: b == null ? '' : fmtQty(b.stokMinimum));
    final hpp = TextEditingController(text: b == null ? '' : fmtQty(b.hppPerDasar));
    final hargaP = TextEditingController(text: b == null || b.hargaPrasmanan == 0 ? '' : '${b.hargaPrasmanan}');
    final qtyP = TextEditingController(text: fmtQty(b?.qtyPrasmanan ?? 1));
    var satuan = b?.satuanDasar ?? kSatuanDasar.first;
    var prasmanan = b?.bisaPrasmanan ?? false;
    final opsiSatuan = [...kSatuanDasar, if (!kSatuanDasar.contains(satuan)) satuan];

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(baru ? 'Tambah bahan' : 'Ubah bahan'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: nama, decoration: const InputDecoration(labelText: 'Nama bahan')),
              DropdownButtonFormField<String>(
                value: satuan,
                decoration: const InputDecoration(labelText: 'Satuan dasar'),
                items: opsiSatuan.map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
                onChanged: (v) => setD(() => satuan = v ?? satuan),
              ),
              TextField(
                controller: stok,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                    labelText: baru ? 'Stok awal ($satuan)' : 'Stok saat ini ($satuan) — ubah = koreksi'),
              ),
              TextField(
                controller: stokMin,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(labelText: 'Stok minimum ($satuan)'),
              ),
              TextField(
                controller: hpp,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(labelText: 'Modal (HPP) per $satuan (Rp)'),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Tersedia di Prasmanan'),
                value: prasmanan,
                onChanged: (v) => setD(() => prasmanan = v),
              ),
              if (prasmanan) ...[
                TextField(
                  controller: hargaP,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Harga jual per 1 pilihan (Rp)'),
                ),
                TextField(
                  controller: qtyP,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(labelText: 'Stok terpakai per 1 pilihan ($satuan)'),
                ),
              ],
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Simpan')),
          ],
        ),
      ),
    );

    final hasil = Bahan(
      id: b?.id,
      nama: nama.text,
      satuanDasar: satuan,
      stok: _angka(stok.text) ?? 0,
      stokMinimum: _angka(stokMin.text) ?? 0,
      hppPerDasar: _angka(hpp.text) ?? 0,
      aktif: b?.aktif ?? true,
      bisaPrasmanan: prasmanan,
      hargaPrasmanan: _bulat(hargaP.text) ?? 0,
      qtyPrasmanan: _angka(qtyP.text) ?? 1,
    );
    for (final c in [nama, stok, stokMin, hpp, hargaP, qtyP]) {
      c.dispose();
    }
    if (ok != true) return;
    await _aman(() async => widget.repo.simpanBahan(hasil));
  }

  Future<void> _hapus(Bahan b) async {
    final yakin = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Hapus ${b.nama}?'),
        content: const Text('Bahan yang sudah punya riwayat stok/transaksi hanya dinonaktifkan '
            '(riwayat tetap aman).'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Hapus')),
        ],
      ),
    );
    if (yakin != true) return;
    await _aman(() async {
      final r = await widget.repo.hapusBahan(b.id!);
      if (mounted) snack(context, 'Bahan $r');
    });
  }

  Future<void> _satuanBeli(Bahan b) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        final namaS = TextEditingController();
        final isi = TextEditingController();
        var daftar = widget.repo.satuanBeli(b.id!);
        return StatefulBuilder(
          builder: (ctx, setS) => Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.of(ctx).viewInsets.bottom + 16),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Satuan beli: ${b.nama}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              FutureBuilder<List<Map<String, Object?>>>(
                future: daftar,
                builder: (_, s) => Column(
                  children: (s.data ?? [])
                      .map((x) => ListTile(
                            dense: true,
                            title: Text('${x['nama_satuan']}'),
                            trailing: Text('= ${qtyFmt(n(x['isi_dasar']))} ${b.satuanDasar}'),
                          ))
                      .toList(),
                ),
              ),
              Row(children: [
                Expanded(
                    child: TextField(
                        controller: namaS,
                        decoration: const InputDecoration(labelText: 'Satuan (dus, pack, ikat)'))),
                const SizedBox(width: 8),
                Expanded(
                    child: TextField(
                        controller: isi,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: InputDecoration(labelText: 'Isi (${b.satuanDasar})'))),
              ]),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: () async {
                  try {
                    await widget.repo.tambahSatuanBeli(b.id!, namaS.text, _angka(isi.text) ?? 0);
                    namaS.clear();
                    isi.clear();
                    setS(() => daftar = widget.repo.satuanBeli(b.id!));
                  } on PosException catch (e) {
                    if (ctx.mounted) snack(ctx, e.pesan);
                  }
                },
                child: const Text('Tambah satuan beli'),
              ),
            ]),
          ),
        );
      },
    );
  }

  Future<void> _biayaDasar() async {
    final awal = await widget.repo.biayaDasarPrasmanan();
    final c = TextEditingController(text: '$awal');
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Biaya dasar prasmanan'),
        content: TextField(
          controller: c,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
              labelText: 'Rp per porsi (bumbu + kuah)', helperText: 'Ditambahkan ke total topping. Isi 0 jika tidak ada.'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Simpan')),
        ],
      ),
    );
    final v = _bulat(c.text) ?? 0;
    c.dispose();
    if (ok == true) {
      await widget.repo.setBiayaDasarPrasmanan(v < 0 ? 0 : v);
      if (mounted) snack(context, 'Biaya dasar disimpan');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _formBahan(),
        icon: const Icon(Icons.add),
        label: const Text('Bahan'),
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(children: [
            Expanded(
              child: TextField(
                decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Cari bahan', isDense: true),
                onChanged: (v) => setState(() => _cari = v.toLowerCase()),
              ),
            ),
            IconButton(
                tooltip: 'Biaya dasar prasmanan', icon: const Icon(Icons.tune), onPressed: _biayaDasar),
          ]),
        ),
        Expanded(
          child: FutureBuilder<List<Bahan>>(
            future: _f,
            builder: (context, snap) {
              if (snap.hasError) return Center(child: Text('${snap.error}'));
              if (!snap.hasData) return const Center(child: CircularProgressIndicator());
              final data = snap.data!.where((b) => b.nama.toLowerCase().contains(_cari)).toList();
              return ListView(padding: const EdgeInsets.only(bottom: 90), children: data.map((b) {
                return ListTile(
                  onTap: () => _formBahan(b: b),
                  title: Text(b.nama,
                      style: TextStyle(color: b.aktif ? null : Colors.grey, fontWeight: FontWeight.w600)),
                  subtitle: Text(
                      'Stok ${fmtQty(b.stok)} ${b.satuanDasar} • min ${fmtQty(b.stokMinimum)} • modal ${rp(b.hppPerDasar)}'
                      '${b.bisaPrasmanan ? '\nPrasmanan ${rp(b.hargaPrasmanan)} / pilihan (${fmtQty(b.qtyPrasmanan)} ${b.satuanDasar})' : ''}'
                      '${b.aktif ? '' : '\n(nonaktif)'}'),
                  isThreeLine: b.bisaPrasmanan || !b.aktif,
                  leading: Icon(b.stokRendah && b.aktif ? Icons.warning_amber : Icons.inventory_2,
                      color: b.stokRendah && b.aktif ? Colors.red : null),
                  trailing: PopupMenuButton<String>(
                    onSelected: (v) {
                      if (v == 'ubah') _formBahan(b: b);
                      if (v == 'satuan') _satuanBeli(b);
                      if (v == 'aktif') {
                        _aman(() async {
                          b.aktif = !b.aktif;
                          await widget.repo.simpanBahan(b);
                        });
                      }
                      if (v == 'hapus') _hapus(b);
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 'ubah', child: Text('Ubah')),
                      const PopupMenuItem(value: 'satuan', child: Text('Satuan beli')),
                      PopupMenuItem(value: 'aktif', child: Text(b.aktif ? 'Nonaktifkan' : 'Aktifkan')),
                      const PopupMenuItem(value: 'hapus', child: Text('Hapus')),
                    ],
                  ),
                );
              }).toList());
            },
          ),
        ),
      ]),
    );
  }
}

// =====================================================================
// TAB KULAK (PEMBELIAN)
// =====================================================================
class _BarisKulak {
  Bahan? bahan;
  int satuanId = 0; // 0 = satuan dasar
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
  late Future<List<Bahan>> _bahan = widget.repo.daftarBahan();
  final _supplier = TextEditingController();
  final List<_BarisKulak> _baris = [_BarisKulak()];

  Future<void> _pilihBahan(_BarisKulak r, Bahan b) async {
    r.bahan = b;
    r.satuanList = await widget.repo.satuanBeli(b.id!);
    r.satuanId = 0;
    if (mounted) setState(() {});
  }

  Future<void> _simpan() async {
    final items = <ItemBeli>[];
    for (final r in _baris) {
      final q = _angka(r.qty.text);
      final h = _bulat(r.harga.text);
      if (r.bahan == null || q == null || q <= 0 || h == null) {
        snack(context, 'Lengkapi semua baris (bahan, jumlah, harga)');
        return;
      }
      items.add((
        bahanId: r.bahan!.id!,
        satuanBeliId: r.satuanId == 0 ? null : r.satuanId,
        qtyBeli: q,
        hargaTotal: h,
      ));
    }
    try {
      await widget.repo.catatPembelian(
          supplier: _supplier.text.trim().isEmpty ? null : _supplier.text.trim(), items: items);
    } on PosException catch (e) {
      if (mounted) snack(context, e.pesan);
      return;
    }
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
    return FutureBuilder<List<Bahan>>(
      future: _bahan,
      builder: (context, snap) {
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());
        final bahan = snap.data!;
        return ListView(padding: const EdgeInsets.all(12), children: [
          TextField(
              controller: _supplier,
              decoration: const InputDecoration(labelText: 'Supplier / toko (opsional)')),
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
                        value: r.bahan?.id,
                        hint: const Text('Pilih bahan'),
                        items: bahan.map((b) => DropdownMenuItem(value: b.id, child: Text(b.nama))).toList(),
                        onChanged: (v) {
                          if (v == null) return;
                          _pilihBahan(r, bahan.firstWhere((b) => b.id == v));
                        },
                      ),
                    ),
                    if (_baris.length > 1)
                      IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => setState(() => _baris.removeAt(e.key))),
                  ]),
                  if (r.bahan != null) ...[
                    Row(children: [
                      Expanded(
                        child: TextField(
                          controller: r.qty,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: const InputDecoration(labelText: 'Jumlah'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: DropdownButtonFormField<int>(
                          value: r.satuanId,
                          items: [
                            DropdownMenuItem(value: 0, child: Text('${r.bahan!.satuanDasar} (dasar)')),
                            ...r.satuanList.map((s) => DropdownMenuItem(
                                value: s['id'] as int,
                                child: Text('${s['nama_satuan']} (${qtyFmt(n(s['isi_dasar']))})'))),
                          ],
                          onChanged: (v) => setState(() => r.satuanId = v ?? 0),
                        ),
                      ),
                    ]),
                    TextField(
                      controller: r.harga,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Total harga baris ini (Rp)'),
                    ),
                  ],
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

// =====================================================================
// TAB AUDIT — buktikan tidak ada selisih stok & keuangan
// =====================================================================
class AuditTab extends StatefulWidget {
  final PosRepository repo;
  const AuditTab({super.key, required this.repo});
  @override
  State<AuditTab> createState() => _AuditTabState();
}

class _AuditTabState extends State<AuditTab> {
  late Future<List<Object>> _f = _periksa();
  DateTime _tgl = DateTime.now();

  String get _tglStr {
    String dua(int v) => v.toString().padLeft(2, '0');
    return '${_tgl.year}-${dua(_tgl.month)}-${dua(_tgl.day)}';
  }

  Future<List<Object>> _periksa() async {
    final stok = await widget.repo.auditStok();
    final uang = await widget.repo.cekKeuanganHarian(_tglStr);
    return [stok, uang];
  }

  void _ulang() => setState(() => _f = _periksa());

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Object>>(
      future: _f,
      builder: (context, snap) {
        if (snap.hasError) return Center(child: Text('${snap.error}'));
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());
        final stok = snap.data![0] as List<SelisihStok>;
        final uang = snap.data![1] as KeuanganHarian;
        return RefreshIndicator(
          onRefresh: () async => _ulang(),
          child: ListView(padding: const EdgeInsets.all(12), children: [
            Row(children: [
              Expanded(
                  child: Text('Keuangan tanggal $_tglStr',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
              TextButton.icon(
                icon: const Icon(Icons.calendar_today, size: 16),
                label: const Text('Ganti'),
                onPressed: () async {
                  final d = await showDatePicker(
                      context: context,
                      initialDate: _tgl,
                      firstDate: DateTime(2023),
                      lastDate: DateTime.now());
                  if (d != null) {
                    _tgl = d;
                    _ulang();
                  }
                },
              ),
            ]),
            Card(
              color: uang.cocok ? Colors.green.shade50 : Colors.red.shade50,
              child: ListTile(
                leading: Icon(uang.cocok ? Icons.check_circle : Icons.error,
                    color: uang.cocok ? Colors.green : Colors.red),
                title: Text(uang.cocok ? 'Omzet & HPP cocok' : 'Ada selisih keuangan!'),
                subtitle: Text('Omzet nota ${rp(uang.omzetHeader)} • omzet rincian ${rp(uang.omzetItem)}\n'
                    'HPP nota ${rp(uang.hppHeader)} • HPP rincian ${rp(uang.hppItem)}'),
                isThreeLine: true,
              ),
            ),
            const SizedBox(height: 12),
            const Text('Stok vs buku besar mutasi',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            if (stok.isEmpty)
              Card(
                color: Colors.green.shade50,
                child: const ListTile(
                    leading: Icon(Icons.check_circle, color: Colors.green),
                    title: Text('Semua stok cocok dengan buku besar')),
              ),
            ...stok.map((s) => Card(
                  color: Colors.red.shade50,
                  child: ListTile(
                    title: Text(s.nama),
                    subtitle: Text('Stok ${fmtQty(s.stok)} • buku besar ${fmtQty(s.ledger)} ${s.satuan}\n'
                        'Selisih ${fmtQty(s.selisih)} ${s.satuan}'),
                    isThreeLine: true,
                    trailing: TextButton(
                      onPressed: () async {
                        await widget.repo.sinkronkanLedger(s.bahanId);
                        _ulang();
                      },
                      child: const Text('Sinkronkan'),
                    ),
                  ),
                )),
            if (stok.isNotEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                    'Selisih pada data lama biasanya karena stok awal dimasukkan sebelum buku besar ada. '
                    '"Sinkronkan" mencatat koreksi di buku besar tanpa mengubah stok.',
                    style: TextStyle(fontSize: 12)),
              ),
          ]),
        );
      },
    );
  }
}
