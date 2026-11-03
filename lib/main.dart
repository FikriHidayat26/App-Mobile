// main.dart: titik masuk aplikasi, inisialisasi database, dan navigasi utama.
import 'package:flutter/material.dart';

import 'database_helper.dart';
import 'pos_repository.dart';
import 'kasir_screen.dart' show KasirScreen;
import 'dashboard_screen.dart' show DashboardScreen;
import 'manajemen_screen.dart' show ManajemenScreen;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    // Membuka DB, membuat skema baru / memigrasi data lama otomatis.
    await DatabaseHelper.instance.database;
    runApp(KedaiApp(repo: PosRepository()));
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
