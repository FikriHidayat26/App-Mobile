// dashboard_screen.dart
// Tanpa paket tambahan selain sqflite. Pakai PosRepository dari pos_repository.dart.
//
// Cara pakai:
//   Navigator.push(context, MaterialPageRoute(
//     builder: (_) => DashboardScreen(repo: repo)));

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

// ---------- Query tambahan untuk dashboard ----------
extension DashboardQueries on PosRepository {
  Future<Map<String, Object?>> ringkasanHariIni() async {
    final r = await db.rawQuery(
        "SELECT * FROM v_rekap_harian WHERE tanggal = date('now','localtime')");
    return r.isEmpty
        ? {'jumlah_transaksi': 0, 'porsi_terjual': 0, 'omzet': 0, 'total_hpp': 0, 'laba_kotor': 0}
        : r.first;
  }

  Future<double> overheadHarian() async {
    final r = await db.rawQuery('''
      SELECT COALESCE(SUM(CASE periode WHEN 'BULANAN' THEN nominal / 30.0 ELSE nominal END),0) AS v
      FROM overhead WHERE aktif = 1''');
    return n(r.first['v']).toDouble();
  }

  Future<List<Map<String, Object?>>> menuTerlarisHariIni() => db.rawQuery('''
      SELECT m.nama, SUM(ti.qty) AS qty, SUM(ti.qty * ti.harga_jual) AS omzet
      FROM transaksi t
      JOIN transaksi_item ti ON ti.transaksi_id = t.id
      JOIN menu m ON m.id = ti.menu_id
      WHERE t.status = 'SELESAI' AND date(t.waktu) = date('now','localtime')
      GROUP BY m.id ORDER BY qty DESC LIMIT 5''');

  Future<List<Map<String, Object?>>> sisaPorsi() =>
      db.query('v_sisa_porsi_menu', orderBy: 'nama');
}

// ---------- Layar utama ----------
class DashboardScreen extends StatelessWidget {
  final PosRepository repo;
  const DashboardScreen({super.key, required this.repo});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Dashboard Kedai'),
          bottom: const TabBar(tabs: [
            Tab(text: 'Ringkasan'),
            Tab(text: 'Stok'),
            Tab(text: 'Laporan'),
          ]),
        ),
        body: TabBarView(children: [
          RingkasanTab(repo: repo),
          StokTab(repo: repo),
          LaporanTab(repo: repo),
        ]),
      ),
    );
  }
}

// ---------- Tab 1: Ringkasan ----------
class RingkasanTab extends StatefulWidget {
  final PosRepository repo;
  const RingkasanTab({super.key, required this.repo});
  @override
  State<RingkasanTab> createState() => _RingkasanTabState();
}

class _RingkasanTabState extends State<RingkasanTab> {
  late Future<List<Object>> _f = _load();

