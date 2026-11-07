// variasi_manajemen_screen.dart — kelola variasi menu (CRUD) + kategori menu.
// Buka dari halaman Kelola:
//   Navigator.push(context, MaterialPageRoute(builder: (_) => const VariasiManajemenScreen()));
import 'package:flutter/material.dart';

import 'helpers.dart';
import 'pos_repository.dart';
import 'variasi_models.dart';

double? _angka(String s) => double.tryParse(s.trim().replaceAll(',', '.'));
int? _bulat(String s) => int.tryParse(s.trim().replaceAll('.', ''));

class VariasiManajemenScreen extends StatelessWidget {
  const VariasiManajemenScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Variasi menu'),
          bottom: const TabBar(tabs: [Tab(text: 'Variasi'), Tab(text: 'Kategori menu')]),
        ),
        body: const TabBarView(children: [_VariasiTab(), _KategoriTab()]),
      ),
    );
  }
}

// =============================================================== TAB VARIASI

/// Tab "Variasi" di Kelola (dipakai manajemen_screen.dart).
class VariasiTab extends StatelessWidget {
  final PosRepository repo;
  const VariasiTab({super.key, required this.repo});
  @override
  Widget build(BuildContext context) => const _VariasiTab();
}

class _DataVariasi {
  final List<VariasiGrup> grup;
  final List<Map<String, Object?>> menus;
  final List<Map<String, Object?>> bahan;
  const _DataVariasi(this.grup, this.menus, this.bahan);
}

class _BarisBahan {
  int? bahanId;
  final TextEditingController qty;
  _BarisBahan({this.bahanId, String qtyAwal = ''}) : qty = TextEditingController(text: qtyAwal);
}

class _VariasiTab extends StatefulWidget {
  const _VariasiTab();
  @override
  State<_VariasiTab> createState() => _VariasiTabState();
}

class _VariasiTabState extends State<_VariasiTab> {
  final _repo = PosRepository();
  late Future<_DataVariasi> _f = _muat();

  Future<_DataVariasi> _muat() async => _DataVariasi(
        await _repo.daftarGrupVariasi(),
        await _repo.daftarMenuKategori(),
        await _repo.daftarBahanRingkas(),
      );

  void _refresh() => setState(() => _f = _muat());

  Future<void> _aman(Future<void> Function() aksi, {String? pesan}) async {
    try {
      await aksi();
      if (pesan != null && mounted) snack(context, pesan);
      _refresh();
    } on PosException catch (e) {
      if (mounted) snack(context, e.pesan);
    } catch (e) {
      if (mounted) snack(context, 'Gagal: $e');
    }
  }

