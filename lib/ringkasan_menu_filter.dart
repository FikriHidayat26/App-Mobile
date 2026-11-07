// ringkasan_menu_filter.dart — Ringkasan Menu di Dashboard dengan filter
// periode (Harian / Mingguan / Bulanan), kategori, dan menu tertentu.
//
// Pasang di dashboard_screen.dart (di dalam ListView/Column), cukup satu baris:
//   const RingkasanMenuFilter(),
import 'package:flutter/material.dart';

import 'helpers.dart';
import 'pos_repository.dart';

class RingkasanMenuFilter extends StatefulWidget {
  const RingkasanMenuFilter({super.key});
  @override
  State<RingkasanMenuFilter> createState() => _RingkasanMenuFilterState();
}

class _Hasil {
  final Map<String, Object?> total;
  final List<Map<String, Object?>> perMenu;
  final List<Map<String, Object?>> variasi;
  final List<String> kategori;
  final List<Map<String, Object?>> menus;
  const _Hasil(this.total, this.perMenu, this.variasi, this.kategori, this.menus);
}

class _RingkasanMenuFilterState extends State<RingkasanMenuFilter> {
  final _repo = PosRepository();

  int _periode = 0; // 0 = harian, 1 = mingguan (7 hari terakhir), 2 = bulanan (bulan ini)
  String? _kategori;
  int? _menuId;
  late Future<_Hasil> _f = _muat();

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  (String, String) _rentang() {
    final now = DateTime.now();
    switch (_periode) {
      case 0:
        return (_fmt(now), _fmt(now));
      case 1:
        return (_fmt(now.subtract(const Duration(days: 6))), _fmt(now));
      default:
        return (_fmt(DateTime(now.year, now.month, 1)), _fmt(now));
    }
  }

  String get _labelRentang {
    final (a, b) = _rentang();
    return a == b ? a : '$a s/d $b';
  }

  Future<_Hasil> _muat() async {
    final (dari, sampai) = _rentang();
    final total = await _repo.ringkasTotalMenu(
        dari: dari, sampai: sampai, menuId: _menuId, kategori: _kategori);
    final perMenu = await _repo.ringkasPerMenu(
        dari: dari, sampai: sampai, menuId: _menuId, kategori: _kategori);
    final variasi = await _repo.ringkasVariasiTerjual(
        dari: dari, sampai: sampai, menuId: _menuId, kategori: _kategori);
    final kategori = await _repo.daftarKategoriMenu();
    final menus = await _repo.daftarMenuKategori();
    return _Hasil(total, perMenu, variasi, kategori, menus);
  }

  void _muatUlang() => setState(() => _f = _muat());

  String _kategoriMenu(Map<String, Object?> m) {
    final k = '${m['kategori'] ?? ''}'.trim();
    return k.isEmpty ? 'Lainnya' : k;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_Hasil>(
      future: _f,
      builder: (context, snap) {
        if (snap.hasError) return Text('${snap.error}');
        if (!snap.hasData) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final h = snap.data!;
        final menuTampil = h.menus
            .where((m) => _kategori == null || _kategoriMenu(m) == _kategori)
            .toList();
        final omzet = (h.total['omzet'] as num).toInt();
        final laba = (h.total['laba'] as num).toDouble();
        final qty = (h.total['qty'] as num).toInt();

        return Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Ringkasan menu', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: [
                for (final e in const [(0, 'Harian'), (1, 'Mingguan'), (2, 'Bulanan')])
                  ChoiceChip(
                    label: Text(e.$2),
                    selected: _periode == e.$1,
                    onSelected: (_) {
                      _periode = e.$1;
                      _muatUlang();
                    },
                  ),
              ]),
              const SizedBox(height: 4),
              Text(_labelRentang, style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
              const SizedBox(height: 8),
              DropdownButtonFormField<String?>(
                value: _kategori,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Kategori', isDense: true),
                items: [
                  const DropdownMenuItem<String?>(value: null, child: Text('Semua kategori')),
                  for (final k in h.kategori) DropdownMenuItem<String?>(value: k, child: Text(k)),
                ],
                onChanged: (v) {
                  _kategori = v;
                  _menuId = null; // menu dipilih ulang sesuai kategori
                  _muatUlang();
                },
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<int?>(
                value: menuTampil.any((m) => m['id'] == _menuId) ? _menuId : null,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Menu', isDense: true),
                items: [
                  const DropdownMenuItem<int?>(value: null, child: Text('Semua menu')),
                  for (final m in menuTampil)
                    DropdownMenuItem<int?>(value: m['id'] as int, child: Text('${m['nama']}')),
                ],
                onChanged: (v) {
                  _menuId = v;
                  _muatUlang();
                },
              ),
              const Divider(height: 24),
              Row(children: [
                _Angka('Terjual', '$qty porsi'),
                _Angka('Omzet', rp(omzet)),
                _Angka('Laba kotor', rp(laba)),
              ]),
              const SizedBox(height: 8),
              if (h.perMenu.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('Belum ada penjualan pada filter ini.'),
                )
              else
                for (final r in h.perMenu) _BarisMenu(r),
              if (h.variasi.isNotEmpty) ...[
                const Divider(height: 24),
                const Text('Variasi terlaris', style: TextStyle(fontWeight: FontWeight.w600)),
                for (final v in h.variasi)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text('${v['grup']}: ${v['opsi']}'),
                    trailing: Text('${(v['qty'] as num).toInt()}x'),
                  ),
              ],
            ]),
          ),
        );
      },
    );
  }
}

class _Angka extends StatelessWidget {
  final String label;
  final String nilai;
  const _Angka(this.label, this.nilai);
  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
          Text(nilai, style: const TextStyle(fontWeight: FontWeight.bold)),
        ]),
      );
}

class _BarisMenu extends StatelessWidget {
  final Map<String, Object?> r;
  const _BarisMenu(this.r);
  @override
  Widget build(BuildContext context) {
    final omzet = (r['omzet'] as num).toDouble();
    final laba = (r['laba'] as num).toDouble();
    final margin = omzet <= 0 ? 0 : laba / omzet * 100;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text('${r['nama']}'),
      subtitle: Text('${r['kategori']} • ${(r['qty'] as num).toInt()} porsi • omzet ${rp(omzet)}'),
      trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
        Text(rp(laba),
            style: TextStyle(fontWeight: FontWeight.bold, color: laba >= 0 ? Colors.green.shade700 : Colors.red)),
        Text('${margin.toStringAsFixed(0)}%', style: const TextStyle(fontSize: 12)),
      ]),
    );
  }
}
