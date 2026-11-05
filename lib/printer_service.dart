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

  /// Baris pertama = judul (rata tengah, tebal). Footer (setelah garis pemisah terakhir) rata tengah,
  /// rincian "kiri ... Rp harga" diratakan ke tepi kertas, sisanya rata kiri.
  List<int> bangunBytes(String teks, int lebar) {
    final b = <int>[0x1B, 0x40]; // inisialisasi printer
    final baris = teks.split('\n');
    while (baris.isNotEmpty && baris.last.trim().isEmpty) {
      baris.removeLast();
    }

    // Baris rincian = teks di kiri, harga rupiah di kanan (mis. "1x Seblak     Rp 12.000").
    final barisHarga = RegExp(r'^(.*\S)\s+(-?Rp\s?[\d.]+)$');
    bool pemisah(String t) => t.startsWith('---') || t.startsWith('===');
    // Setelah garis pemisah terakhir (TOTAL, Bayar, Kembali, lalu footer) -> footer rata tengah.
    final akhirPemisah = baris.lastIndexWhere((l) => pemisah(l.trim()));

    for (var i = 0; i < baris.length; i++) {
      final line = baris[i];
      final trimmed = line.trim();
      final lower = trimmed.toLowerCase();
      final cocokHarga = barisHarga.firstMatch(line.trimRight());
      final adaHarga = cocokHarga != null;
      final footer = akhirPemisah >= 0 && i > akhirPemisah && trimmed.isNotEmpty && !adaHarga;

      // 1. Judul (baris pertama), ucapan terima kasih / lunas, atau baris *** -> RATA TENGAH
      //    (kalimat panjang dipecah per kata, tiap baris tetap di tengah)
      if (i == 0 ||
          footer ||
          trimmed.contains('***') ||
          (!adaHarga && (lower.contains('terima kasih') || lower.contains('lunas')))) {
        b.addAll([0x1B, 0x61, 0x01]); // rata tengah
        if (i == 0) b.addAll([0x1B, 0x45, 0x01]); // tebal khusus baris pertama
        for (final l in _bungkusKata(trimmed, lebar)) {
          b.addAll(_ascii(l));
          b.add(0x0A);
        }
        if (i == 0) b.addAll([0x1B, 0x45, 0x00]); // matikan tebal
      }
      // 2. Garis pemisah (--- / ===) -> penuh selebar kertas
      else if (pemisah(trimmed)) {
        b.addAll([0x1B, 0x61, 0x01]);
        b.addAll(_ascii('-' * lebar));
        b.add(0x0A);
      }
      // 3. Rincian "kiri ... Rp harga" -> rata kiri-kanan, indent dipertahankan
      else if (adaHarga) {
        b.addAll([0x1B, 0x61, 0x00]); // rata kiri
        final indent = line.substring(0, line.length - line.trimLeft().length);
        final kiri = '$indent${cocokHarga.group(1)!.trimLeft()}';
        final kanan = cocokHarga.group(2)!;
        for (final l in _kiriKanan(kiri, kanan, lebar)) {
          b.addAll(_ascii(l));
          b.add(0x0A);
        }
      }
      // 4. Baris biasa / catatan / keterangan -> rata kiri
      else {
        b.addAll([0x1B, 0x61, 0x00]);
        for (final l in _bungkus(line, lebar)) {
          b.addAll(_ascii(l));
          b.add(0x0A);
        }
      }
    }

    b.addAll([0x1B, 0x61, 0x00]); // kembalikan rata kiri
    b.addAll([0x1B, 0x64, 0x04]); // maju 4 baris
    b.addAll([0x1D, 0x56, 0x42, 0x00]); // potong (diabaikan jika tanpa pemotong)
    return b;
  }

  /// Meratakan teks ke tepi kiri & kanan kertas. Jika terlalu panjang, bagian kiri
  /// dibungkus dan bagian kanan tetap rata kanan (tidak ada yang terpotong).
  List<String> _kiriKanan(String kiri, String kanan, int lebar) {
    if (kiri.length + 1 + kanan.length <= lebar) {
      return [kiri + (' ' * (lebar - kiri.length - kanan.length)) + kanan];
    }
    final kiriBaris = _bungkus(kiri, lebar);
    final akhir = kiriBaris.last;
    if (akhir.length + 1 + kanan.length <= lebar) {
      kiriBaris[kiriBaris.length - 1] =
          akhir + (' ' * (lebar - akhir.length - kanan.length)) + kanan;
      return kiriBaris;
    }
    final pad = lebar - kanan.length;
    return [...kiriBaris, (' ' * (pad < 0 ? 0 : pad)) + kanan];
  }

  /// Bungkus per karakter (mempertahankan indent) untuk baris rata kiri.
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

  /// Bungkus per kata, untuk teks rata tengah (judul, footer, ucapan).
  List<String> _bungkusKata(String s, int lebar) {
    final hasil = <String>[];
    var cur = '';
    for (final k in s.split(' ')) {
      if (cur.isEmpty) {
        cur = k;
      } else if (cur.length + 1 + k.length <= lebar) {
        cur = '$cur $k';
      } else {
        hasil.add(cur);
        cur = k;
      }
    }
    if (cur.isNotEmpty) hasil.add(cur);
    // Kata tunggal yang lebih panjang dari lebar kertas dipotong paksa.
    final akhir = <String>[];
    for (final h in hasil) {
      var x = h;
      while (x.length > lebar) {
        akhir.add(x.substring(0, lebar));
        x = x.substring(lebar);
      }
      akhir.add(x);
    }
    return akhir;
  }

  List<int> _ascii(String s) =>
      s.runes.map((r) => (r >= 32 && r < 127) ? r : (r == 9 ? 32 : 63)).toList();
}