  Future<bool> _konfirmasi(String judul, String isi, String tombol) async {
    final ya = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(judul),
        content: Text(isi),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tombol)),
        ],
      ),
    );
    return ya == true;
  }

  // ------------------------------------------------------------ form kelompok

  Future<void> _formGrup({VariasiGrup? g}) async {
    final nama = TextEditingController(text: g?.nama ?? '');
    final maks = TextEditingController(text: (g != null && g.maksPilih > 1) ? '${g.maksPilih}' : '2');
    var wajib = g?.wajib ?? false;
    var aktif = g?.aktif ?? true;
    // 1 = pilih satu, 2 = banyak dengan batas, 0 = banyak tanpa batas
    var mode = g == null ? 1 : (g.maksPilih == 1 ? 1 : (g.maksPilih == 0 ? 0 : 2));

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(g == null ? 'Tambah kelompok variasi' : 'Ubah kelompok variasi'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                  controller: nama,
                  decoration: const InputDecoration(labelText: 'Nama (Level Pedas, Topping, Suhu...)')),
              const SizedBox(height: 8),
              DropdownButtonFormField<int>(
                value: mode,
                decoration: const InputDecoration(labelText: 'Cara memilih'),
                items: const [
                  DropdownMenuItem(value: 1, child: Text('Pilih satu saja')),
                  DropdownMenuItem(value: 2, child: Text('Boleh banyak (ada batas)')),
                  DropdownMenuItem(value: 0, child: Text('Boleh banyak (tanpa batas)')),
                ],
                onChanged: (v) => setD(() => mode = v ?? mode),
              ),
              if (mode == 2)
                TextField(
                    controller: maks,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Maksimal pilihan (min. 2)')),
              SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Wajib dipilih'),
                  value: wajib,
                  onChanged: (v) => setD(() => wajib = v)),
              SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Aktif'),
                  value: aktif,
                  onChanged: (v) => setD(() => aktif = v)),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Simpan')),
          ],
        ),
      ),
    );
    final namaTxt = nama.text;
    final batas = _bulat(maks.text) ?? 0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      nama.dispose();
      maks.dispose();
    });
    if (ok != true) return;
    if (mode == 2 && batas < 2) {
      if (mounted) snack(context, 'Maksimal pilihan minimal 2');
      return;
    }
    await _aman(() async {
      await _repo.simpanGrupVariasi(
        id: g?.id,
        nama: namaTxt,
        wajib: wajib,
        maksPilih: mode == 1 ? 1 : (mode == 0 ? 0 : batas),
        aktif: aktif,
      );
    });
  }

  // ------------------------------------------------------------ form opsi

  Future<void> _formOpsi(VariasiGrup g, List<Map<String, Object?>> bahan, {VariasiOpsi? o}) async {
    final nama = TextEditingController(text: o?.nama ?? '');
    final harga = TextEditingController(text: o == null ? '0' : '${o.hargaTambah}');
    var aktif = o?.aktif ?? true;
    final baris = <_BarisBahan>[
      for (final b in o?.bahan ?? const <VariasiBahan>[])
        _BarisBahan(bahanId: b.bahanId, qtyAwal: '${b.qtyDasar}'.replaceAll(RegExp(r'\.0$'), '')),
    ];

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(o == null ? 'Tambah opsi di "${g.nama}"' : 'Ubah opsi'),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(controller: nama, decoration: const InputDecoration(labelText: 'Nama opsi')),
                TextField(
                    controller: harga,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Harga tambahan (Rp)')),
                SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Aktif'),
                    value: aktif,
                    onChanged: (v) => setD(() => aktif = v)),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Bahan yang ikut terpotong (opsional, per porsi)',
                      style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                ),
                for (final r in baris)
                  Row(children: [
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        value: r.bahanId,
                        isExpanded: true,
                        hint: const Text('Bahan'),
                        items: [
                          for (final b in bahan)
                            DropdownMenuItem(
                                value: b['id'] as int,
                                child: Text('${b['nama']} (${b['satuan_dasar']})',
                                    overflow: TextOverflow.ellipsis)),
                        ],
                        onChanged: (v) => setD(() => r.bahanId = v),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 70,
                      child: TextField(
                          controller: r.qty,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: const InputDecoration(hintText: 'Jumlah')),
                    ),
                    IconButton(
                        icon: const Icon(Icons.close, size: 20),
                        onPressed: () => setD(() => baris.remove(r))),
                  ]),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                      onPressed: () => setD(() => baris.add(_BarisBahan())),
                      icon: const Icon(Icons.add),
                      label: const Text('Tambah bahan')),
                ),
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Simpan')),
          ],
        ),
      ),
    );

    final namaTxt = nama.text;
    final hargaTambah = _bulat(harga.text) ?? -1;
    final bahanOpsi = <VariasiBahan>[];
    String? salah;
    for (final r in baris) {
      final q = _angka(r.qty.text);
      if (r.bahanId == null && r.qty.text.trim().isEmpty) continue;
      if (r.bahanId == null || q == null || q <= 0) {
        salah = 'Lengkapi bahan dan jumlahnya, atau hapus barisnya';
        break;
      }
      bahanOpsi.add(VariasiBahan(bahanId: r.bahanId!, qtyDasar: q));
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      nama.dispose();
      harga.dispose();
      for (final r in baris) {
        r.qty.dispose();
      }
    });
    if (ok != true) return;
    if (salah != null) {
      if (mounted) snack(context, salah);
      return;
    }
    await _aman(() async {
      await _repo.simpanOpsiVariasi(
        id: o?.id,
        grupId: g.id,
        nama: namaTxt,
        hargaTambah: hargaTambah,
        aktif: aktif,
        bahan: bahanOpsi,
      );
    });
  }

  // ------------------------------------------------------------ relasi menu

  Future<void> _aturMenu(VariasiGrup g, List<Map<String, Object?>> menus) async {
    final dipilih = g.menuIds.toSet();
    final daftar = menus.where((m) => m['aktif'] == 1 || dipilih.contains(m['id'] as int)).toList();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text('"${g.nama}" berlaku di menu:'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(shrinkWrap: true, children: [
              Row(children: [
                TextButton(
                    onPressed: () => setD(() => dipilih.addAll(daftar.map((m) => m['id'] as int))),
                    child: const Text('Pilih semua')),
                TextButton(onPressed: () => setD(dipilih.clear), child: const Text('Kosongkan')),
              ]),
              for (final m in daftar)
                CheckboxListTile(
                  dense: true,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text('${m['nama']}'),
                  value: dipilih.contains(m['id'] as int),
                  onChanged: (v) => setD(() {
                    if (v == true) {
                      dipilih.add(m['id'] as int);
                    } else {
                      dipilih.remove(m['id'] as int);
                    }
                  }),
                ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Simpan')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    await _aman(() => _repo.setMenuUntukGrup(g.id, dipilih.toList()), pesan: 'Menu diperbarui');
  }

  // ------------------------------------------------------------ tampilan

  String _ringkasBahan(VariasiOpsi o) =>
      o.bahan.map((b) => '${b.nama} ${qtyFmt(b.qtyDasar)} ${b.satuan}').join(', ');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _formGrup(),
        icon: const Icon(Icons.add),
        label: const Text('Kelompok'),
      ),
      body: FutureBuilder<_DataVariasi>(
        future: _f,
        builder: (context, snap) {
          if (snap.hasError) return Center(child: Text('${snap.error}'));
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final d = snap.data!;
          if (d.grup.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Text(
                      'Belum ada variasi.\nTekan "Kelompok" untuk membuat, misalnya "Level Pedas", '
                      'lalu tambahkan opsinya dan pasang ke menu.',
                      textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    icon: const Icon(Icons.auto_fix_high),
                    label: const Text('Buat variasi standar seblak'),
                    onPressed: () => _aman(() async {
                      final n = await _repo.buatVariasiAwal();
                      if (mounted) snack(context, '$n kelompok dibuat: Level Pedas, Kuah, Rasa, Topping');
                    }),
                  ),
                ]),
              ),
            );
          }
          return ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 90), children: [
            for (final g in d.grup)
              Card(
                child: ExpansionTile(
                  title: Text(g.nama,
                      style: TextStyle(fontWeight: FontWeight.bold, color: g.aktif ? null : Colors.grey)),
                  subtitle: Text('${g.keterangan} • ${g.opsi.length} opsi • ${g.menuIds.length} menu'),
                  children: [
                    for (final o in g.opsi)
                      ListTile(
                        dense: true,
                        title: Text(o.nama, style: TextStyle(color: o.aktif ? null : Colors.grey)),
                        subtitle: Text([
                          o.hargaTambah > 0 ? '+${rp(o.hargaTambah)}' : 'Gratis',
                          if (o.bahan.isNotEmpty) 'Potong: ${_ringkasBahan(o)}',
                        ].join(' • ')),
                        onTap: () => _formOpsi(g, d.bahan, o: o),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline, color: Colors.red),
                          onPressed: () async {
                            if (await _konfirmasi('Hapus opsi?', '"${o.nama}" akan dihapus. Nota lama tetap utuh.', 'Hapus')) {
                              await _aman(() => _repo.hapusOpsiVariasi(o.id));
                            }
                          },
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                      child: Wrap(spacing: 4, children: [
                        TextButton.icon(
                            onPressed: () => _formOpsi(g, d.bahan),
                            icon: const Icon(Icons.add),
                            label: const Text('Opsi')),
                        TextButton.icon(
                            onPressed: () => _aturMenu(g, d.menus),
                            icon: const Icon(Icons.link),
                            label: const Text('Atur menu')),
                        TextButton.icon(
                            onPressed: () => _formGrup(g: g),
                            icon: const Icon(Icons.edit_outlined),
                            label: const Text('Ubah')),
                        TextButton.icon(
                          onPressed: () async {
                            if (await _konfirmasi('Hapus kelompok?',
                                '"${g.nama}" beserta semua opsinya akan dihapus. Nota lama tetap utuh.', 'Hapus')) {
                              await _aman(() => _repo.hapusGrupVariasi(g.id));
                            }
                          },
                          icon: const Icon(Icons.delete_outline, color: Colors.red),
                          label: const Text('Hapus', style: TextStyle(color: Colors.red)),
                        ),
                      ]),
                    ),
                  ],
                ),
              ),
          ]);
        },
      ),
    );
  }
}

