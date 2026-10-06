import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:remotex/app/remote_x_services.dart';
import 'package:remotex/features/controller/presentation/controller_home_screen.dart';
import 'package:remotex/features/host/presentation/host_home_screen.dart';
import 'package:remotex/features/web/presentation/web_remote_screen.dart';

class RemoteXApp extends StatelessWidget {
  RemoteXApp({super.key, this.targetPlatform, RemoteXServices? services})
    : services = services ?? RemoteXServices.create();

  final TargetPlatform? targetPlatform;
  final RemoteXServices services;

  @override
  Widget build(BuildContext context) {
    final Widget home;
    if (kIsWeb) {
      home = WebRemoteScreen(services: services);
    } else {
      home = switch (targetPlatform ?? defaultTargetPlatform) {
        TargetPlatform.android => ControllerHomeScreen(services: services),
        TargetPlatform.windows => HostHomeScreen(services: services),
        _ => WebRemoteScreen(services: services),
      };
    }

    return MaterialApp(
      title: 'RemoteX',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF3468F6),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF0B1020),
        useMaterial3: true,
      ),
      home: home,
    );
  }
}
