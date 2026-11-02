// main.dart: titik masuk aplikasi, inisialisasi database, dan navigasi utama.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'pos_repository.dart';
import 'kasir_screen.dart' show KasirScreen;
import 'dashboard_screen.dart' show DashboardScreen;
import 'manajemen_screen.dart' show ManajemenScreen;

/// Memecah schema.sql jadi pernyataan satu per satu
/// (sqflite hanya menjalankan satu pernyataan per execute).
/// Blok TRIGGER dianggap satu kesatuan sampai baris "END;".
List<String> pecahSql(String sql) {
  final hasil = <String>[];
  final buf = StringBuffer();
  var trigger = false;
  for (final raw in sql.split('\n')) {
    final line = raw.replaceAll(RegExp(r'--.*$'), '').trimRight();
    final t = line.trim();
    if (t.isEmpty || t.toUpperCase().startsWith('PRAGMA')) continue;
    if (buf.isEmpty && t.toUpperCase().startsWith('CREATE TRIGGER')) trigger = true;
    buf.writeln(line);
    final selesai = trigger ? t.toUpperCase() == 'END;' : t.endsWith(';');
    if (selesai) {
      hasil.add(buf.toString().trim());
      buf.clear();
      trigger = false;
    }
  }
  return hasil;
}

Future<Database> bukaDatabase() async {
  final path = p.join(await getDatabasesPath(), 'kedai.db');
  return openDatabase(
    path,
    version: 1,
    onConfigure: (db) async => db.execute('PRAGMA foreign_keys = ON'),
    onCreate: (db, _) async {
      final sql = await rootBundle.loadString('assets/schema.sql');
      for (final s in pecahSql(sql)) {
        await db.execute(s);
      }
    },
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final db = await bukaDatabase();
    runApp(KedaiApp(repo: PosRepository(db)));
  } catch (e) {
    runApp(MaterialApp(
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Gagal membuka database:\n$e', textAlign: TextAlign.center),
          ),
        ),
      ),
    ));
  }
}

class KedaiApp extends StatelessWidget {
  final PosRepository repo;
  const KedaiApp({super.key, required this.repo});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Kedai POS',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.deepOrange,
      ),
      home: HomeShell(repo: repo),
    );
  }
}

class HomeShell extends StatefulWidget {
  final PosRepository repo;
  const HomeShell({super.key, required this.repo});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  // Layar dibangun ulang tiap pindah tab agar data selalu terbaru.
  // Selesaikan pesanan di Kasir sebelum pindah tab (keranjang ikut ter-reset).
  Widget _halaman() {
    switch (_tab) {
      case 1:
        return DashboardScreen(key: const ValueKey('dash'), repo: widget.repo);
      case 2:
        return ManajemenScreen(key: const ValueKey('kelola'), repo: widget.repo);
      default:
        return KasirScreen(key: const ValueKey('kasir'), repo: widget.repo);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _halaman(),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.point_of_sale), label: 'Kasir'),
          NavigationDestination(icon: Icon(Icons.dashboard), label: 'Dashboard'),
          NavigationDestination(icon: Icon(Icons.inventory_2), label: 'Kelola'),
        ],
      ),
    );
  }
}