// =============================================================== TAB KATEGORI MENU

class _KategoriTab extends StatefulWidget {
  const _KategoriTab();
  @override
  State<_KategoriTab> createState() => _KategoriTabState();
}

class _KategoriTabState extends State<_KategoriTab> {
  final _repo = PosRepository();
  late Future<List<Map<String, Object?>>> _f = _repo.daftarMenuKategori();

  void _refresh() => setState(() => _f = _repo.daftarMenuKategori());

  Future<void> _ubah(Map<String, Object?> m, List<String> saran) async {
    final c = TextEditingController(text: '${m['kategori'] ?? ''}');
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
                for (final s in saran)
                  ActionChip(label: Text(s), onPressed: () => setD(() => c.text = s)),
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
      await _repo.setKategoriMenu(m['id'] as int, teks);
      _refresh();
    } catch (e) {
      if (mounted) snack(context, 'Gagal: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Map<String, Object?>>>(
      future: _f,
      builder: (context, snap) {
        if (snap.hasError) return Center(child: Text('${snap.error}'));
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());
        final menus = snap.data!;
        final saran = menus
            .map((m) => '${m['kategori'] ?? ''}'.trim())
            .where((k) => k.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
        return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text('Kategori dipakai untuk memfilter ringkasan di Dashboard. '
                'Menu tanpa kategori masuk "Lainnya".',
                style: TextStyle(fontSize: 12)),
          ),
          for (final m in menus)
            ListTile(
              dense: true,
              title: Text('${m['nama']}', style: TextStyle(color: m['aktif'] == 1 ? null : Colors.grey)),
              subtitle: Text('${m['kategori'] ?? ''}'.trim().isEmpty ? 'Lainnya (belum diatur)' : '${m['kategori']}'),
              trailing: const Icon(Icons.edit_outlined, size: 20),
              onTap: () => _ubah(m, saran),
            ),
        ]);
      },
    );
  }
}
