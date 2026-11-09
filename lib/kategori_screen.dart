// kategori_screen.dart — tab "Kategori" di Kelola: tambah, ubah, hapus, dan urutkan kategori menu.
// Menu dihubungkan ke kategori lewat menu.kategori_id (diatur di tab Menu).
import 'package:flutter/material.dart';

import 'helpers.dart';
import 'pos_repository.dart';

class KategoriTab extends StatefulWidget {
  final PosRepository repo;
  const KategoriTab({super.key, required this.repo});
  @override
  State<KategoriTab> createState() => _KategoriTabState();
}

class _KategoriTabState extends State<KategoriTab> {
  late Future<List<Map<String, Object?>>> _f = widget.repo.daftarKategori();

  void _refresh() => setState(() => _f = widget.repo.daftarKategori());

  Future<void> _aman(Future<void> Function() aksi) async {
    try {
      await aksi();
      _refresh();
    } on PosException catch (e) {
      if (mounted) snack(context, e.pesan);
    } catch (e) {
      if (mounted) snack(context, 'Gagal: $e');
    }
  }

  Future<void> _form({Map<String, Object?>? k}) async {
    final c = TextEditingController(text: '${k?['nama'] ?? ''}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(k == null ? 'Tambah kategori' : 'Ubah kategori'),
        content: TextField(
          controller: c,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Nama (Seblak, Minuman, Es, Jajanan...)'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Simpan')),
        ],
      ),
    );
    final nama = c.text;
    WidgetsBinding.instance.addPostFrameCallback((_) => c.dispose());
    if (ok != true) return;
    await _aman(() async {
      await widget.repo.simpanKategori(id: k?['id'] as int?, nama: nama);
    });
  }

  Future<void> _hapus(Map<String, Object?> k) async {
    final jml = (k['jumlah_menu'] as num).toInt();
    final ya = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Hapus kategori "${k['nama']}"?'),
        content: Text(jml == 0
            ? 'Kategori ini belum dipakai menu mana pun.'
            : '$jml menu di kategori ini akan menjadi "tanpa kategori". Menu dan riwayat penjualan tidak terhapus.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Hapus')),
        ],
      ),
    );
    if (ya != true) return;
    await _aman(() => widget.repo.hapusKategori(k['id'] as int));
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
          if (data.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('Belum ada kategori.\nTekan "Kategori" untuk membuat, misalnya "Seblak" atau "Minuman", '
                    'lalu pasang ke menu di tab Menu.',
                    textAlign: TextAlign.center),
              ),
            );
          }
          return ListView(padding: const EdgeInsets.only(bottom: 90), children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text('Urutan di sini = urutan kartu kategori di layar Kasir.',
                  style: TextStyle(fontSize: 12)),
            ),
            for (var i = 0; i < data.length; i++)
              ListTile(
                title: Text('${data[i]['nama']}', style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text('${data[i]['jumlah_aktif']} menu aktif • ${data[i]['jumlah_menu']} total'),
                onTap: () => _form(k: data[i]),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(
                    tooltip: 'Naikkan',
                    icon: const Icon(Icons.arrow_upward, size: 20),
                    onPressed: i == 0 ? null : () => _aman(() => widget.repo.geserKategori(data[i]['id'] as int, -1)),
                  ),
                  IconButton(
                    tooltip: 'Turunkan',
                    icon: const Icon(Icons.arrow_downward, size: 20),
                    onPressed: i == data.length - 1
                        ? null
                        : () => _aman(() => widget.repo.geserKategori(data[i]['id'] as int, 1)),
                  ),
                  IconButton(
                    tooltip: 'Hapus',
                    icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20),
                    onPressed: () => _hapus(data[i]),
                  ),
                ]),
              ),
          ]);
        },
      ),
    );
  }
}
