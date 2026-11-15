import 'discovery_base.dart';

class PlatformDiscoveryService implements DiscoveryService {
  @override
  void startDiscovery(void Function(Map<String, dynamic> host) onHostFound) {}

  @override
  void stopDiscovery() {}
}

DiscoveryService getDiscoveryService() => PlatformDiscoveryService();
