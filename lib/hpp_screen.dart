// hpp_screen.dart — tab "HPP" di Kelola.
// HPP penuh per porsi = HPP bahan (dari resep x modal bahan) + overhead per porsi.
// Overhead per porsi = total biaya tetap per bulan / estimasi porsi per bulan.
// Saran harga = HPP penuh / (1 - target margin), dibulatkan ke atas per Rp500.
// hpp_screen.dart — tab "HPP" di Kelola.
import 'package:flutter/material.dart';

import 'helpers.dart';
import 'models.dart';
import 'pos_repository.dart';

double? _angka(String s) => double.tryParse(s.trim().replaceAll(',', '.'));
int? _bulat(String s) => int.tryParse(s.trim().replaceAll('.', ''));

int _saranHarga(double hpp, double targetPersen) {
  final m = targetPersen.clamp(0, 94) / 100;
  final mentah = hpp / (1 - m);
  return ((mentah / 500).ceil()) * 500;
}

double _marginPersen(num harga, double hpp) => harga <= 0 ? 0 : (harga - hpp) / harga * 100;

double _perBulan(num nominal, String periode) {
  switch (periode) {
    case 'HARIAN':
      return nominal * 30;
    case 'MINGGUAN':
      return nominal * 52 / 12; // ≈ 4,33 minggu per bulan
    default:
      return nominal.toDouble();
  }
}

String _labelPeriode(String p) =>
    p == 'BULANAN' ? 'bulan' : (p == 'MINGGUAN' ? 'minggu' : 'hari');

class _HppData {
  final List> menus;
  final List> overhead;
  final List<Bahan> bahan;
  final double ohPerPorsi;
  final int estPorsi;
  final int porsi30;
  final double target;
  final int biayaDasar;
  const _HppData(this.menus, this.overhead, this.bahan, this.ohPerPorsi, this.estPorsi, this.porsi30,
      this.target, this.biayaDasar);
}

class HppTab extends StatefulWidget {
  final PosRepository repo;
  const HppTab({super.key, required this.repo});
  @override
  State<HppTab> createState() => _HppTabState();
}

class _HppTabState extends State<HppTab> {
  late Future<_HppData> _f = _muat();
  final _estimasi = TextEditingController();
  final _target = TextEditingController();

  Future<_HppData> _muat() async {
    final r = widget.repo;
    final d = _HppData(
      await r.daftarMenuLengkap(),
      await r.daftarOverhead(),
      await r.daftarBahan(),
      await r.overheadPerPorsi(),
      await r.estimasiPorsiBulanan(),
      await r.porsiTerjual30Hari(),
      await r.targetMargin(),
      await r.biayaDasarPrasmanan(),
    );
    _estimasi.text = '${d.estPorsi}';
    _target.text = qtyFmt(d.target);
    return d;
  }

  void _refresh() => setState(() => _f = _muat());

  @override
  void dispose() {
    _estimasi.dispose();
    _target.dispose();
    super.dispose();
  }

  Future<void> _aman(Future<void> Function() aksi, {String? pesan}) async {
    try {
      await aksi();
      if (pesan != null && mounted) snack(context, pesan);
      _refresh();
    } on PosException catch (e) {
      if (mounted) snack(context, e.pesan);
    }
  }

