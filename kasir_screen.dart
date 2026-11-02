// kasir_screen.dart
// Pakai PosRepository dari pos_repository.dart (tanpa paket tambahan).
//
//   Navigator.push(context, MaterialPageRoute(
//     builder: (_) => KasirScreen(repo: repo)));

import 'package:flutter/material.dart';
import 'pos_repository.dart';

String rp(num v) {
  final s = v.round().abs().toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write('.');
    b.write(s[i]);
  }
  return '${v < 0 ? '-' : ''}Rp$b';
}

class MenuKasir {
  final int id;
  final String nama;
  final int harga;
  final int? sisaPorsi; // null = resep belum diisi
  MenuKasir(this.id, this.nama, this.harga, this.sisaPorsi);
}

extension KasirQueries on PosRepository {
  Future<List<MenuKasir>> menuAktif() async {
    final r = await db.rawQuery('''
      SELECT m.id, m.nama, m.harga_jual, s.sisa_porsi
      FROM menu m LEFT JOIN v_sisa_porsi_menu s ON s.menu_id = m.id
      WHERE m.aktif = 1 ORDER BY m.nama''');
    return r
        .map((e) => MenuKasir(e['id'] as int, e['nama'] as String,
            e['harga_jual'] as int, (e['sisa_porsi'] as num?)?.toInt()))
        .toList();
  }
}

class KasirScreen extends StatefulWidget {
  final PosRepository repo;
  const KasirScreen({super.key, required this.repo});
  @override
  State<KasirScreen> createState() => _KasirScreenState();
}

class _KasirScreenState extends State<KasirScreen> {
  late Future<List<MenuKasir>> _menu = widget.repo.menuAktif();
  final Map<int, ItemKeranjang> _keranjang = {};
  final Map<int, MenuKasir> _info = {};

  int get _totalQty => _keranjang.values.fold(0, (a, i) => a + i.qty);
  int get _total =>
      _keranjang.values.fold(0, (a, i) => a + i.qty * _info[i.menuId]!.harga);

  void _tambah(MenuKasir m) {
    _info[m.id] = m;
    setState(() {
      final it = _keranjang[m.id];
      if (it == null) {
        _keranjang[m.id] = ItemKeranjang(m.id, 1);
      } else {
        it.qty++;
      }
    });
  }

  void _kurang(int id) => setState(() {
        final it = _keranjang[id]!;
        if (it.qty <= 1) {
          _keranjang.remove(id);
        } else {
          it.qty--;
        }
      });

