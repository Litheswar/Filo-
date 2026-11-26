import 'package:flutter/material.dart';

import '../app/filo_services.dart';
import '../app/filo_theme.dart';
import '../screens/activity_screen.dart';
import '../screens/convert_screen.dart';
import '../screens/library_screen.dart';
import '../screens/settings_screen.dart';
import '../widgets/filo_logo.dart';

class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.services,
    this.themeMode = ThemeMode.system,
    this.onThemeModeChanged,
  });

  final FiloServices services;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode>? onThemeModeChanged;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _selectedIndex = 0;
  final Set<int> _visitedDestinations = {0};

  @override
  Widget build(BuildContext context) {
    final pages = [
      LibraryScreen(
        services: widget.services,
        onConvert: () => _selectDestination(1),
      ),
      ConvertScreen(
        services: widget.services,
        onOpenLibrary: () => _selectDestination(0),
      ),
      ActivityScreen(
        activityManager: widget.services.activityManager,
        activityChanges: widget.services.activityChanges,
        isActive: _selectedIndex == 2,
      ),
      SettingsScreen(
        fileStorage: widget.services.fileStorage,
        activityManager: widget.services.activityManager,
        isActive: _selectedIndex == 3,
        managedStorageChanges: widget.services.managedStorageChanges,
        onManagedStorageChanged: widget.services.notifyManagedStorageChanged,
        filePickerConsentStore: widget.services.filePickerConsentStore,
        themeMode: widget.themeMode,
        onThemeModeChanged: widget.onThemeModeChanged,
        onActivityHistoryChanged: () => widget.services.activityChanges.value++,
      ),
    ];
    return PopScope(
      canPop: _selectedIndex == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selectedIndex != 0) _selectDestination(0);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Row(
            children: [
              const FiloLogo(size: 30),
              const SizedBox(width: FiloSpacing.sm),
              Text(
                ['Library', 'Convert', 'Activity', 'Settings'][_selectedIndex],
              ),
            ],
          ),
          actions: [
            IconButton(
              tooltip: 'About local privacy',
              onPressed: () => Navigator.of(context).pushNamed('/welcome'),
              icon: const Icon(Icons.shield_outlined),
            ),
            const SizedBox(width: FiloSpacing.sm),
          ],
        ),
        body: IndexedStack(
          index: _selectedIndex,
          children: [
            for (var index = 0; index < pages.length; index++)
              _visitedDestinations.contains(index)
                  ? pages[index]
                  : const SizedBox.shrink(),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _selectedIndex,
          onDestinationSelected: _selectDestination,
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.folder_outlined),
              selectedIcon: Icon(Icons.folder_rounded),
              label: 'Library',
            ),
            NavigationDestination(
              icon: Icon(Icons.swap_horiz_rounded),
              selectedIcon: Icon(Icons.swap_horiz_rounded),
              label: 'Convert',
            ),
            NavigationDestination(
              icon: Icon(Icons.history_rounded),
              selectedIcon: Icon(Icons.history_rounded),
              label: 'Activity',
            ),
            NavigationDestination(
              icon: Icon(Icons.tune_rounded),
              selectedIcon: Icon(Icons.tune_rounded),
              label: 'Settings',
            ),
          ],
        ),
      ),
    );
  }

  void _selectDestination(int index) {
    if (index == _selectedIndex) return;
    setState(() {
      _selectedIndex = index;
      _visitedDestinations.add(index);
    });
  }
}