  Future<void> _formOverhead({Map<String, Object?>? o}) async {
    final nama = TextEditingController(text: '${o?['nama'] ?? ''}');
    final nominal = TextEditingController(text: o == null ? '' : '${n(o['nominal']).toInt()}');
    var periode = '${o?['periode'] ?? 'BULANAN'}';
    
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(o == null ? 'Tambah biaya tetap' : 'Ubah biaya tetap'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: nama, decoration: const InputDecoration(labelText: 'Nama (sewa, listrik, gas, gaji...)')),
            TextField(
                controller: nominal,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Nominal (Rp)')),
            DropdownButtonFormField<String>(
              value: periode,
              decoration: const InputDecoration(labelText: 'Dibayar per'),
              items: const [
                DropdownMenuItem(value: 'BULANAN', child: Text('Bulanan')),
                DropdownMenuItem(value: 'MINGGUAN', child: Text('Mingguan')),
                DropdownMenuItem(value: 'HARIAN', child: Text('Harian')),
              ],
              onChanged: (v) => setD(() => periode = v ?? periode),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Simpan')),
          ],
        ),
      ),
    );

    final namaTxt = nama.text;
    final nom = _bulat(nominal.text) ?? -1;
    
    WidgetsBinding.instance.addPostFrameCallback((_) {
      nama.dispose();
      nominal.dispose();
    });

    if (ok != true) return;
    await _aman(() => widget.repo.simpanOverhead(
        id: o?['id'] as int?,
        nama: namaTxt,
        nominal: nom,
        periode: periode,
        aktif: (o?['aktif'] ?? 1) == 1));
  }

  Future<void> _terapkanHarga(Map<String, Object?> m, int saran) async {
    final yakin = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Ubah harga ${m['nama']}?'),
        content: Text('${rp(n(m['harga_jual']))}  →  ${rp(saran)}\n\n'
            'Berlaku untuk transaksi berikutnya. Nota lama tidak berubah.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Ubah harga')),
        ],
      ),
    );
    if (yakin != true) return;
    await _aman(() => widget.repo.updateMenu(m['id'] as int, harga: saran), pesan: 'Harga diubah');
  }

  Color _warnaMargin(double margin, double target) =>
      margin >= target ? Colors.green : (margin >= 0 ? Colors.orange : Colors.red);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_HppData>(
      future: _f,
      builder: (context, snap) {
        if (snap.hasError) return Center(child: Text('${snap.error}'));
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());
        final d = snap.data!;
        final totalBulanan = d.overhead
            .where((o) => o['aktif'] == 1)
            .fold<double>(0, (a, o) => a + _perBulan(n(o['nominal']), '${o['periode']}'));

        return ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 40), children: [
          // ---------------------------------------------- 1. Biaya tetap
          const Text('1. Biaya tetap (overhead)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          ...d.overhead.map((o) {
            final aktif = o['aktif'] == 1;
            final periodeStr = '${o['periode']}';
            return ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text('${o['nama']}', style: TextStyle(color: aktif ? null : Colors.grey)),
              subtitle: Text('${rp(n(o['nominal']))} / ${_labelPeriode(periodeStr)}'),
              onTap: () => _formOverhead(o: o),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                Switch(
                  value: aktif,
                  onChanged: (v) => _aman(() => widget.repo.simpanOverhead(
                      id: o['id'] as int,
                      nama: '${o['nama']}',
                      nominal: n(o['nominal']).toInt(),
                      periode: periodeStr,
                      aktif: v)),
                ),
                IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.red),
                    onPressed: () => _aman(() => widget.repo.hapusOverhead(o['id'] as int))),
              ]),
            );
          }),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
                onPressed: () => _formOverhead(),
                icon: const Icon(Icons.add),
                label: const Text('Tambah biaya tetap')),
          ),
          const Divider(),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _estimasi,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                    labelText: 'Estimasi porsi terjual / bulan', helperText: 'Pembagi biaya tetap'),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: () => _aman(
                  () => widget.repo.setEstimasiPorsiBulanan(_bulat(_estimasi.text) ?? 0),
                  pesan: 'Estimasi disimpan'),
              child: const Text('Simpan'),
            ),
          ]),
          if (d.porsi30 > 0)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () {
                  _estimasi.text = '${d.porsi30}';
                  _aman(() => widget.repo.setEstimasiPorsiBulanan(d.porsi30),
                      pesan: 'Memakai penjualan 30 hari terakhir');
                },
                child: Text('Pakai penjualan nyata 30 hari terakhir (${d.porsi30} porsi)'),
              ),
            ),
          Card(
            color: Colors.orange.shade50,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                  'Total biaya tetap ${rp(totalBulanan)} / bulan  ÷  ${d.estPorsi} porsi\n'
                  '= overhead ${rp(d.ohPerPorsi)} per porsi',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
          ),

          // ---------------------------------------------- 2. Target margin
          const SizedBox(height: 16),
          const Text('2. Target margin', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _target,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                    labelText: 'Target untung (% dari harga jual)', suffixText: '%'),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: () => _aman(() => widget.repo.setTargetMargin(_angka(_target.text) ?? -1),
                  pesan: 'Target disimpan'),
              child: const Text('Simpan'),
            ),
          ]),

          // ---------------------------------------------- 3. Menu
          const SizedBox(height: 16),
          const Text('3. HPP & saran harga menu', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const Padding(
            padding: EdgeInsets.only(bottom: 6),
            child: Text('HPP penuh = bahan + overhead per porsi. Menu belum punya resep → HPP bahan Rp0 (isi resepnya dulu).',
                style: TextStyle(fontSize: 12)),
          ),
          ...d.menus.where((m) => m['aktif'] == 1).map((m) {
            final bahan = n(m['hpp_bahan']).toDouble();
            final penuh = bahan + d.ohPerPorsi;
            final harga = n(m['harga_jual']);
            final margin = _marginPersen(harga, penuh);
            final saran = _saranHarga(penuh, d.target);
            final belumResep = bahan <= 0;
            return Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(
                        child: Text('${m['nama']}',
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15))),
                    Chip(
                      label: Text('${margin.toStringAsFixed(0)}%',
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                      backgroundColor: _warnaMargin(margin, d.target),
                      visualDensity: VisualDensity.compact,
                    ),
                  ]),
                  Text('Harga jual ${rp(harga)}'),
                  Text('HPP bahan ${rp(bahan)} + overhead ${rp(d.ohPerPorsi)} = ${rp(penuh)}'),
                  Text('Laba per porsi ${rp(harga - penuh)}',
                      style: TextStyle(color: harga - penuh >= 0 ? Colors.green.shade700 : Colors.red)),
                  if (belumResep)
                    const Text('Resep belum diisi', style: TextStyle(color: Colors.red, fontSize: 12))
                  else
                    Row(children: [
                      Expanded(child: Text('Saran harga (target ${qtyFmt(d.target)}%): ${rp(saran)}')),
                      if (saran != harga)
                        TextButton(onPressed: () => _terapkanHarga(m, saran), child: const Text('Pakai')),
                    ]),
                ]),
              ),
            );
          }),

          // ---------------------------------------------- 4. Prasmanan
          const SizedBox(height: 16),
          const Text('4. Margin topping prasmanan', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const Padding(
            padding: EdgeInsets.only(bottom: 6),
            child: Text('Overhead dibebankan per pesanan lewat "biaya dasar", bukan per topping.',
                style: TextStyle(fontSize: 12)),
          ),
          Card(
            color: Colors.orange.shade50,
            child: ListTile(
              title: Text('Biaya dasar sekarang: ${rp(d.biayaDasar)}'),
              subtitle: Text('Minimal agar overhead tertutup: ${rp(_saranHarga(d.ohPerPorsi, d.target))}\n'
                  '(ubah di Kelola > Bahan > ikon pengaturan)'),
              isThreeLine: true,
            ),
          ),
          ...d.bahan.where((b) => b.bisaPrasmanan).map((b) {
            final hpp = b.qtyPrasmanan * b.hppPerDasar;
            final margin = _marginPersen(b.hargaPrasmanan, hpp);
            final saran = _saranHarga(hpp, d.target);
            return ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(b.nama),
              subtitle: Text('Modal ${rp(hpp)} • jual ${rp(b.hargaPrasmanan)} • saran ${rp(saran)}'),
              trailing: Text('${margin.toStringAsFixed(0)}%',
                  style: TextStyle(fontWeight: FontWeight.bold, color: _warnaMargin(margin, d.target))),
            );
          }),
        ]);
      },
    );
  }
}

                DropdownMenuItem(value: 'HARIAN', child: Text('Hari')),
              ],
              onChanged: (v) => setD(() => periode = v ?? periode),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Simpan')),
          ],
        ),
      ),
    );
    final namaTxt = nama.text;
    final nom = _bulat(nominal.text) ?? -1;
    nama.dispose();
    nominal.dispose();
    if (ok != true) return;
    await _aman(() => widget.repo.simpanOverhead(
        id: o?['id'] as int?,
        nama: namaTxt,
        nominal: nom,
        periode: periode,
        aktif: (o?['aktif'] ?? 1) == 1));
  }

  Future<void> _terapkanHarga(Map<String, Object?> m, int saran) async {
    final yakin = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Ubah harga ${m['nama']}?'),
        content: Text('${rp(n(m['harga_jual']))}  →  ${rp(saran)}\n\n'
            'Berlaku untuk transaksi berikutnya. Nota lama tidak berubah.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Ubah harga')),
        ],
      ),
    );
    if (yakin != true) return;
    await _aman(() => widget.repo.updateMenu(m['id'] as int, harga: saran), pesan: 'Harga diubah');
  }

  Color _warnaMargin(double margin, double target) =>
      margin >= target ? Colors.green : (margin >= 0 ? Colors.orange : Colors.red);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_HppData>(
      future: _f,
      builder: (context, snap) {
        if (snap.hasError) return Center(child: Text('${snap.error}'));
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());
        final d = snap.data!;
        final totalBulanan = d.overhead.where((o) => o['aktif'] == 1).fold<double>(
            0, (a, o) => a + (o['periode'] == 'BULANAN' ? n(o['nominal']) : n(o['nominal']) * 30));

        return ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 40), children: [
          // ---------------------------------------------- 1. Biaya tetap
          const Text('1. Biaya tetap (overhead)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          ...d.overhead.map((o) {
            final aktif = o['aktif'] == 1;
            return ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text('${o['nama']}', style: TextStyle(color: aktif ? null : Colors.grey)),
              subtitle: Text('${rp(n(o['nominal']))} / ${o['periode'] == 'BULANAN' ? 'bulan' : 'hari'}'),
              onTap: () => _formOverhead(o: o),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                Switch(
                  value: aktif,
                  onChanged: (v) => _aman(() => widget.repo.simpanOverhead(
                      id: o['id'] as int,
                      nama: '${o['nama']}',
                      nominal: n(o['nominal']).toInt(),
                      periode: '${o['periode']}',
                      aktif: v)),
                ),
                IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.red),
                    onPressed: () => _aman(() => widget.repo.hapusOverhead(o['id'] as int))),
              ]),
            );
          }),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
                onPressed: () => _formOverhead(),
                icon: const Icon(Icons.add),
                label: const Text('Tambah biaya tetap')),
          ),
          const Divider(),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _estimasi,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                    labelText: 'Estimasi porsi terjual / bulan', helperText: 'Pembagi biaya tetap'),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