  void _kosongkan() => setState(_keranjang.clear);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Kasir'),
        actions: [
          if (_keranjang.isNotEmpty)
            IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Kosongkan',
                onPressed: _kosongkan),
        ],
      ),
      body: FutureBuilder<List<MenuKasir>>(
        future: _menu,
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final data = snap.data!;
          if (data.isEmpty) return const Center(child: Text('Belum ada menu aktif.'));
          return GridView.builder(
            padding: const EdgeInsets.all(12),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2, mainAxisSpacing: 10, crossAxisSpacing: 10, childAspectRatio: 1.3),
            itemCount: data.length,
            itemBuilder: (_, i) => _kartuMenu(data[i]),
          );
        },
      ),
      bottomNavigationBar: _keranjang.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: FilledButton(
                  style: FilledButton.styleFrom(padding: const EdgeInsets.all(16)),
                  onPressed: _bukaKeranjang,
                  child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    Text('$_totalQty item'),
                    Text('Lihat pesanan • ${rp(_total)}',
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                  ]),
                ),
              ),
            ),
    );
  }

  Widget _kartuMenu(MenuKasir m) {
    final qty = _keranjang[m.id]?.qty ?? 0;
    final habis = m.sisaPorsi != null && m.sisaPorsi! <= 0;
    return Card(
      color: habis ? Colors.grey.shade200 : null,
      child: InkWell(
        onTap: () => _tambah(m),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Expanded(
                  child: Text(m.nama,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
              if (qty > 0) CircleAvatar(radius: 12, child: Text('$qty')),
            ]),
            const Spacer(),
            Text(rp(m.harga), style: const TextStyle(fontSize: 15)),
            Text(
              m.sisaPorsi == null
                  ? 'Resep belum diisi'
                  : habis
                      ? 'Stok habis'
                      : 'Sisa ± ${m.sisaPorsi} porsi',
              style: TextStyle(
                  fontSize: 11,
                  color: habis || (m.sisaPorsi != null && m.sisaPorsi! < 10)
                      ? Colors.red
                      : Colors.grey.shade700),
            ),
          ]),
        ),
      ),
    );
  }

  // ---------- Keranjang & pembayaran ----------
  void _bukaKeranjang() {
    String metode = 'TUNAI';
    final uang = TextEditingController();
    bool proses = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
        final total = _total;
        final bayar = int.tryParse(uang.text.replaceAll('.', '')) ?? 0;
        final kembali = bayar - total;

        void ubah(void Function() f) {
          f();
          setState(() {});
          setSheet(() {});
          if (_keranjang.isEmpty) Navigator.pop(ctx);
        }

        return Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.of(ctx).viewInsets.bottom + 16),
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text('Pesanan', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              ..._keranjang.values.map((it) {
                final m = _info[it.menuId]!;
                return ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(m.nama),
                  subtitle: Text('${rp(m.harga)} x ${it.qty} = ${rp(m.harga * it.qty)}'),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    IconButton(
                        icon: const Icon(Icons.remove_circle_outline),
                        onPressed: () => ubah(() => _kurang(it.menuId))),
                    Text('${it.qty}'),
                    IconButton(
                        icon: const Icon(Icons.add_circle_outline),
                        onPressed: () => ubah(() => it.qty++)),
                  ]),
                );
              }),
              const Divider(),
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                const Text('Total', style: TextStyle(fontSize: 16)),
                Text(rp(total), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              ]),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'TUNAI', label: Text('Tunai')),
                  ButtonSegment(value: 'QRIS', label: Text('QRIS')),
                  ButtonSegment(value: 'TRANSFER', label: Text('Transfer')),
                ],
                selected: {metode},
                onSelectionChanged: (s) => setSheet(() => metode = s.first),
              ),
              if (metode == 'TUNAI') ...[
                const SizedBox(height: 8),
                TextField(
                  controller: uang,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Uang diterima (Rp)'),
                  onChanged: (_) => setSheet(() {}),
                ),
                Wrap(spacing: 8, children: [
                  for (final v in {total, 20000, 50000, 100000})
                    ActionChip(
                        label: Text(rp(v)),
                        onPressed: () => setSheet(() => uang.text = '$v')),
                ]),
                if (bayar > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(kembali >= 0 ? 'Kembalian ${rp(kembali)}' : 'Uang kurang ${rp(-kembali)}',
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: kembali >= 0 ? Colors.green : Colors.red)),
                  ),
              ],
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: proses || (metode == 'TUNAI' && bayar < total)
                      ? null
                      : () async {
                          setSheet(() => proses = true);
                          final ok = await _bayar(ctx, metode, bayar, kembali);
                          if (!ok) setSheet(() => proses = false);
                        },
                  child: Text(proses ? 'Memproses...' : 'Bayar & Simpan'),
                ),
              ),
            ]),
          ),
        );
      }),
    );
  }

  /// true jika sukses (sheet ditutup), false jika dibatalkan
  Future<bool> _bayar(BuildContext sheetCtx, String metode, int bayar, int kembali) async {
    final daftar = _keranjang.values.map((i) => ItemKeranjang(i.menuId, i.qty)).toList();

    // 1) cek stok, boleh dilanjutkan oleh pemilik jika stok catatan belum sinkron
    final kurang = await widget.repo.cekStok(daftar);
    if (kurang.isNotEmpty) {
      if (!mounted) return false;
      final lanjut = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Stok tidak cukup'),
          content: Text(kurang
              .map((k) => '• ${k.bahan}: butuh ${_f(k.butuh)}, ada ${_f(k.tersedia)}')
              .join('\n')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Batal')),
            FilledButton(
                onPressed: () => Navigator.pop(c, true),
                child: const Text('Tetap lanjut')),
          ],
        ),
      );
      if (lanjut != true) return false;
    }

    // 2) checkout (atomik: simpan transaksi + potong stok)
    final nota = _rincianNota(metode, bayar, kembali);
    final trxId = await widget.repo.checkout(daftar, metodeBayar: metode);

    if (!mounted) return true;
    Navigator.pop(sheetCtx);
    _kosongkan();
    setState(() => _menu = widget.repo.menuAktif()); // sisa porsi diperbarui

    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Transaksi #$trxId berhasil'),
        content: SingleChildScrollView(
            child: Text(nota, style: const TextStyle(fontFamily: 'monospace', fontSize: 12))),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Selesai'))],
      ),
    );
    return true;
  }

  String _f(double v) => (v * 100).round() / 100 == v.roundToDouble()
      ? v.toInt().toString()
      : (v * 100).round() / 100 == 0
          ? v.toString()
          : ((v * 100).round() / 100).toString();

  String _rincianNota(String metode, int bayar, int kembali) {
    final b = StringBuffer();
    final now = DateTime.now();
    b.writeln('${now.day}/${now.month}/${now.year} '
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}');
    b.writeln('------------------------');
    for (final it in _keranjang.values) {
      final m = _info[it.menuId]!;
      b.writeln('${m.nama}\n  ${it.qty} x ${rp(m.harga)} = ${rp(it.qty * m.harga)}');
    }
    b.writeln('------------------------');
    b.writeln('TOTAL   : ${rp(_total)}');
    b.writeln('Bayar   : $metode');
    if (metode == 'TUNAI') {
      b.writeln('Diterima: ${rp(bayar)}');
      b.writeln('Kembali : ${rp(kembali)}');
    }
    return b.toString();
  }
}
