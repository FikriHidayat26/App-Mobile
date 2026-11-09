// kasir_screen.dart — Kasir: menu tetap + seblak prasmanan + request customer.
// Semua hitungan harga/stok final dilakukan ulang di PosRepository.simpanTransaksi
// (satu transaksi database) sehingga stok & keuangan selalu sinkron.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import 'helpers.dart';
import 'models.dart';
import 'pos_repository.dart';
import 'printer_service.dart';
import 'variasi_models.dart';
import 'variasi_picker.dart';

// Penanda khusus untuk kartu kategori di layar kasir.
const int _kSemua = -1; // "Semua menu"
const int _kTanpa = -2; // menu tanpa kategori

class KasirScreen extends StatefulWidget {
  final PosRepository repo;
  const KasirScreen({super.key, required this.repo});
  @override
  State<KasirScreen> createState() => _KasirScreenState();
}

class _KasirScreenState extends State<KasirScreen> {
  List<Menu> _menus = [];
  List<Map<String, Object?>> _kategori = [];
  int? _katId; // null = tampilan grid kategori; selain itu = isi kategori terpilih
  String _katNama = '';
  List<Bahan> _bahan = [];
  int _biayaDasar = 0;
  bool _loading = true;
  String? _error;
  int _mode = 0; // 0 = menu, 1 = prasmanan
  final List<CartItem> _cart = [];

  @override
  void initState() {
    super.initState();
    _muat();
  }

