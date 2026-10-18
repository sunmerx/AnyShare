import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:localsend_app/config/init.dart';
import 'package:localsend_app/config/theme.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/pages/home_page_controller.dart';
import 'package:localsend_app/pages/tabs/blocklist_tab.dart';
import 'package:localsend_app/pages/tabs/device_list_tab.dart';
import 'package:localsend_app/pages/tabs/my_devices_tab.dart';
import 'package:localsend_app/pages/tabs/settings_tab.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/util/native/cross_file_converters.dart';
import 'package:localsend_app/widget/responsive_builder.dart';
import 'package:localsend_app/widget/transfer_panel.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// AnyShare modification (2026-10-18): home navigation redesigned (UI-1).
/// Four zones: My Devices / Devices / Blocklist / Settings.
enum HomeTab {
  myDevices(Icons.devices),
  deviceList(Icons.grid_view),
  blocklist(Icons.block),
  settings(Icons.settings)
  ;

  const HomeTab(this.icon);

  final IconData icon;

  String get label {
    switch (this) {
      case HomeTab.myDevices:
        return t.ui2.nav.myDevices;
      case HomeTab.deviceList:
        return t.ui2.nav.deviceList;
      case HomeTab.blocklist:
        return t.ui2.nav.blocklist;
      case HomeTab.settings:
        return t.ui2.nav.settings;
    }
  }
}

class HomePage extends StatefulWidget {
  final HomeTab initialTab;

  /// It is important for the initializing step
  /// because the first init clears the cache
  final bool appStart;

  const HomePage({
    required this.initialTab,
    required this.appStart,
    super.key,
  });

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with Refena {
  bool _dragAndDropIndicator = false;

  @override
  void initState() {
    super.initState();

    ensureRef((ref) async {
      ref.redux(homePageControllerProvider).dispatch(ChangeTabAction(widget.initialTab));
      await postInit(context, ref, widget.appStart);
    });
  }

  @override
  Widget build(BuildContext context) {
    Translations.of(context); // rebuild on locale change
    final vm = context.watch(homePageControllerProvider);

    return DropTarget(
      onDragEntered: (_) {
        setState(() {
          _dragAndDropIndicator = true;
        });
      },
      onDragExited: (_) {
        setState(() {
          _dragAndDropIndicator = false;
        });
      },
      onDragDone: (event) async {
        // the drop may contain a mix of files and directories
        final droppedDirectories = event.files.where((file) => Directory(file.path).existsSync()).toList();
        final droppedFiles = event.files.where((file) => !Directory(file.path).existsSync()).toList();

        for (final directory in droppedDirectories) {
          await ref.redux(selectedSendingFilesProvider).dispatchAsync(AddDirectoryAction(directory.path));
        }

        if (droppedFiles.isNotEmpty) {
          await ref
              .redux(selectedSendingFilesProvider)
              .dispatchAsync(
                AddFilesAction(
                  files: droppedFiles,
                  converter: CrossFileConverters.convertXFile,
                ),
              );
        }
        // UI-1: dropped files are sent by picking a device on the devices page.
        vm.changeTab(HomeTab.deviceList);
      },
      child: ResponsiveBuilder(
        builder: (sizingInformation) {
          return Scaffold(
            body: Row(
              children: [
                if (!sizingInformation.isMobile)
                  Container(
                    color: Theme.of(context).cardColorWithElevation,
                    // Fixed width (extended rail is 256, compact is 72): the
                    // transfer section must not stretch the rail with long
                    // file names.
                    width: sizingInformation.isDesktop ? 256 : 72,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: NavigationRail(
                            selectedIndex: vm.currentTab.index,
                            onDestinationSelected: (index) => vm.changeTab(HomeTab.values[index]),
                            extended: sizingInformation.isDesktop,
                            scrollable: true,
                            backgroundColor: Colors.transparent,
                            leading: sizingInformation.isDesktop
                                ? const Column(
                                    children: [
                                      SizedBox(height: 20),
                                      Text(
                                        'AnyShare',
                                        style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
                                        textAlign: TextAlign.center,
                                      ),
                                      SizedBox(height: 20),
                                    ],
                                  )
                                : null,
                            destinations: HomeTab.values.map((tab) {
                              return NavigationRailDestination(
                                icon: Icon(tab.icon),
                                label: Text(tab.label),
                              );
                            }).toList(),
                          ),
                        ),
                        // UI-3: transfer panel pinned under the rail.
                        TransferRailSection(compact: !sizingInformation.isDesktop),
                      ],
                    ),
                  ),
                Expanded(
                  child: SafeArea(
                    left: sizingInformation.isMobile,
                    child: Stack(
                      children: [
                        PageView(
                          controller: vm.controller,
                          physics: const NeverScrollableScrollPhysics(),
                          children: const [
                            MyDevicesTab(),
                            DeviceListTab(),
                            BlocklistTab(),
                            SettingsTab(),
                          ],
                        ),
                        if (_dragAndDropIndicator)
                          Container(
                            width: double.infinity,
                            decoration: BoxDecoration(
                              color: Theme.of(context).scaffoldBackgroundColor,
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(Icons.file_download, size: 128),
                                const SizedBox(height: 30),
                                Text(t.sendTab.placeItems, style: Theme.of(context).textTheme.titleLarge),
                              ],
                            ),
                          ),
                        // UI-3: mobile transfer pill above the navigation bar.
                        if (sizingInformation.isMobile)
                          const Positioned(
                            right: 16,
                            bottom: 16,
                            child: TransferPill(),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            bottomNavigationBar: sizingInformation.isMobile
                ? NavigationBar(
                    selectedIndex: vm.currentTab.index,
                    onDestinationSelected: (index) => vm.changeTab(HomeTab.values[index]),
                    destinations: HomeTab.values.map((tab) {
                      return NavigationDestination(icon: Icon(tab.icon), label: tab.label);
                    }).toList(),
                  )
                : null,
          );
        },
      ),
    );
  }
}