// hpp_screen.dart — tab "HPP" di Kelola.
import 'package:flutter/material.dart';

import 'helpers.dart';
import 'models.dart';
import 'pos_repository.dart';

double? _angka(String s) => double.tryParse(s.trim().replaceAll(',', '.'));
int? _bulat(String s) => int.tryParse(s.trim().replaceAll('.', ''));

int _saranHarga(double hpp, double targetPersen) {
  final m = targetPersen.clamp(0, 94) / 100;
  final mentah = hpp / (1 - m);
  return ((mentah / 500).ceil()) * 500;
}

double _marginPersen(num harga, double hpp) => harga <= 0 ? 0 : (harga - hpp) / harga * 100;

double _perBulan(num nominal, String periode) {
  switch (periode) {
    case 'HARIAN':
      return nominal * 30;
    case 'MINGGUAN':
      return nominal * 52 / 12; // ≈ 4,33 minggu per bulan
    default:
      return nominal.toDouble();
  }
}

String _labelPeriode(String p) =>
    p == 'BULANAN' ? 'bulan' : (p == 'MINGGUAN' ? 'minggu' : 'hari');

class _HppData {
  final List> menus;
  final List> overhead;
  final List<Bahan> bahan;
  final double ohPerPorsi;
  final int estPorsi;
  final int porsi30;
  final double target;
  final int biayaDasar;
  const _HppData(this.menus, this.overhead, this.bahan, this.ohPerPorsi, this.estPorsi, this.porsi30,
      this.target, this.biayaDasar);
}