  Future<void> _muat() async {
    try {
      final menus = await widget.repo.daftarMenu();
      final kategori = await widget.repo.daftarKategori();
      final bahan = await widget.repo.daftarBahan();
      final biaya = await widget.repo.biayaDasarPrasmanan();
      if (!mounted) return;
      setState(() {
        _menus = menus;
        _kategori = kategori;
        // Kategori yang terpilih sudah dihapus -> kembali ke grid.
        if (_katId != null && _katId! >= 0 && !kategori.any((k) => k['id'] == _katId)) _katId = null;
        _bahan = bahan;
        _biayaDasar = biaya;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Map<int, Bahan> get _bahanMap => {for (final b in _bahan) b.id!: b};
  List<Bahan> get _bahanPrasmanan =>
      _bahan.where((b) => b.bisaPrasmanan && b.hargaPrasmanan > 0).toList();

  double _terpakai(int bahanId, {CartItem? kecuali}) {
    var t = 0.0;
    for (final c in _cart) {
      if (identical(c, kecuali)) continue;
      t += (c.kebutuhanPerPorsi[bahanId] ?? 0) * c.qty;
    }
    return t;
  }

  double _sisaStok(int bahanId, {CartItem? kecuali}) =>
      (_bahanMap[bahanId]?.stok ?? 0) - _terpakai(bahanId, kecuali: kecuali);

  int get _total => _cart.fold(0, (a, c) => a + c.subtotal);
  int get _jumlahPorsi => _cart.fold(0, (a, c) => a + c.qty);

  Future<void> _buka({Menu? menu, CartItem? awal}) async {
    final m = awal?.menu ?? menu;
    final resep = awal != null
        ? awal.resep
        : (m == null ? <ResepItem>[] : await widget.repo.resepMenu(m.id!));
    // Variasi dinamis hanya untuk menu tetap; kelompok tanpa opsi aktif diabaikan.
    final grupVariasi = m == null
        ? <VariasiGrup>[]
        : (await widget.repo.grupUntukMenu(m.id!)).where((g) => g.opsi.isNotEmpty).toList();
    if (!mounted) return;
    final hasil = await Navigator.push<CartItem>(
      context,
      MaterialPageRoute(
        builder: (_) => ItemEditorPage(
          menu: m,
          resep: resep,
          bahanPrasmanan: _bahanPrasmanan,
          semuaBahan: _bahanMap,
          biayaDasar: _biayaDasar,
          awal: awal,
          grupVariasi: grupVariasi,
          sisaStok: (id) => _sisaStok(id, kecuali: awal),
        ),
      ),
    );
    if (hasil == null) return;
    setState(() {
      final i = awal == null ? -1 : _cart.indexOf(awal);
      if (i >= 0) {
        _cart[i] = hasil;
      } else {
        _cart.add(hasil);
      }
    });
  }

  void _bukaKeranjang() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          void ubah(VoidCallback f) {
            setState(f);
            setSheet(() {});
            if (_cart.isEmpty && ctx.mounted) Navigator.pop(ctx);
          }

          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.85),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(children: [
                    const Expanded(
                        child: Text('Rincian Pesanan',
                            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
                    TextButton(onPressed: () => ubah(_cart.clear), child: const Text('Kosongkan')),
                  ]),
                ),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    itemCount: _cart.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final c = _cart[i];
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Row(children: [
                            Expanded(
                                child: Text('${c.qty}x ${c.namaItem}',
                                    style: const TextStyle(fontWeight: FontWeight.bold))),
                            Text(rupiah(c.subtotal),
                                style: const TextStyle(fontWeight: FontWeight.bold)),
                          ]),
                          ...c.ringkasan.map((l) => Padding(
                                padding: const EdgeInsets.only(left: 8, top: 1),
                                child: Text(l, style: const TextStyle(fontSize: 12.5)),
                              )),
                          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                            IconButton(
                                icon: const Icon(Icons.edit_outlined),
                                onPressed: () async {
                                  Navigator.pop(ctx);
                                  await _buka(awal: c);
                                  if (mounted) _bukaKeranjang();
                                }),
                            IconButton(
                                icon: const Icon(Icons.delete_outline, color: Colors.red),
                                onPressed: () => ubah(() => _cart.removeAt(i))),
                          ]),
                        ]),
                      );
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(children: [
                    Expanded(
                        child: Text('Total ${rupiah(_total)}',
                            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
                    FilledButton.icon(
                      icon: const Icon(Icons.payments),
                      label: const Text('Bayar'),
                      onPressed: _cart.isEmpty
                          ? null
                          : () {
                              Navigator.pop(ctx);
                              _bayar();
                            },
                    ),
                  ]),
                ),
              ]),
            ),
          );
        },
      ),
    );
  }

  Future<void> _bayar() async {
    var metode = 'TUNAI';
    final uang = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) {
          final diterima = int.tryParse(uang.text.replaceAll('.', '')) ?? 0;
          return AlertDialog(
            title: Text('Bayar ${rupiah(_total)}'),
            content: Column(mainAxisSize: MainAxisSize.min, children: [
              SegmentedButton<String>(
                segments: kMetodeBayar.map((m) => ButtonSegment(value: m, label: Text(m))).toList(),
                selected: {metode},
                onSelectionChanged: (s) => setD(() => metode = s.first),
              ),
              if (metode == 'TUNAI') ...[
                const SizedBox(height: 12),
                TextField(
                  controller: uang,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Uang diterima (Rp)'),
                  onChanged: (_) => setD(() {}),
                ),
                const SizedBox(height: 8),
                Text(
                  diterima >= _total ? 'Kembalian ${rupiah(diterima - _total)}' : 'Uang kurang',
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: diterima >= _total ? Colors.green : Colors.red),
                ),
              ],
            ]),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
              FilledButton(
                onPressed: metode == 'TUNAI' && diterima < _total ? null : () => Navigator.pop(ctx, true),
                child: const Text('Selesaikan'),
              ),
            ],
          );
        },
      ),
    );
    final bayar = metode == 'TUNAI' ? int.tryParse(uang.text.replaceAll('.', '')) : null;
    uang.dispose();
    if (ok != true) return;
    try {
      final hasil = await widget.repo.simpanTransaksi(List.of(_cart), metodeBayar: metode);
      if (!mounted) return;
      setState(_cart.clear);
      await _muat(); // stok terbaru
      if (!mounted) return;
      await tampilkanStruk(context, widget.repo, hasil.id, bayar: bayar, autoCetak: true);
    } on StokTidakCukupException catch (e) {
      if (!mounted) return;
      await _dialogInfo('Stok tidak cukup', e.detail.join('\n'));
      await _muat();
    } on PosException catch (e) {
      if (!mounted) return;
      await _dialogInfo('Transaksi gagal', e.pesan);
    } catch (e) {
      if (!mounted) return;
      await _dialogInfo('Terjadi kesalahan', '$e');
    }
  }

  Future<void> _dialogInfo(String judul, String isi) => showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(judul),
          content: Text(isi),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
        ),
      );

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _katId == null || _mode != 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _katId = null);
      },
      child: Scaffold(
      appBar: AppBar(
        title: const Text('Kasir'),
        actions: [
          IconButton(
            tooltip: 'Riwayat & void',
            icon: const Icon(Icons.receipt_long),
            onPressed: () async {
              await Navigator.push(
                  context, MaterialPageRoute(builder: (_) => RiwayatPage(repo: widget.repo)));
              _muat();
            },
          ),
          IconButton(tooltip: 'Muat ulang', icon: const Icon(Icons.refresh), onPressed: _muat),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!)))
              : Column(children: [
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: SegmentedButton<int>(
                      segments: const [
                        ButtonSegment(value: 0, label: Text('Menu'), icon: Icon(Icons.restaurant_menu)),
                        ButtonSegment(value: 1, label: Text('Prasmanan'), icon: Icon(Icons.ramen_dining)),
                      ],
                      selected: {_mode},
                      onSelectionChanged: (s) => setState(() => _mode = s.first),
                    ),
                  ),
                  Expanded(child: _mode == 0 ? _daftarMenu() : _panelPrasmanan()),
                  _barKeranjang(),
                ]),
    ));
  }

  List<Menu> get _menuTampil {
    if (_katId == _kSemua) return _menus;
    if (_katId == _kTanpa) return _menus.where((m) => m.kategoriId == null).toList();
    return _menus.where((m) => m.kategoriId == _katId).toList();
  }

  Widget _daftarMenu() {
    if (_menus.isEmpty) return const Center(child: Text('Belum ada menu aktif. Tambah di tab Kelola.'));
    // Belum ada menu yang dikategorikan: tampilkan daftar biasa (perilaku lama).
    if (!_menus.any((m) => m.kategoriId != null)) return _listMenu(_menus);
    return _katId == null ? _gridKategori() : _isiKategori();
  }

  Widget _listMenu(List<Menu> list) => ListView.separated(
        itemCount: list.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (_, i) {
          final m = list[i];
          return ListTile(
            title: Text(m.nama, style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(rupiah(m.hargaJual)),
            trailing: const Icon(Icons.add_circle, color: Colors.deepOrange, size: 30),
            onTap: () => _buka(menu: m),
          );
        },
      );

  IconData _ikonKategori(String nama) {
    final kata = nama.toLowerCase().split(RegExp(r'\s+'));
    bool ada(List<String> k) => kata.any(k.contains);
    if (ada(['semua'])) return Icons.apps;
    if (ada(['tanpa'])) return Icons.label_off_outlined;
    if (ada(['es', 'teh', 'kopi', 'jus', 'minuman', 'susu'])) return Icons.local_drink;
    if (ada(['seblak', 'mie', 'bakso', 'soto'])) return Icons.ramen_dining;
    if (ada(['jajanan', 'snack', 'camilan', 'gorengan'])) return Icons.cookie;
    return Icons.restaurant_menu;
  }

  Widget _gridKategori() {
    final kartu = <({int id, String nama, int jumlah})>[
      (id: _kSemua, nama: 'Semua menu', jumlah: _menus.length),
      for (final k in _kategori)
        if (_menus.any((m) => m.kategoriId == k['id']))
          (
            id: k['id'] as int,
            nama: '${k['nama']}',
            jumlah: _menus.where((m) => m.kategoriId == k['id']).length
          ),
      if (_menus.any((m) => m.kategoriId == null))
        (id: _kTanpa, nama: 'Tanpa kategori', jumlah: _menus.where((m) => m.kategoriId == null).length),
    ];
    return GridView.count(
      crossAxisCount: 2,
      padding: const EdgeInsets.all(12),
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: 1.35,
      children: [
        for (final k in kartu)
          Card(
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => setState(() {
                _katId = k.id;
                _katNama = k.nama;
              }),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(_ikonKategori(k.nama), size: 34, color: Colors.deepOrange),
                  const SizedBox(height: 6),
                  Text(k.nama,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                  Text('${k.jumlah} menu', style: const TextStyle(fontSize: 12)),
                ]),
              ),
            ),
          ),
      ],
    );
  }

  Widget _isiKategori() {
    final list = _menuTampil;
    return Column(children: [
      ListTile(
        dense: true,
        leading: const Icon(Icons.arrow_back),
        title: Text('$_katNama • ${list.length} menu', style: const TextStyle(fontWeight: FontWeight.bold)),
        onTap: () => setState(() => _katId = null),
      ),
      const Divider(height: 1),
      Expanded(child: _listMenu(list)),
    ]);
  }

  Widget _panelPrasmanan() {
    final list = _bahanPrasmanan;
    return ListView(padding: const EdgeInsets.all(12), children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Seblak Prasmanan',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(
                'Customer memilih topping bebas. Harga = jumlah pilihan'
                '${_biayaDasar > 0 ? ' + biaya dasar ${rupiah(_biayaDasar)}' : ''}. '
                'Stok terpotong otomatis per bahan.',
                style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 10),
            FilledButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('Buat pesanan prasmanan'),
              onPressed: list.isEmpty ? null : () => _buka(),
            ),
            if (list.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('Belum ada bahan prasmanan. Aktifkan & isi harga di Kelola > Bahan.',
                    style: TextStyle(color: Colors.red, fontSize: 12)),
              ),
          ]),
        ),
      ),
      const Padding(
        padding: EdgeInsets.fromLTRB(4, 8, 4, 4),
        child: Text('Daftar topping & harga', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      ...list.map((b) => ListTile(
            dense: true,
            title: Text(b.nama),
            subtitle: Text(
                'Stok ${fmtQty(b.stok)} ${b.satuanDasar} • 1 pilihan = ${fmtQty(b.qtyPrasmanan)} ${b.satuanDasar}'),
            trailing: Text(rupiah(b.hargaPrasmanan), style: const TextStyle(fontWeight: FontWeight.bold)),
          )),
    ]);
  }

  Widget _barKeranjang() {
    return Material(
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('$_jumlahPorsi porsi • ${_cart.length} pesanan', style: const TextStyle(fontSize: 12)),
                Text(rupiah(_total), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              ]),
            ),
            FilledButton.icon(
              icon: const Icon(Icons.shopping_cart),
              label: const Text('Lihat pesanan'),
              onPressed: _cart.isEmpty ? null : _bukaKeranjang,
            ),
          ]),
        ),
      ),
    );
  }
}