  Future<List<Object>> _load() => Future.wait<Object>([
        widget.repo.ringkasanHariIni(),
        widget.repo.overheadHarian(),
        widget.repo.menuTerlarisHariIni(),
        widget.repo.sisaPorsi(),
        widget.repo.stokRealtime(),
      ]);

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () async => setState(() => _f = _load()),
      child: FutureBuilder<List<Object>>(
        future: _f,
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final r = snap.data![0] as Map<String, Object?>;
          final overhead = snap.data![1] as double;
          final terlaris = snap.data![2] as List<Map<String, Object?>>;
          final sisa = snap.data![3] as List<Map<String, Object?>>;
          final stok = snap.data![4] as List<Map<String, Object?>>;

          final labaKotor = n(r['laba_kotor']).toDouble();
          final labaBersih = labaKotor - overhead;
          final menipis = stok.where((s) => s['perlu_beli'] == 1).toList();

          return ListView(padding: const EdgeInsets.all(12), children: [
            Row(children: [
              _kartu('Omzet', rp(n(r['omzet'])), Icons.payments, Colors.green),
              _kartu('Porsi', '${n(r['porsi_terjual'])}', Icons.ramen_dining, Colors.orange),
            ]),
            Row(children: [
              _kartu('Laba kotor', rp(labaKotor), Icons.trending_up, Colors.blue),
              _kartu('Laba bersih*', rp(labaBersih), Icons.account_balance_wallet,
                  labaBersih >= 0 ? Colors.teal : Colors.red),
            ]),
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 8),
              child: Text('*setelah overhead harian ${rp(overhead)}',
                  style: Theme.of(context).textTheme.bodySmall),
            ),
            if (menipis.isNotEmpty)
              Card(
                color: Colors.red.shade50,
                child: ListTile(
                  leading: const Icon(Icons.warning_amber, color: Colors.red),
                  title: Text('${menipis.length} bahan perlu dibeli'),
                  subtitle: Text(menipis.map((e) => e['nama']).join(', ')),
                ),
              ),
            _judul('Menu terlaris hari ini'),
            if (terlaris.isEmpty) const ListTile(title: Text('Belum ada penjualan')),
            ...terlaris.map((m) => ListTile(
                  dense: true,
                  title: Text('${m['nama']}'),
                  trailing: Text('${m['qty']} porsi • ${rp(n(m['omzet']))}'),
                )),
            _judul('Estimasi sisa porsi dari stok'),
            ...sisa.map((m) => ListTile(
                  dense: true,
                  title: Text('${m['nama']}'),
                  trailing: Text('${m['sisa_porsi']} porsi',
                      style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: n(m['sisa_porsi']) < 10 ? Colors.red : null)),
                )),
          ]);
        },
      ),
    );
  }

  Widget _kartu(String label, String nilai, IconData ic, Color c) => Expanded(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(ic, color: c),
              const SizedBox(height: 6),
              Text(label, style: const TextStyle(fontSize: 12)),
              FittedBox(
                  child: Text(nilai,
                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold))),
            ]),
          ),
        ),
      );

  Widget _judul(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
        child: Text(t, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
      );
}

// ---------- Tab 2: Stok real-time ----------
class StokTab extends StatefulWidget {
  final PosRepository repo;
  const StokTab({super.key, required this.repo});
  @override
  State<StokTab> createState() => _StokTabState();
}

class _StokTabState extends State<StokTab> {
  late Future<List<Map<String, Object?>>> _f = widget.repo.stokRealtime();
  String _cari = '';
  bool _hanyaMenipis = false;

