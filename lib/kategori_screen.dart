// kategori_screen.dart — Kelola > Kategori.
// Kategori mengelompokkan menu di Kasir (Seblak, Minuman, Es, Jajanan, dst).
// Bebas ditambah, diubah namanya, diurutkan, atau dihapus (menu tidak ikut terhapus).
import 'package:flutter/material.dart';

import 'helpers.dart';
import 'pos_repository.dart';

// =====================================================================
// Pemilih kategori (dipakai di form menu): pilih yang ada atau buat baru.
// =====================================================================
class KategoriPicker extends StatefulWidget {
  final List<String> daftar;
  final String? awal;
  final ValueChanged<String?> onChanged;
  const KategoriPicker({super.key, required this.daftar, required this.awal, required this.onChanged});

  @override
  State<KategoriPicker> createState() => _KategoriPickerState();
}

class _KategoriPickerState extends State<KategoriPicker> {
  static const String _tanpa = '__tanpa__';
  static const String _baru = '__baru__';
  late String _sel;
  final _ctl = TextEditingController();

  @override
  void initState() {
    super.initState();
    final a = (widget.awal ?? '').trim();
    if (a.isEmpty) {
      _sel = _tanpa;
    } else {
      final cocok = widget.daftar.where((k) => k.toLowerCase() == a.toLowerCase());
      if (cocok.isNotEmpty) {
        _sel = cocok.first;
      } else {
        _sel = _baru;
        _ctl.text = a;
      }
    }
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  String? get _nilai {
    if (_sel == _tanpa) return null;
    if (_sel == _baru) {
      final t = _ctl.text.trim();
      return t.isEmpty ? null : t;
    }
    return _sel;
  }

  @override
  Widget build(BuildContext context) {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      DropdownButtonFormField<String>(
        value: _sel,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Kategori'),
        items: [
          const DropdownMenuItem(value: _tanpa, child: Text('Tanpa kategori (Lainnya)')),
          for (final k in widget.daftar) DropdownMenuItem(value: k, child: Text(k)),
          const DropdownMenuItem(value: _baru, child: Text('+ Kategori baru...')),
        ],
        onChanged: (v) {
          setState(() => _sel = v ?? _sel);
          widget.onChanged(_nilai);
        },
      ),
      if (_sel == _baru)
        TextField(
          controller: _ctl,
          decoration: const InputDecoration(labelText: 'Nama kategori baru (Minuman, Es, Jajanan...)'),
          onChanged: (_) => widget.onChanged(_nilai),
        ),
    ]);
  }
}

// =====================================================================
// TAB KATEGORI
// =====================================================================
class KategoriTab extends StatefulWidget {
  final PosRepository repo;
  const KategoriTab({super.key, required this.repo});
  @override
  State<KategoriTab> createState() => _KategoriTabState();
}

class _KategoriTabState extends State<KategoriTab> {
  late Future<List<Map<String, Object?>>> _f = widget.repo.daftarKategori();

  void _refresh() => setState(() => _f = widget.repo.daftarKategori());

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