// =====================================================================
// EDITOR ITEM: kustomisasi satu pesanan (menu tetap / prasmanan)
// =====================================================================
class ItemEditorPage extends StatefulWidget {
  final Menu? menu; // null = prasmanan
  final List<ResepItem> resep;
  final List<Bahan> bahanPrasmanan;
  final Map<int, Bahan> semuaBahan;
  final int biayaDasar;
  final CartItem? awal;
  final double Function(int bahanId) sisaStok;
  final List<VariasiGrup> grupVariasi;

  const ItemEditorPage({
    super.key,
    required this.menu,
    required this.resep,
    required this.bahanPrasmanan,
    required this.semuaBahan,
    required this.biayaDasar,
    required this.awal,
    required this.sisaStok,
    this.grupVariasi = const [],
  });

  @override
  State<ItemEditorPage> createState() => _ItemEditorPageState();
}

class _ItemEditorPageState extends State<ItemEditorPage> {
  int _qty = 1;
  final Set<int> _hapus = {};
  final Map<int, int> _pick = {};
  double _level = 0;
  bool _custom = false;
  final _customCtl = TextEditingController();
  final _catatanCtl = TextEditingController();
  String _kuah = kKuah[1];
  String _rasa = kRasa[0];

  // Variasi dinamis: grupId -> opsiId yang dipilih.
  final Map<int, Set<int>> _vPilih = {};
  // Bila menu punya variasi, Level/Kuah/Rasa/Topping lama disembunyikan
  // (digantikan kelompok variasi yang diatur di Kelola > Variasi).
  bool get _pakaiVariasi => widget.grupVariasi.isNotEmpty;

