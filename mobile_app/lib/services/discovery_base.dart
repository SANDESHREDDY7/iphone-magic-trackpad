abstract class DiscoveryService {
  void startDiscovery(void Function(Map<String, dynamic> host) onHostFound);
  void stopDiscovery();
}