  Future<void> _form({Map<String, Object?>? k}) async {
    final nama = TextEditingController(text: '${k?['nama'] ?? ''}');
    var opsiSeblak = (k?['opsi_seblak'] ?? 0) == 1;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(k == null ? 'Tambah kategori' : 'Ubah kategori'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              TextField(
                controller: nama,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Nama kategori (Seblak, Minuman, Es, Jajanan...)'),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Opsi seblak'),
                subtitle: const Text(
                    'Tampilkan Level pedas, Kuah, dan Rasa di kasir untuk menu kategori ini. '
                    'Aktifkan untuk Seblak; matikan untuk Minuman, Es, Jajanan.'),
                value: opsiSeblak,
                onChanged: (v) => setD(() => opsiSeblak = v),
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
    final teks = nama.text;
    WidgetsBinding.instance.addPostFrameCallback((_) => nama.dispose());
    if (ok != true) return;
    await _aman(() async {
      await widget.repo.simpanKategori(id: k?['id'] as int?, nama: teks, opsiSeblak: opsiSeblak);
    }, pesan: 'Kategori disimpan');
  }

  Future<void> _hapus(Map<String, Object?> k) async {
    final jumlah = n(k['jumlah_menu']).toInt();
    final yakin = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Hapus kategori "${k['nama']}"?'),
        content: Text(jumlah == 0
            ? 'Kategori ini belum punya menu.'
            : '$jumlah menu tidak ikut terhapus, tapi dipindah ke "Lainnya".'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Hapus')),
        ],
      ),
    );
    if (yakin != true) return;
    await _aman(() async {
      await widget.repo.hapusKategori(k['id'] as int);
    }, pesan: 'Kategori dihapus');
  }

  Future<void> _aturMenu(Map<String, Object?> k) async {
    final menus = await widget.repo.daftarMenuKategori();
    final nama = '${k['nama']}'.toLowerCase();
    final dipilih = <int>{
      for (final m in menus)
        if ('${m['kategori'] ?? ''}'.trim().toLowerCase() == nama) m['id'] as int,
    };
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text('Menu di "${k['nama']}"'),
          content: SizedBox(
            width: double.maxFinite,
            child: menus.isEmpty
                ? const Text('Belum ada menu. Tambah dulu di tab Menu.')
                : ListView(shrinkWrap: true, children: [
                    for (final m in menus)
                      CheckboxListTile(
                        dense: true,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: Text('${m['nama']}'),
                        subtitle: '${m['kategori'] ?? ''}'.trim().isEmpty ||
                                '${m['kategori']}'.toLowerCase() == nama
                            ? null
                            : Text('Sekarang di: ${m['kategori']}', style: const TextStyle(fontSize: 11)),
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
    await _aman(() => widget.repo.setMenuUntukKategori(k['id'] as int, dipilih.toList()),
        pesan: 'Menu kategori diperbarui');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _form(),
        icon: const Icon(Icons.add),
        label: const Text('Kategori'),
      ),
      body: FutureBuilder<List<Map<String, Object?>>>(
        future: _f,
        builder: (context, snap) {
          if (snap.hasError) return Center(child: Text('${snap.error}'));
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final data = snap.data!;
          return Column(children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                  'Kategori tampil sebagai pilihan di Kasir. Tahan lalu geser untuk mengubah urutan. '
                  'Menu tanpa kategori masuk "Lainnya".',
                  style: TextStyle(fontSize: 12)),
            ),
            Expanded(
              child: data.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text('Belum ada kategori.\nTekan "Kategori" untuk membuat, misalnya Seblak, Minuman, Es.',
                            textAlign: TextAlign.center),
                      ),
                    )
                  : ReorderableListView.builder(
                      padding: const EdgeInsets.only(bottom: 90),
                      itemCount: data.length,
                      onReorder: (a, b) async {
                        final list = List<Map<String, Object?>>.of(data);
                        if (b > a) b -= 1;
                        final item = list.removeAt(a);
                        list.insert(b, item);
                        await _aman(() => widget.repo.urutkanKategori([for (final e in list) e['id'] as int]));
                      },
                      itemBuilder: (_, i) {
                        final k = data[i];
                        final seblak = k['opsi_seblak'] == 1;
                        return ListTile(
                          key: ValueKey(k['id']),
                          leading: const Icon(Icons.drag_handle),
                          title: Text('${k['nama']}', style: const TextStyle(fontWeight: FontWeight.w600)),
                          subtitle: Text('${n(k['jumlah_menu']).toInt()} menu • '
                              '${seblak ? 'Opsi seblak aktif' : 'Tanpa opsi seblak'}'),
                          onTap: () => _form(k: k),
                          trailing: PopupMenuButton<String>(
                            onSelected: (v) {
                              if (v == 'ubah') _form(k: k);
                              if (v == 'menu') _aturMenu(k);
                              if (v == 'hapus') _hapus(k);
                            },
                            itemBuilder: (_) => const [
                              PopupMenuItem(value: 'ubah', child: Text('Ubah nama / opsi')),
                              PopupMenuItem(value: 'menu', child: Text('Atur menu di kategori ini')),
                              PopupMenuItem(value: 'hapus', child: Text('Hapus')),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ]);
        },
      ),
    );
  }
}
