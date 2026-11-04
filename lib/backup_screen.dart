// backup_screen.dart — Cadangkan & pulihkan seluruh data kedai
// (bahan, stok, menu, resep, transaksi, pengaturan) dalam satu berkas.
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import 'pos_repository.dart';

class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key});
  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  final _repo = PosRepository();
  bool _sibuk = false;

  void _pesan(String teks) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(teks)));
  }

  Future<void> _ekspor() async {
    setState(() => _sibuk = true);
    try {
      final path = await _repo.eksporDatabase();
      await Share.shareXFiles(
        [XFile(path)],
        text: 'Cadangan data kedai',
        subject: 'Cadangan data kedai',
      );
    } on PosException catch (e) {
      _pesan(e.pesan);
    } catch (e) {
      _pesan('Gagal membuat cadangan: $e');
    } finally {
      if (mounted) setState(() => _sibuk = false);
    }
  }

  Future<void> _impor() async {
    final hasil = await FilePicker.platform.pickFiles(type: FileType.any);
    final path = hasil?.files.single.path;
    if (path == null) return;
    if (!mounted) return;

    final yakin = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Pulihkan data?'),
        content: const Text(
            'SEMUA data di aplikasi ini akan diganti dengan isi berkas cadangan.\n\n'
            'Aplikasi akan menutup sendiri setelah selesai. Buka lagi untuk memakai data hasil pemulihan.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Pulihkan')),
        ],
      ),
    );
    if (yakin != true) return;

    setState(() => _sibuk = true);
    try {
      await _repo.imporDatabase(path);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('Pemulihan selesai'),
          content: const Text('Aplikasi akan ditutup. Buka lagi untuk melihat data.'),
          actions: [
            FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Tutup aplikasi')),
          ],
        ),
      );
      await SystemNavigator.pop();
    } on PosException catch (e) {
      _pesan(e.pesan);
    } catch (e) {
      _pesan('Gagal memulihkan: $e');
    } finally {
      if (mounted) setState(() => _sibuk = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Cadangan data')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Buat cadangan', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              const Text(
                  'Membuat satu berkas berisi semua data kedai. Kirim ke Google Drive, WhatsApp '
                  '(chat ke diri sendiri), atau simpan ke Files. Lakukan sebelum uninstall atau ganti HP.'),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _sibuk ? null : _ekspor,
                icon: const Icon(Icons.upload_file),
                label: const Text('Buat & bagikan cadangan'),
              ),
            ]),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Pulihkan dari cadangan', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              const Text(
                  'Pilih berkas cadangan (.db) dari HP. Data yang ada sekarang akan DIGANTI. '
                  'Aplikasi menutup sendiri setelah selesai.'),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _sibuk ? null : _impor,
                icon: const Icon(Icons.download),
                label: const Text('Pilih berkas & pulihkan'),
              ),
            ]),
          ),
        ),
        if (_sibuk)
          const Padding(
            padding: EdgeInsets.only(top: 24),
            child: Center(child: CircularProgressIndicator()),
          ),
      ]),
    );
  }
}