  bool get _prasmanan => widget.menu == null;

  @override
  void initState() {
    super.initState();
    final a = widget.awal;
    if (a != null) {
      _qty = a.qty;
      _hapus.addAll(a.resepDihapus);
      for (final t in a.topping) {
        _pick[t.bahan.id!] = t.pick;
      }
      _level = a.levelPedas.toDouble();
      final cu = a.levelCustom?.trim() ?? '';
      if (cu.isNotEmpty) {
        _custom = true;
        _customCtl.text = cu;
      }
      _kuah = kKuah.contains(a.kuah) ? a.kuah : kKuah[1];
      _rasa = kRasa.contains(a.rasa) ? a.rasa : kRasa[0];
      _catatanCtl.text = a.catatan;
      for (final v in a.variasi) {
        (_vPilih[v.grupId] ??= <int>{}).add(v.opsiId);
      }
    }
  }

  @override
  void dispose() {
    _customCtl.dispose();
    _catatanCtl.dispose();
    super.dispose();
  }

  CartItem _susun() => CartItem(
        menu: widget.menu,
        resep: widget.resep,
        resepDihapus: {..._hapus},
        topping: [
          for (final b in widget.bahanPrasmanan)
            if (!_pakaiVariasi && (_pick[b.id!] ?? 0) > 0) ToppingDipilih(b, _pick[b.id!]!),
        ],
        biayaDasar: widget.biayaDasar,
        levelPedas: _level.round(),
        levelCustom: _custom ? _customCtl.text : null,
        kuah: _kuah,
        rasa: _rasa,
        catatan: _catatanCtl.text,
        qty: _qty,
        variasi: susunPilihanVariasi(widget.grupVariasi, _vPilih),
        tampilkanLegacy: !_pakaiVariasi,
      );

