// printer_service.dart — cetak struk ke printer thermal Bluetooth (ESC/POS).
// Perintah ESC/POS ditulis langsung (tanpa paket tambahan) agar ringan & minim risiko.
import 'package:permission_handler/permission_handler.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';

import 'pos_repository.dart';

class PrinterCfg {
  final String mac;
  final String nama;
  final String namaKedai;
  final String footer;
  final int lebar; // karakter per baris: 32 = kertas 58 mm, 48 = kertas 80 mm
  final bool otomatis;
  const PrinterCfg({
    required this.mac,
    required this.nama,
    required this.namaKedai,
    required this.footer,
    required this.lebar,
    required this.otomatis,
  });
}

class PrinterService {
  PrinterService._();
  static final PrinterService instance = PrinterService._();

  // ---------------------------------------------------------- pengaturan

  Future<PrinterCfg> muatPengaturan(PosRepository repo) async {
    final lebar = int.tryParse(await repo.getPengaturan('printer_lebar') ?? '') ?? 32;
    return PrinterCfg(
      mac: await repo.getPengaturan('printer_mac') ?? '',
      nama: await repo.getPengaturan('printer_nama') ?? '',
      namaKedai: await repo.getPengaturan('nama_kedai') ?? 'KEDAI SEBLAK',
      footer: await repo.getPengaturan('struk_footer') ?? 'Terima kasih!',
      lebar: lebar == 48 ? 48 : 32,
      otomatis: (await repo.getPengaturan('printer_otomatis')) == '1',
    );
  }

  // ---------------------------------------------------------- bluetooth

  Future<void> mintaIzin() async {
    try {
      await [Permission.bluetoothConnect, Permission.bluetoothScan].request();
    } catch (_) {
      // Android lama tidak butuh izin runtime ini.
    }
  }

  Future<List<BluetoothInfo>> daftarPerangkat() async {
    await mintaIzin();
    return PrintBluetoothThermal.pairedBluetooths;
  }

  Future<bool> bluetoothAktif() => PrintBluetoothThermal.bluetoothEnabled;

  Future<bool> tersambung() => PrintBluetoothThermal.connectionStatus;

  Future<bool> sambung(String mac) async {
    await mintaIzin();
    return PrintBluetoothThermal.connect(macPrinterAddress: mac);
  }

  Future<void> putus() async {
    await PrintBluetoothThermal.disconnect;
  }

  // ---------------------------------------------------------- cetak

  /// Mengembalikan null jika sukses, atau pesan error yang bisa ditampilkan ke kasir.
  Future<String?> cetak(PosRepository repo, String teks, {int? lebar}) async {
    final cfg = await muatPengaturan(repo);
    if (cfg.mac.isEmpty) return 'Printer belum dipilih (Kelola > Printer)';
    try {
      await mintaIzin();
      if (!await bluetoothAktif()) return 'Bluetooth HP mati. Nyalakan dulu.';
      var ok = await tersambung();
      if (!ok) ok = await sambung(cfg.mac);
      if (!ok) {
        return 'Tidak bisa terhubung ke ${cfg.nama.isEmpty ? 'printer' : cfg.nama}. '
            'Pastikan printer menyala, dekat, dan izin Bluetooth diizinkan.';
      }
      final sukses = await PrintBluetoothThermal.writeBytes(bangunBytes(teks, lebar ?? cfg.lebar));
      return sukses ? null : 'Data gagal dikirim ke printer';
    } catch (e) {
      return 'Gagal mencetak: $e';
    }
  }

  // ---------------------------------------------------------- ESC/POS

  /// Baris pertama = judul (rata tengah, tebal). Sisanya rata kiri.
  List<int> bangunBytes(String teks, int lebar) {
    final b = <int>[0x1B, 0x40]; // inisialisasi printer
    final baris = teks.split('\n');
    while (baris.isNotEmpty && baris.last.trim().isEmpty) {
      baris.removeLast();
    }
    for (var i = 0; i < baris.length; i++) {
      final judul = i == 0;
      if (judul) b.addAll([0x1B, 0x61, 0x01, 0x1B, 0x45, 0x01]); // tengah + tebal
      for (final l in _bungkus(baris[i], lebar)) {
        b.addAll(_ascii(l));
        b.add(0x0A);
      }
      if (judul) b.addAll([0x1B, 0x45, 0x00, 0x1B, 0x61, 0x00]); // normal
    }
    b.addAll([0x1B, 0x64, 0x04]); // maju 4 baris
    b.addAll([0x1D, 0x56, 0x42, 0x00]); // potong (diabaikan jika tanpa pemotong)
    return b;
  }

  List<String> _bungkus(String line, int lebar) {
    if (line.length <= lebar) return [line];
    final indentN = (line.length - line.trimLeft().length).clamp(0, 6);
    final indent = ' ' * indentN;
    final hasil = <String>[line.substring(0, lebar)];
    var sisa = line.substring(lebar);
    final isi = lebar - indentN;
    while (sisa.isNotEmpty) {
      final potong = sisa.length > isi ? isi : sisa.length;
      hasil.add('$indent${sisa.substring(0, potong)}');
      sisa = sisa.substring(potong);
    }
    return hasil;
  }

  List<int> _ascii(String s) =>
      s.runes.map((r) => (r >= 32 && r < 127) ? r : (r == 9 ? 32 : 63)).toList();
}