class HppTab extends StatefulWidget {
  final PosRepository repo;
  const HppTab({super.key, required this.repo});
  @override
  State<HppTab> createState() => _HppTabState();
}

class _HppTabState extends State<HppTab> {
  late Future<_HppData> _f = _muat();
  final _estimasi = TextEditingController();
  final _target = TextEditingController();

  Future<_HppData> _muat() async {
    final r = widget.repo;
    final d = _HppData(
      await r.daftarMenuLengkap(),
      await r.daftarOverhead(),
      await r.daftarBahan(),
      await r.overheadPerPorsi(),
      await r.estimasiPorsiBulanan(),
      await r.porsiTerjual30Hari(),
      await r.targetMargin(),
      await r.biayaDasarPrasmanan(),
    );
    _estimasi.text = '${d.estPorsi}';
    _target.text = qtyFmt(d.target);
    return d;
  }

  void _refresh() => setState(() => _f = _muat());

  @override
  void dispose() {
    _estimasi.dispose();
    _target.dispose();
    super.dispose();
  }

  Future<void> _aman(Future<void> Function() aksi, {String? pesan}) async {
    try {
      await aksi();
      if (pesan != null && mounted) snack(context, pesan);
      _refresh();
    } on PosException catch (e) {
      if (mounted) snack(context, e.pesan);
    }
  }