  List<String> _kurang(CartItem c) {
    final out = <String>[];
    c.kebutuhanPerPorsi.forEach((id, q) {
      final sisa = widget.sisaStok(id);
      final butuh = q * c.qty;
      if (butuh > sisa + 1e-9) {
        final b = widget.semuaBahan[id];
        out.add(
            '${b?.nama ?? 'Bahan $id'}: butuh ${fmtQty(butuh)}, sisa ${fmtQty(sisa < 0 ? 0 : sisa)} ${b?.satuanDasar ?? ''}');
      }
    });
    return out;
  }

  bool _bolehTambah(Bahan b, CartItem c) {
    final sisa = widget.sisaStok(b.id!);
    final dipakai = (c.kebutuhanPerPorsi[b.id!] ?? 0) * c.qty;
    return sisa - dipakai + 1e-9 >= b.qtyPrasmanan * c.qty;
  }

  @override
  Widget build(BuildContext context) {
    final c = _susun();
    final kurang = _kurang(c);
    final kosongPrasmanan = _prasmanan && c.topping.isEmpty;
    final variasiBelum = variasiBelumLengkap(widget.grupVariasi, _vPilih);

    return Scaffold(
      appBar: AppBar(title: Text(_prasmanan ? 'Seblak Prasmanan' : widget.menu!.nama)),
      body: ListView(padding: const EdgeInsets.all(14), children: [
        _judul('Jumlah porsi'),
        Row(children: [
          IconButton.filledTonal(
              onPressed: _qty > 1 ? () => setState(() => _qty--) : null, icon: const Icon(Icons.remove)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Text('$_qty', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          ),
          IconButton.filledTonal(onPressed: () => setState(() => _qty++), icon: const Icon(Icons.add)),
        ]),
        if (!_prasmanan && widget.resep.isNotEmpty) ...[
          _judul('Bahan resep (matikan jika customer tidak mau)'),
          ...widget.resep.map((r) => SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(r.nama),
                subtitle: Text('${fmtQty(r.qty)} ${r.satuan} per porsi'),
                value: !_hapus.contains(r.bahanId),
                onChanged: (v) => setState(() => v ? _hapus.remove(r.bahanId) : _hapus.add(r.bahanId)),
              )),
        ],
        if (_pakaiVariasi)
          VariasiPilihan(
            grup: widget.grupVariasi,
            dipilih: _vPilih,
            onKetuk: (g, o) {
              ketukVariasi(context, g, o, _vPilih);
              setState(() {});
            },
          )
        else ...[
        _judul(_prasmanan ? 'Pilih topping / bahan' : 'Tambah / ganti topping (opsional)'),
        if (widget.bahanPrasmanan.isEmpty)
          const Text('Belum ada bahan prasmanan (atur di Kelola > Bahan).',
              style: TextStyle(color: Colors.red)),
        ...widget.bahanPrasmanan.map((b) {
          final p = _pick[b.id!] ?? 0;
          final sisa = widget.sisaStok(b.id!);
          return ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(b.nama, style: TextStyle(fontWeight: p > 0 ? FontWeight.bold : null)),
            subtitle: Text(
                '${rupiah(b.hargaPrasmanan)} / pilihan • sisa ${fmtQty(sisa < 0 ? 0 : sisa)} ${b.satuanDasar}'),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                  onPressed: p > 0 ? () => setState(() => _pick[b.id!] = p - 1) : null,
                  icon: const Icon(Icons.remove_circle_outline)),
              SizedBox(width: 24, child: Center(child: Text('$p'))),
              IconButton(
                  onPressed: _bolehTambah(b, c) ? () => setState(() => _pick[b.id!] = p + 1) : null,
                  icon: const Icon(Icons.add_circle_outline)),
            ]),
          );
        }),
        _judul('Level kepedasan'),
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Level custom (ketik sendiri)'),
          value: _custom,
          onChanged: (v) => setState(() => _custom = v),
        ),
        if (_custom)
          TextField(
            controller: _customCtl,
            decoration: const InputDecoration(hintText: 'mis. Level 15 / pedas banget', isDense: true),
            onChanged: (_) => setState(() {}),
          )
        else
          Row(children: [
            Expanded(
              child: Slider(
                min: 0,
                max: 10,
                divisions: 10,
                label: 'Level ${_level.round()}',
                value: _level,
                onChanged: (v) => setState(() => _level = v),
              ),
            ),
            SizedBox(width: 70, child: Text('Level ${_level.round()}')),
          ]),
        _judul('Porsi / jumlah kuah'),
        _chips(kKuah, _kuah, (v) => setState(() => _kuah = v)),
        _judul('Rasa'),
        _chips(kRasa, _rasa, (v) => setState(() => _rasa = v)),
        ],
        _judul('Catatan khusus'),
        TextField(
          controller: _catatanCtl,
          maxLines: 2,
          decoration: const InputDecoration(hintText: 'mis. bumbu dipisah, tanpa bawang', isDense: true),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 120),
      ]),
      bottomSheet: Material(
        elevation: 12,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (kurang.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text('Stok tidak cukup:\n${kurang.join('\n')}',
                      style: const TextStyle(color: Colors.red, fontSize: 12)),
                ),
              if (variasiBelum.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text('Pilih dulu: ${variasiBelum.join(', ')}',
                      style: const TextStyle(color: Colors.red, fontSize: 12)),
                ),
              if (kosongPrasmanan)
                const Padding(
                  padding: EdgeInsets.only(bottom: 6),
                  child: Text('Pilih minimal satu topping.', style: TextStyle(color: Colors.red, fontSize: 12)),
                ),
              Row(children: [
                Expanded(
                    child: Text(rupiah(c.subtotal),
                        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold))),
                FilledButton(
                  onPressed: kurang.isNotEmpty || kosongPrasmanan || variasiBelum.isNotEmpty
                      ? null
                      : () => Navigator.pop(context, c),
                  child: Text(widget.awal == null ? 'Tambah ke pesanan' : 'Simpan perubahan'),
                ),
              ]),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _judul(String t) => Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 6),
        child: Text(t, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
      );

  Widget _chips(List<String> opsi, String terpilih, void Function(String) onPilih) => Wrap(
        spacing: 6,
        runSpacing: 4,
        children: opsi
            .map((o) => ChoiceChip(label: Text(o), selected: o == terpilih, onSelected: (_) => onPilih(o)))
            .toList(),
      );
}

