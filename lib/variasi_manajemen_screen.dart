// variasi_manajemen_screen.dart — tab "Variasi" di Kelola: CRUD kelompok & opsi variasi,
// aturan pilih (wajib / minimal / maksimal), harga tambahan, efek stok, dan relasi ke menu.
import 'package:flutter/material.dart';

import 'helpers.dart';
import 'pos_repository.dart';
import 'variasi_models.dart';

double? _angka(String s) => double.tryParse(s.trim().replaceAll(',', '.'));
int? _bulat(String s) => int.tryParse(s.trim().replaceAll('.', ''));

// =============================================================== TAB VARIASI

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

class VariasiTab extends StatefulWidget {
  final PosRepository repo;
  const VariasiTab({super.key, required this.repo});
  @override
  State<VariasiTab> createState() => _VariasiTabState();
}

class _VariasiTabState extends State<VariasiTab> {
  PosRepository get _repo => widget.repo;
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
    final minC = TextEditingController(text: g == null ? '1' : '${g.minPilih < 1 ? 1 : g.minPilih}');
    final maksC = TextEditingController(text: g == null ? '1' : '${g.maksPilih}');
    var wajib = g?.wajib ?? false;
    var aktif = g?.aktif ?? true;
    var tipe = g?.tipe ?? kVarRadio;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(g == null ? 'Tambah kelompok variasi' : 'Ubah kelompok variasi'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              TextField(
                  controller: nama,
                  decoration: const InputDecoration(labelText: 'Nama (Level Pedas, Topping, Suhu...)')),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: tipe,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Tipe tampilan di kasir'),
                items: const [
                  DropdownMenuItem(value: kVarRadio, child: Text('Radio (pilih satu)')),
                  DropdownMenuItem(value: kVarTeks, child: Text('Teks (ketik bebas)')),
                  DropdownMenuItem(value: kVarBanyak, child: Text('Banyak item (tombol − / +)')),
                ],
                onChanged: (v) => setD(() {
                  tipe = v ?? kVarRadio;
                  // Banyak item: default tanpa batas bila sebelumnya "pilih satu".
                  if (tipe == kVarBanyak && (_bulat(maksC.text) ?? 1) == 1) maksC.text = '0';
                }),
              ),
              SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Wajib diisi (Required)'),
                  subtitle: const Text('Mati = opsional'),
                  value: wajib,
                  onChanged: (v) => setD(() => wajib = v)),
              if (wajib && tipe == kVarBanyak)
                TextField(
                    controller: minC,
                    keyboardType: TextInputType.number,
                    onChanged: (_) => setD(() {}),
                    decoration: const InputDecoration(labelText: 'Minimal pilihan (min_select)')),
              if (tipe == kVarBanyak)
                TextField(
                    controller: maksC,
                    keyboardType: TextInputType.number,
                    onChanged: (_) => setD(() {}),
                    decoration: const InputDecoration(
                        labelText: 'Maksimal total item (max_select)',
                        helperText:
                            'Jumlah semua opsi digabung, mis. 5 = boleh sosis×2 + tofu×3 • 0 = tanpa batas')),
              const SizedBox(height: 8),
              Text(
                tipe == kVarTeks
                    ? 'Tampil di kasir: kolom teks (${wajib ? 'wajib diisi' : 'boleh kosong'})'
                    : tipe == kVarRadio
                        ? 'Tampil di kasir: ${aturanVariasi(wajib: wajib, min: 1, maks: 1)}'
                        : 'Tampil di kasir: ${aturanVariasi(wajib: wajib, min: _bulat(minC.text) ?? 1, maks: _bulat(maksC.text) ?? 0)}',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
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
    final minimal = _bulat(minC.text) ?? 1;
    final maksimal = _bulat(maksC.text);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      nama.dispose();
      minC.dispose();
      maksC.dispose();
    });
    if (ok != true) return;
    if (tipe == kVarBanyak && (maksimal == null || maksimal < 0)) {
      if (mounted) snack(context, 'Isi maksimal item (0 = tanpa batas)');
      return;
    }
    await _aman(() async {
      await _repo.simpanGrupVariasi(
        id: g?.id,
        nama: namaTxt,
        wajib: wajib,
        minPilih: wajib ? (tipe == kVarBanyak ? minimal : 1) : 0,
        maksPilih: maksimal ?? 1,
        aktif: aktif,
        tipe: tipe,
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
    String katDari(Map<String, Object?> m) => (m['kategori'] as String?) ?? 'Tanpa kategori';
    final kategoriList = {for (final m in daftar) katDari(m)}.toList()..sort();
    List<int> idsKategori(String k) => [
          for (final m in daftar)
            if (katDari(m) == k) m['id'] as int,
        ];
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
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Wrap(spacing: 6, runSpacing: 0, children: [
                  for (final k in kategoriList)
                    FilterChip(
                      label: Text('Semua $k'),
                      selected: idsKategori(k).every(dipilih.contains),
                      onSelected: (v) => setD(() {
                        if (v) {
                          dipilih.addAll(idsKategori(k));
                        } else {
                          dipilih.removeAll(idsKategori(k));
                        }
                      }),
                    ),
                ]),
              ),
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
                  subtitle: Text(g.isTeks
                      ? '${g.keterangan} • ${g.menuIds.length} menu'
                      : '${g.keterangan} • ${g.opsi.length} opsi • ${g.menuIds.length} menu'),
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
                        if (!g.isTeks)
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
