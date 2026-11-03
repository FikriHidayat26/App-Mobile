// printer_screen.dart — tab "Printer" di Kelola: pilih printer Bluetooth, ukuran kertas,
// nama & footer struk, cetak otomatis, serta tes untuk mengetahui lebar kertas.
import 'package:flutter/material.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';

import 'helpers.dart';
import 'models.dart';
import 'pos_repository.dart';
import 'printer_service.dart';

class PrinterTab extends StatefulWidget {
  final PosRepository repo;
  const PrinterTab({super.key, required this.repo});
  @override
  State<PrinterTab> createState() => _PrinterTabState();
}

class _PrinterTabState extends State<PrinterTab> {
  final _svc = PrinterService.instance;
  final _namaKedai = TextEditingController();
  final _footer = TextEditingController();
  String _mac = '';
  String _namaPrinter = '';
  int _lebar = 32;
  bool _otomatis = false;
  bool _siap = false;
  bool _sibuk = false;
  Future<List<BluetoothInfo>>? _perangkat;

  @override
  void initState() {
    super.initState();
    _muat();
  }

  @override
  void dispose() {
    _namaKedai.dispose();
    _footer.dispose();
    super.dispose();
  }

  Future<void> _muat() async {
    final c = await _svc.muatPengaturan(widget.repo);
    if (!mounted) return;
    setState(() {
      _namaKedai.text = c.namaKedai;
      _footer.text = c.footer;
      _mac = c.mac;
      _namaPrinter = c.nama;
      _lebar = c.lebar;
      _otomatis = c.otomatis;
      _siap = true;
    });
  }

  Future<void> _simpan({bool tampilkanPesan = true}) async {
    final r = widget.repo;
    await r.setPengaturan('nama_kedai', _namaKedai.text.trim().isEmpty ? 'KEDAI SEBLAK' : _namaKedai.text.trim());
    await r.setPengaturan('struk_footer', _footer.text.trim());
    await r.setPengaturan('printer_mac', _mac);
    await r.setPengaturan('printer_nama', _namaPrinter);
    await r.setPengaturan('printer_lebar', '$_lebar');
    await r.setPengaturan('printer_otomatis', _otomatis ? '1' : '0');
    if (tampilkanPesan && mounted) snack(context, 'Pengaturan printer disimpan');
  }

  Future<void> _jalankan(Future<String?> Function() aksi, String sukses) async {
    setState(() => _sibuk = true);
    await _simpan(tampilkanPesan: false);
    final err = await aksi();
    if (!mounted) return;
    setState(() => _sibuk = false);
    snack(context, err ?? sukses);
  }

  Future<void> _cariPerangkat() async {
    final f = _svc.daftarPerangkat();
    setState(() => _perangkat = f);
  }

  Future<void> _pilih(BluetoothInfo p) async {
    setState(() {
      _mac = p.macAdress;
      _namaPrinter = p.name;
      _sibuk = true;
    });
    await _simpan(tampilkanPesan: false);
    await _svc.putus();
    final ok = await _svc.sambung(p.macAdress);
    if (!mounted) return;
    setState(() => _sibuk = false);
    snack(context, ok ? 'Terhubung ke ${p.name}' : 'Gagal terhubung. Pastikan printer menyala & sudah di-pairing.');
  }

  String get _strukContoh {
    final s = Struk(
      id: 0,
      noNota: 'KS-TES-001',
      waktu: DateTime.now().toString().substring(0, 16),
      metode: 'TUNAI',
      total: 27000,
      status: 'SELESAI',
      items: const [
        StrukItem(
          tipe: 'PRASMANAN',
          nama: 'Seblak Prasmanan',
          qty: 1,
          hargaSatuan: 15000,
          levelPedas: 'Level 5',
          kuah: 'Kuah banyak',
          rasa: 'Gurih manis',
          catatan: 'bumbu dipisah',
          topping: [
            StrukTopping('Sosis ayam', 'PRASMANAN', 2, 5000),
            StrukTopping('Cikuwa', 'PRASMANAN', 1, 2500),
          ],
        ),
        StrukItem(
            tipe: 'MENU',
            nama: 'Seblak Umume',
            qty: 1,
            hargaSatuan: 12000,
            levelPedas: 'Level 3',
            kuah: 'Nyemek (kuah kental sedikit)',
            rasa: 'Original/Sedang'),
      ],
    );
    return teksStruk(s,
        namaKedai: _namaKedai.text.trim().isEmpty ? 'KEDAI SEBLAK' : _namaKedai.text.trim(),
        lebar: _lebar,
        footer: _footer.text.trim(),
        bayar: 30000);
  }

  static const String _teksTesLebar = 'TES LEBAR KERTAS\n'
      'Baris A (32 karakter):\n'
      '12345678901234567890123456789012\n'
      'Baris B (48 karakter):\n'
      '123456789012345678901234567890123456789012345678\n'
      'Jika baris B terpotong atau turun ke baris baru = kertas 58 mm.\n'
      'Jika baris B utuh satu baris = kertas 80 mm.\n';