// =====================================================================
// STRUK & RIWAYAT
// =====================================================================
Future<void> tampilkanStruk(
  BuildContext context,
  PosRepository repo,
  int id, {
  int? bayar,
  bool bisaVoid = false,
  bool autoCetak = false,
  VoidCallback? onVoid,
}) async {
  final Struk s;
  try {
    s = await repo.ambilStruk(id);
  } catch (e) {
    if (context.mounted) snack(context, '$e');
    return;
  }
  if (!context.mounted) return;
  final cfg = await PrinterService.instance.muatPengaturan(repo);
  final teks = teksStruk(s,
      namaKedai: cfg.namaKedai, lebar: cfg.lebar, footer: cfg.footer, bayar: bayar);
  if (autoCetak && cfg.otomatis && cfg.mac.isNotEmpty) {
    final err = await PrinterService.instance.cetak(repo, teks);
    if (context.mounted) snack(context, err ?? 'Struk dicetak');
  }
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(s.status == 'VOID' ? 'Struk (VOID)' : 'Struk'),
      content: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SingleChildScrollView(
          child: SelectableText(teks, style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5)),
        ),
      ),
      actions: [
        if (bisaVoid && s.status == 'SELESAI')
          TextButton(
            onPressed: () async {
              final yakin = await showDialog<bool>(
                context: ctx,
                builder: (c2) => AlertDialog(
                  title: const Text('Void transaksi?'),
                  content: const Text('Nota dibatalkan dan stok bahan dikembalikan.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(c2, false), child: const Text('Tidak')),
                    FilledButton(onPressed: () => Navigator.pop(c2, true), child: const Text('Void')),
                  ],
                ),
              );
              if (yakin != true) return;
              try {
                await repo.voidTransaksi(id);
                if (ctx.mounted) Navigator.pop(ctx);
                onVoid?.call();
              } catch (e) {
                if (ctx.mounted) snack(ctx, '$e');
              }
            },
            child: const Text('Void', style: TextStyle(color: Colors.red)),
          ),
        TextButton(
          onPressed: () async {
            final err = await PrinterService.instance.cetak(repo, teks);
            if (ctx.mounted) snack(ctx, err ?? 'Struk dicetak');
          },
          child: const Text('Cetak'),
        ),
        TextButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: teks));
            if (ctx.mounted) snack(ctx, 'Struk disalin');
          },
          child: const Text('Salin'),
        ),
        FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Tutup')),
      ],
    ),
  );
}