  void _refresh() => setState(() => _f = widget.repo.stokRealtime());

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(8),
        child: Row(children: [
          Expanded(
            child: TextField(
              decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search), hintText: 'Cari bahan', isDense: true),
              onChanged: (v) => setState(() => _cari = v.toLowerCase()),
            ),
          ),
          const SizedBox(width: 8),
          FilterChip(
            label: const Text('Menipis'),
            selected: _hanyaMenipis,
            onSelected: (v) => setState(() => _hanyaMenipis = v),
          ),
        ]),
      ),
      Expanded(
        child: RefreshIndicator(
          onRefresh: () async => _refresh(),
          child: FutureBuilder<List<Map<String, Object?>>>(
            future: _f,
            builder: (context, snap) {
              if (!snap.hasData) return const Center(child: CircularProgressIndicator());
              final data = snap.data!.where((s) {
                final cocok = '${s['nama']}'.toLowerCase().contains(_cari);
                return cocok && (!_hanyaMenipis || s['perlu_beli'] == 1);
              }).toList();
              final nilaiTotal = snap.data!.fold<double>(0, (a, s) => a + n(s['nilai_stok']));
              return ListView(children: [
                ListTile(
                  title: const Text('Total nilai stok'),
                  trailing: Text(rp(nilaiTotal),
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
                const Divider(height: 1),
                ...data.map(_baris),
              ]);
            },
          ),
        ),
      ),
    ]);
  }

  Widget _baris(Map<String, Object?> s) {
    final stok = n(s['stok']).toDouble();
    final min = n(s['stok_minimum']).toDouble();
    final habis = s['perlu_beli'] == 1;
    final rasio = min <= 0 ? 1.0 : (stok / (min * 3)).clamp(0.0, 1.0);
    return ListTile(
      onTap: () => _aksi(s),
      title: Text('${s['nama']}'),
      subtitle: LinearProgressIndicator(
        value: rasio,
        color: habis ? Colors.red : Colors.green,
        backgroundColor: Colors.grey.shade200,
      ),
      trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text('${qtyFmt(stok)} ${s['satuan_dasar']}',
                style: TextStyle(fontWeight: FontWeight.bold, color: habis ? Colors.red : null)),
            Text('min ${qtyFmt(min)}', style: const TextStyle(fontSize: 11)),
          ]),
    );
  }

  void _aksi(Map<String, Object?> s) {
    final c = TextEditingController();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.of(ctx).viewInsets.bottom + 16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('${s['nama']} (${s['satuan_dasar']})',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          TextField(
            controller: c,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Jumlah (boleh 0.5 atau 1/4)'),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () async {
                  final v = Takaran.parse(c.text).nilai;
                  await widget.repo.opname(s['id'] as int, v, catatan: 'Opname dari dashboard');
                  if (ctx.mounted) Navigator.pop(ctx);
                  _refresh();
                },
                child: const Text('Set stok fisik'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton(
                onPressed: () async {
                  final v = Takaran.parse(c.text).nilai;
                  await widget.repo.buangBahan(s['id'] as int, v, catatan: 'Rusak/terbuang');
                  if (ctx.mounted) Navigator.pop(ctx);
                  _refresh();
                },
                child: const Text('Catat terbuang'),
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}

// ---------- Tab 3: Laporan ----------
class LaporanTab extends StatefulWidget {
  final PosRepository repo;
  const LaporanTab({super.key, required this.repo});
  @override
  State<LaporanTab> createState() => _LaporanTabState();
}

class _LaporanTabState extends State<LaporanTab> {
  late Future<List<List<Map<String, Object?>>>> _f = _load();

  Future<List<List<Map<String, Object?>>>> _load() =>
      Future.wait([widget.repo.rekapHarian(), widget.repo.marginMenu()]);

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () async => setState(() => _f = _load()),
      child: FutureBuilder<List<List<Map<String, Object?>>>>(
        future: _f,
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final rekap = snap.data![0];
          final margin = snap.data![1];
          final maxOmzet = rekap.fold<double>(1, (a, r) => n(r['omzet']) > a ? n(r['omzet']).toDouble() : a);
          final totalOmzet = rekap.fold<double>(0, (a, r) => a + n(r['omzet']));
          final totalLaba = rekap.fold<double>(0, (a, r) => a + n(r['laba_kotor']));

          return ListView(padding: const EdgeInsets.all(12), children: [
            Text('30 hari terakhir: omzet ${rp(totalOmzet)} • laba kotor ${rp(totalLaba)}',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            if (rekap.isEmpty) const Text('Belum ada transaksi.'),
            ...rekap.map((r) {
              final omzet = n(r['omzet']).toDouble();
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    Text('${r['tanggal']}'),
                    Text('${r['porsi_terjual']} porsi • ${rp(omzet)}'),
                  ]),
                  const SizedBox(height: 2),
                  LinearProgressIndicator(value: omzet / maxOmzet, minHeight: 8),
                  Text('HPP ${rp(n(r['total_hpp']))} • laba kotor ${rp(n(r['laba_kotor']))}',
                      style: const TextStyle(fontSize: 11)),
                ]),
              );
            }),
            const Divider(height: 32),
            const Text('Margin per menu (termasuk overhead)',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ...margin.map((m) {
              final persen = n(m['margin_persen']).toDouble();
              return Card(
                child: ListTile(
                  title: Text('${m['nama']}'),
                  subtitle: Text('Jual ${rp(n(m['harga_jual']))} • HPP bahan ${rp(n(m['hpp_bahan']))}\n'
                      'HPP penuh ${rp(n(m['hpp_penuh']))} • laba ${rp(n(m['laba_per_porsi']))}/porsi'),
                  isThreeLine: true,
                  trailing: Text('${persen.toStringAsFixed(0)}%',
                      style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: persen < 20 ? Colors.red : Colors.green)),
                ),
              );
            }),
          ]);
        },
      ),
    );
  }
}