  @override
  Widget build(BuildContext context) {
    if (!_siap) return const Center(child: CircularProgressIndicator());
    return ListView(padding: const EdgeInsets.all(12), children: [
      Card(
        child: ListTile(
          leading: const Icon(Icons.print),
          title: Text(_mac.isEmpty ? 'Belum ada printer dipilih' : _namaPrinter),
          subtitle: Text(_mac.isEmpty ? 'Pilih dari daftar di bawah' : _mac),
        ),
      ),
      const SizedBox(height: 8),
      const Text('1. Ukuran kertas', style: TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(height: 6),
      SegmentedButton<int>(
        segments: const [
          ButtonSegment(value: 32, label: Text('58 mm')),
          ButtonSegment(value: 48, label: Text('80 mm')),
        ],
        selected: {_lebar},
        onSelectionChanged: (s) => setState(() => _lebar = s.first),
      ),
      const Padding(
        padding: EdgeInsets.only(top: 4, bottom: 4),
        child: Text(
            'Belum tahu ukurannya? Hubungkan printer, lalu tekan "Tes lebar kertas". '
            'Kertas 58 mm paling umum untuk printer kecil/portabel.',
            style: TextStyle(fontSize: 12)),
      ),
      OutlinedButton.icon(
        icon: const Icon(Icons.straighten),
        label: const Text('Tes lebar kertas'),
        onPressed: _sibuk || _mac.isEmpty
            ? null
            : () => _jalankan(() => _svc.cetak(widget.repo, _teksTesLebar, lebar: 48), 'Tes lebar dicetak'),
      ),
      const SizedBox(height: 16),
      const Text('2. Pilih printer (sudah di-pairing di Bluetooth HP)',
          style: TextStyle(fontWeight: FontWeight.bold)),
      const Padding(
        padding: EdgeInsets.symmetric(vertical: 4),
        child: Text(
            'Nyalakan printer, buka Pengaturan > Bluetooth HP, pairing dulu (PIN biasanya 0000 atau 1234), '
            'lalu kembali ke sini.',
            style: TextStyle(fontSize: 12)),
      ),
      FilledButton.tonalIcon(
        icon: const Icon(Icons.bluetooth_searching),
        label: const Text('Tampilkan printer terpasang'),
        onPressed: _sibuk ? null : _cariPerangkat,
      ),
      if (_perangkat != null)
        FutureBuilder<List<BluetoothInfo>>(
          future: _perangkat,
          builder: (context, snap) {
            if (snap.hasError) return Padding(padding: const EdgeInsets.all(8), child: Text('${snap.error}'));
            if (!snap.hasData) {
              return const Padding(padding: EdgeInsets.all(12), child: Center(child: CircularProgressIndicator()));
            }
            final list = snap.data!;
            if (list.isEmpty) {
              return const Padding(
                padding: EdgeInsets.all(8),
                child: Text('Tidak ada perangkat. Pastikan Bluetooth menyala, izin diberikan, dan printer sudah di-pairing.',
                    style: TextStyle(color: Colors.red, fontSize: 12)),
              );
            }
            return Column(
              children: list
                  .map((p) => ListTile(
                        leading: Icon(Icons.print, color: p.macAdress == _mac ? Colors.green : null),
                        title: Text(p.name),
                        subtitle: Text(p.macAdress),
                        trailing: p.macAdress == _mac
                            ? const Icon(Icons.check_circle, color: Colors.green)
                            : const Text('Pilih'),
                        onTap: _sibuk ? null : () => _pilih(p),
                      ))
                  .toList(),
            );
          },
        ),
      const SizedBox(height: 16),
      const Text('3. Tampilan struk', style: TextStyle(fontWeight: FontWeight.bold)),
      TextField(
          controller: _namaKedai,
          decoration: const InputDecoration(labelText: 'Nama kedai (judul struk)'),
          onChanged: (_) => setState(() {})),
      TextField(
          controller: _footer,
          decoration: const InputDecoration(labelText: 'Teks bawah struk'),
          onChanged: (_) => setState(() {})),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Cetak otomatis setelah pembayaran'),
        value: _otomatis,
        onChanged: (v) => setState(() => _otomatis = v),
      ),
      const Text('Pratinjau (sesuai lebar kertas):', style: TextStyle(fontSize: 12)),
      Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.all(8),
        color: Colors.grey.shade200,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Text(_strukContoh,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5, color: Colors.black87)),
        ),
      ),
      Row(children: [
        Expanded(
          child: OutlinedButton(onPressed: _sibuk ? null : _simpan, child: const Text('Simpan')),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: FilledButton.icon(
            icon: const Icon(Icons.receipt),
            label: const Text('Tes cetak struk'),
            onPressed: _sibuk || _mac.isEmpty
                ? null
                : () => _jalankan(() => _svc.cetak(widget.repo, _strukContoh, lebar: _lebar), 'Struk contoh dicetak'),
          ),
        ),
      ]),
      if (_sibuk) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
    ]);
  }
}