class RiwayatPage extends StatefulWidget {
  final PosRepository repo;
  const RiwayatPage({super.key, required this.repo});
  @override
  State<RiwayatPage> createState() => _RiwayatPageState();
}

class _RiwayatPageState extends State<RiwayatPage> {
  late Future<List<RingkasTransaksi>> _f = _muat();

  Future<List<RingkasTransaksi>> _muat() {
    final now = DateTime.now();
    String dua(int v) => v.toString().padLeft(2, '0');
    return widget.repo.riwayatTransaksi(tanggal: '${now.year}-${dua(now.month)}-${dua(now.day)}');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Transaksi hari ini')),
      body: FutureBuilder<List<RingkasTransaksi>>(
        future: _f,
        builder: (context, snap) {
          if (snap.hasError) return Center(child: Text('${snap.error}'));
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final data = snap.data!;
          if (data.isEmpty) return const Center(child: Text('Belum ada transaksi hari ini'));
          return ListView.separated(
            itemCount: data.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final t = data[i];
              final batal = t.status == 'VOID';
              return ListTile(
                title: Text(t.noNota,
                    style: TextStyle(decoration: batal ? TextDecoration.lineThrough : null)),
                subtitle: Text('${t.waktu} • ${t.metode}${batal ? ' • VOID' : ''}'),
                trailing: Text(rupiah(t.total), style: const TextStyle(fontWeight: FontWeight.bold)),
                onTap: () => tampilkanStruk(context, widget.repo, t.id,
                    bisaVoid: true, onVoid: () => setState(() => _f = _muat())),
              );
            },
          );
        },
      ),
    );
  }
}
