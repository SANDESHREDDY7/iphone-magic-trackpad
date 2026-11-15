import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'discovery_base.dart';

class PlatformDiscoveryService implements DiscoveryService {
  RawDatagramSocket? _socket;
  Timer? _probeTimer;

  @override
  void startDiscovery(void Function(Map<String, dynamic> host) onHostFound) async {
    try {
      _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _socket!.broadcastEnabled = true;

      _socket!.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          final datagram = _socket!.receive();
          if (datagram != null) {
            try {
              final text = utf8.decode(datagram.data).trim();
              final json = jsonDecode(text);
              if (json is Map<String, dynamic> && json['magic'] == 'MAGIC_TRACKPAD_SERVER') {
                if (json['ip'] == null || json['ip'] == 'localhost') {
                  json['ip'] = datagram.address.address;
                }
                onHostFound(json);
              }
            } catch (_) {}
          }
        }
      });

      _sendProbe();
      _probeTimer = Timer.periodic(const Duration(seconds: 3), (_) => _sendProbe());
    } catch (_) {}
  }

  void _sendProbe() {
    try {
      final data = utf8.encode('MAGIC_TRACKPAD_DISCOVER');
      _socket?.send(data, InternetAddress('255.255.255.255'), 3001);
    } catch (_) {}
  }

  @override
  void stopDiscovery() {
    _probeTimer?.cancel();
    _socket?.close();
    _socket = null;
  }
}

DiscoveryService getDiscoveryService() => PlatformDiscoveryService();