  Future<void> _formOverhead({Map<String, Object?>? o}) async {
    final nama = TextEditingController(text: '${o?['nama'] ?? ''}');
    final nominal = TextEditingController(text: o == null ? '' : '${n(o['nominal']).toInt()}');
    var periode = '${o?['periode'] ?? 'BULANAN'}';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(o == null ? 'Tambah biaya tetap' : 'Ubah biaya tetap'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: nama, decoration: const InputDecoration(labelText: 'Nama (sewa, listrik, gas, gaji...)')),
            TextField(
                controller: nominal,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Nominal (Rp)')),
            DropdownButtonFormField<String>(
              value: periode,
              decoration: const InputDecoration(labelText: 'Dibayar per'),
              items: const [
                DropdownMenuItem(value: 'BULANAN', child: Text('Bulan')),
                DropdownMenuItem(value: 'MINGGUAN', child: Text('Mingguan')),
                DropdownMenuItem(value: 'HARIAN', child: Text('Hari')),
              ],
              onChanged: (v) => setD(() => periode = v ?? periode),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Simpan')),
          ],
        ),
      ),
    );
    final namaTxt = nama.text;
    final nom = _bulat(nominal.text) ?? -1;
    nama.dispose();
    nominal.dispose();
    if (ok != true) return;
    await _aman(() => widget.repo.simpanOverhead(
        id: o?['id'] as int?,
        nama: namaTxt,
        nominal: nom,
        periode: periode,
        aktif: (o?['aktif'] ?? 1) == 1));
  }

  Future<void> _terapkanHarga(Map<String, Object?> m, int saran) async {
    final yakin = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Ubah harga ${m['nama']}?'),
        content: Text('${rp(n(m['harga_jual']))}  →  ${rp(saran)}\n\n'
            'Berlaku untuk transaksi berikutnya. Nota lama tidak berubah.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Ubah harga')),
        ],
      ),
    );
    if (yakin != true) return;
    await _aman(() => widget.repo.updateMenu(m['id'] as int, harga: saran), pesan: 'Harga diubah');
  }

  Color _warnaMargin(double margin, double target) =>
      margin >= target ? Colors.green : (margin >= 0 ? Colors.orange : Colors.red);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_HppData>(
      future: _f,
      builder: (context, snap) {
        if (snap.hasError) return Center(child: Text('${snap.error}'));
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());
        final d = snap.data!;
        final totalBulanan = d.overhead
            .where((o) => o['aktif'] == 1)
            .fold<double>(0, (a, o) => a + _perBulan(n(o['nominal']), '${o['periode']}'));

        return ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 40), children: [
          // ---------------------------------------------- 1. Biaya tetap
          const Text('1. Biaya tetap (overhead)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          ...d.overhead.map((o) {
            final aktif = o['aktif'] == 1;
            final periodeStr = '${o['periode']}';
            return ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text('${o['nama']}', style: TextStyle(color: aktif ? null : Colors.grey)),
              subtitle: Text('${rp(n(o['nominal']))} / ${_labelPeriode(periodeStr)}'),
              onTap: () => _formOverhead(o: o),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                Switch(
                  value: aktif,
                  onChanged: (v) => _aman(() => widget.repo.simpanOverhead(
                      id: o['id'] as int,
                      nama: '${o['nama']}',
                      nominal: n(o['nominal']).toInt(),
                      periode: periodeStr,
                      aktif: v)),
                ),
                IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.red),
                    onPressed: () => _aman(() => widget.repo.hapusOverhead(o['id'] as int))),
              ]),
            );
          }),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
                onPressed: () => _formOverhead(),
                icon: const Icon(Icons.add),
                label: const Text('Tambah biaya tetap')),
          ),
          const Divider(),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _estimasi,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                    labelText: 'Estimasi porsi terjual / bulan', helperText: 'Pembagi biaya tetap'),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: () => _aman(
                  () => widget.repo.setEstimasiPorsiBulanan(_bulat(_estimasi.text) ?? 0),
                  pesan: 'Estimasi disimpan'),
              child: const Text('Simpan'),
            ),
          ]),
          if (d.porsi30 > 0)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () {
                  _estimasi.text = '${d.porsi30}';
                  _aman(() => widget.repo.setEstimasiPorsiBulanan(d.porsi30),
                      pesan: 'Memakai penjualan 30 hari terakhir');
                },
                child: Text('Pakai penjualan nyata 30 hari terakhir (${d.porsi30} porsi)'),
              ),
            ),
          Card(
            color: Colors.orange.shade50,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                  'Total biaya tetap ${rp(totalBulanan)} / bulan  ÷  ${d.estPorsi} porsi\n'
                  '= overhead ${rp(d.ohPerPorsi)} per porsi',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
          ),

          // ---------------------------------------------- 2. Target margin
          const SizedBox(height: 16),
          const Text('2. Target margin', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _target,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                    labelText: 'Target untung (% dari harga jual)', suffixText: '%'),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: () => _aman(() => widget.repo.setTargetMargin(_angka(_target.text) ?? -1),
                  pesan: 'Target disimpan'),
              child: const Text('Simpan'),
            ),
          ]),

          // ---------------------------------------------- 3. Menu
          const SizedBox(height: 16),
          const Text('3. HPP & saran harga menu', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const Padding(
            padding: EdgeInsets.only(bottom: 6),
            child: Text('HPP penuh = bahan + overhead per porsi. Menu belum punya resep → HPP bahan Rp0 (isi resepnya dulu).',
                style: TextStyle(fontSize: 12)),
          ),
          ...d.menus.where((m) => m['aktif'] == 1).map((m) {
            final bahan = n(m['hpp_bahan']).toDouble();
            final penuh = bahan + d.ohPerPorsi;
            final harga = n(m['harga_jual']);
            final margin = _marginPersen(harga, penuh);
            final saran = _saranHarga(penuh, d.target);
            final belumResep = bahan <= 0;
            return Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(
                        child: Text('${m['nama']}',
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15))),
                    Chip(
                      label: Text('${margin.toStringAsFixed(0)}%',
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                      backgroundColor: _warnaMargin(margin, d.target),
                      visualDensity: VisualDensity.compact,
                    ),
                  ]),
                  Text('Harga jual ${rp(harga)}'),
                  Text('HPP bahan ${rp(bahan)} + overhead ${rp(d.ohPerPorsi)} = ${rp(penuh)}'),
                  Text('Laba per porsi ${rp(harga - penuh)}',
                      style: TextStyle(color: harga - penuh >= 0 ? Colors.green.shade700 : Colors.red)),
                  if (belumResep)
                    const Text('Resep belum diisi', style: TextStyle(color: Colors.red, fontSize: 12))
                  else
                    Row(children: [
                      Expanded(child: Text('Saran harga (target ${qtyFmt(d.target)}%): ${rp(saran)}')),
                      if (saran != harga)
                        TextButton(onPressed: () => _terapkanHarga(m, saran), child: const Text('Pakai')),
                    ]),
                ]),
              ),
            );
          }),

          // ---------------------------------------------- 4. Prasmanan
          const SizedBox(height: 16),
          const Text('4. Margin topping prasmanan', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const Padding(
            padding: EdgeInsets.only(bottom: 6),
            child: Text('Overhead dibebankan per pesanan lewat "biaya dasar", bukan per topping.',
                style: TextStyle(fontSize: 12)),
          ),
          Card(
            color: Colors.orange.shade50,
            child: ListTile(
              title: Text('Biaya dasar sekarang: ${rp(d.biayaDasar)}'),
              subtitle: Text('Minimal agar overhead tertutup: ${rp(_saranHarga(d.ohPerPorsi, d.target))}\n'
                  '(ubah di Kelola > Bahan > ikon pengaturan)'),
              isThreeLine: true,
            ),
          ),
          ...d.bahan.where((b) => b.bisaPrasmanan).map((b) {
            final hpp = b.qtyPrasmanan * b.hppPerDasar;
            final margin = _marginPersen(b.hargaPrasmanan, hpp);
            final saran = _saranHarga(hpp, d.target);
            return ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(b.nama),
              subtitle: Text('Modal ${rp(hpp)} • jual ${rp(b.hargaPrasmanan)} • saran ${rp(saran)}'),
              trailing: Text('${margin.toStringAsFixed(0)}%',
                  style: TextStyle(fontWeight: FontWeight.bold, color: _warnaMargin(margin, d.target))),
            );
          }),
        ]);
      },
    );
  }
}
