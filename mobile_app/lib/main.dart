import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;
import 'services/discovery.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarBrightness: Brightness.dark,
    statusBarIconBrightness: Brightness.light,
  ));
  runApp(const MagicTrackpadApp());
}

class MagicTrackpadApp extends StatelessWidget {
  const MagicTrackpadApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Magic Trackpad Pro',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF08090D),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF0A84FF),
          secondary: Color(0xFF30D158),
          surface: Color(0xFF161822),
        ),
        fontFamily: '-apple-system',
      ),
      home: const TrackpadHomeScreen(),
    );
  }
}

class TrackpadHomeScreen extends StatefulWidget {
  const TrackpadHomeScreen({super.key});

  @override
  State<TrackpadHomeScreen> createState() => _TrackpadHomeScreenState();
}

class _TrackpadHomeScreenState extends State<TrackpadHomeScreen> with WidgetsBindingObserver {
  final TextEditingController _ipController = TextEditingController();
  final TextEditingController _textInputController = TextEditingController();
  final TextEditingController _pinController = TextEditingController();

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;

  // Auto-Discovery Service
  late final DiscoveryService _discoveryService;
  final Map<String, Map<String, dynamic>> _discoveredHosts = {};

  bool _isConnected = false;
  bool _isConnecting = false;
  bool _isReconnecting = false;
  String _statusMessage = '';

  // Host system information reported by server
  String _targetOs = 'mac';
  String _targetHostname = '';
  List<String> _recentHosts = [];
  String? _lastConnectedIp;

  // Preferences & Settings
  double _sensitivity = 2.0;
  bool _hapticsEnabled = true;
  bool _naturalScroll = true;
  bool _cursorAcceleration = true;

  // Active view on mobile deck: 0 = Mouse buttons, 1 = Media controls, 2 = Keyboard
  int _activeDeckTab = 0;

  // Touch tracking state
  final Map<int, Offset> _activePointers = {};
  Offset? _lastFirstPointerPos;
  Offset? _startFirstPointerPos;
  int _touchStartTime = 0;
  bool _hasMoved = false;
  int _lastTapTime = 0;

  // Drag tracking
  Timer? _dragTimer;
  bool _isDragging = false;

  // 2-finger scroll
  double _scrollAccumulator = 0.0;

  // 3-finger swipe
  Offset? _startThreeFingerAvg;
  bool _threeFingerFired = false;

  // Visual touch ripple
  Offset? _ripplePos;

  // Heartbeat & Auto-reconnect timers
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadSavedData();
    _initDiscovery();
  }

  void _initDiscovery() {
    _discoveryService = getDiscoveryService();
    _discoveryService.startDiscovery((host) {
      final ip = host['ip']?.toString();
      if (ip != null && ip.isNotEmpty) {
        if (!mounted) return;
        setState(() {
          _discoveredHosts[ip] = host;
        });
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Re-trigger discovery and silent reconnect if connection was dropped in background
      _discoveryService.startDiscovery((host) {});
      if (!_isConnected && _lastConnectedIp != null && !_isConnecting) {
        _silentReconnect();
      }
    }
  }

  Future<void> _loadSavedData() async {
    final prefs = await SharedPreferences.getInstance();
    final savedIp = prefs.getString('saved_mac_ip');
    final recents = prefs.getStringList('recent_hosts') ?? [];
    final natScroll = prefs.getBool('natural_scroll') ?? true;
    final accel = prefs.getBool('cursor_acceleration') ?? true;

    setState(() {
      _recentHosts = recents;
      _naturalScroll = natScroll;
      _cursorAcceleration = accel;
      if (savedIp != null && savedIp.isNotEmpty) {
        _ipController.text = savedIp;
      } else if (recents.isNotEmpty) {
        _ipController.text = recents.first;
      }
    });
  }

  Future<void> _saveHost(String ip) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('saved_mac_ip', ip);
    _lastConnectedIp = ip;

    final recents = List<String>.from(_recentHosts);
    recents.remove(ip);
    recents.insert(0, ip);
    if (recents.length > 5) recents.removeLast();

    setState(() => _recentHosts = recents);
    await prefs.setStringList('recent_hosts', recents);
  }

  void _triggerHaptic([String type = 'light']) {
    if (!_hapticsEnabled) return;
    switch (type) {
      case 'medium':
        HapticFeedback.mediumImpact();
        break;
      case 'heavy':
        HapticFeedback.heavyImpact();
        break;
      case 'selection':
        HapticFeedback.selectionClick();
        break;
      default:
        HapticFeedback.lightImpact();
    }
  }

  void _connect([String? specificIp]) async {
    final rawIp = (specificIp ?? _ipController.text).trim();
    if (rawIp.isEmpty) {
      setState(() => _statusMessage = 'Please enter an IP address');
      return;
    }

    setState(() {
      _isConnecting = true;
      _statusMessage = 'Connecting to $rawIp...';
    });

    String url;
    if (rawIp.contains('ngrok')) {
      url = rawIp.startsWith('ws') ? rawIp : 'wss://$rawIp';
    } else if (rawIp.startsWith('ws://') || rawIp.startsWith('wss://')) {
      url = rawIp;
    } else {
      url = 'ws://$rawIp:3000';
    }

    try {
      _disconnect(isDisposing: false);
      final uri = Uri.parse(url);
      _channel = WebSocketChannel.connect(uri);

      _subscription = _channel!.stream.listen(
        (message) => _handleIncomingMessage(message, rawIp),
        onDone: () => _handleConnectionLoss(rawIp),
        onError: (error) => _handleConnectionLoss(rawIp),
      );

      // Start ping heartbeat
      _heartbeatTimer?.cancel();
      _heartbeatTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        _send({'type': 'ping'});
      });

      // Pause to establish
      await Future.delayed(const Duration(milliseconds: 350));

      if (mounted) {
        setState(() {
          _isConnected = true;
          _isConnecting = false;
          _isReconnecting = false;
          _statusMessage = '';
        });
        _saveHost(rawIp);
        _triggerHaptic('medium');

        // Check if we have an authentication token saved for this computer
        final prefs = await SharedPreferences.getInstance();
        final token = prefs.getString('auth_token_$rawIp');
        if (token != null) {
          _send({'type': 'auth', 'token': token});
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isConnected = false;
          _isConnecting = false;
          _statusMessage = 'Connection failed: $e';
        });
      }
    }
  }

  void _handleIncomingMessage(dynamic message, String hostIp) async {
    try {
      final data = jsonDecode(message);
      if (data is! Map) return;

      final type = data['type'];

      if (type == 'handshake' || type == 'system_info') {
        setState(() {
          _targetOs = (data['os'] ?? 'mac').toString().toLowerCase();
          _targetHostname = (data['hostname'] ?? '').toString();
        });

        final requirePin = data['requirePin'] == true;
        final authenticated = data['authenticated'] == true;

        if (requirePin && !authenticated) {
          final prefs = await SharedPreferences.getInstance();
          final token = prefs.getString('auth_token_$hostIp');
          if (token != null) {
            _send({'type': 'auth', 'token': token});
          } else {
            _showPinDialog(hostIp);
          }
        }
      } else if (type == 'auth_required') {
        _showPinDialog(hostIp);
      } else if (type == 'auth_success') {
        if (data['token'] != null) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('auth_token_$hostIp', data['token'].toString());
        }
        if (mounted && Navigator.canPop(context)) {
          Navigator.pop(context);
        }
        _triggerHaptic('medium');
      } else if (type == 'auth_failed') {
        _triggerHaptic('heavy');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(data['message'] ?? 'Incorrect PIN'),
            backgroundColor: const Color(0xFFFF453A),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (_) {}
  }

  void _handleConnectionLoss(String hostIp) {
    _heartbeatTimer?.cancel();
    if (!mounted) return;

    if (_isConnected) {
      setState(() {
        _isConnected = false;
        _isReconnecting = true;
        _statusMessage = 'Connection lost. Auto-reconnecting...';
      });
      _scheduleAutoReconnect(hostIp);
    }
  }

  void _scheduleAutoReconnect(String hostIp) {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 2), () {
      if (!_isConnected && mounted) {
        _silentReconnect();
      }
    });
  }

  void _silentReconnect() {
    if (_lastConnectedIp != null && !_isConnected && !_isConnecting) {
      _connect(_lastConnectedIp);
    }
  }

  void _disconnect({bool isDisposing = false}) {
    _subscription?.cancel();
    _subscription = null;
    _heartbeatTimer?.cancel();
    _reconnectTimer?.cancel();
    _channel?.sink.close(ws_status.goingAway);
    _channel = null;
    _isConnected = false;
    _isConnecting = false;
    _isReconnecting = false;
    if (mounted && !isDisposing) {
      setState(() {});
    }
  }

  void _send(Map<String, dynamic> data) {
    if (_channel != null && _isConnected) {
      try {
        _channel!.sink.add(jsonEncode(data));
      } catch (_) {}
    }
  }

  // --- 4-Digit Security PIN Dialog ---
  void _showPinDialog(String hostIp) {
    _pinController.clear();
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF161822),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
          ),
          title: const Row(
            children: [
              Icon(Icons.lock_rounded, color: Color(0xFF0A84FF), size: 22),
              SizedBox(width: 8),
              Text('Security Pairing', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Enter the 4-digit PIN shown on your computer screen to pair securely:',
                style: TextStyle(fontSize: 13, color: Colors.white70),
              ),
              const SizedBox(height: 18),
              TextField(
                controller: _pinController,
                autofocus: true,
                keyboardType: TextInputType.number,
                maxLength: 4,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 28, letterSpacing: 10, fontWeight: FontWeight.bold),
                decoration: InputDecoration(
                  counterText: '',
                  hintText: '••••',
                  filled: true,
                  fillColor: Colors.black.withValues(alpha: 0.4),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide.none,
                  ),
                ),
                onSubmitted: (val) {
                  _send({'type': 'auth', 'pin': val.trim()});
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                _disconnect();
              },
              child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0A84FF),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: () {
                _send({'type': 'auth', 'pin': _pinController.text.trim()});
              },
              child: const Text('Pair Device'),
            ),
          ],
        );
      },
    );
  }

  // --- Multi-Touch Gesture Detection ---
  void _onPointerDown(PointerDownEvent event) {
    _activePointers[event.pointer] = event.localPosition;
    final pointerCount = _activePointers.length;

    setState(() {
      _ripplePos = event.localPosition;
    });

    if (pointerCount == 1) {
      _touchStartTime = DateTime.now().millisecondsSinceEpoch;
      _lastFirstPointerPos = event.localPosition;
      _startFirstPointerPos = event.localPosition;
      _hasMoved = false;

      _dragTimer?.cancel();
      _dragTimer = Timer(const Duration(milliseconds: 350), () {
        if (!_hasMoved && _activePointers.length == 1) {
          setState(() => _isDragging = true);
          _send({'type': 'drag_start'});
          _triggerHaptic('heavy');
          _lastTapTime = 0;
        }
      });
    } else {
      _dragTimer?.cancel();
    }

    if (pointerCount == 3) {
      double totalX = 0, totalY = 0;
      for (final p in _activePointers.values) {
        totalX += p.dx;
        totalY += p.dy;
      }
      _startThreeFingerAvg = Offset(totalX / 3, totalY / 3);
      _threeFingerFired = false;
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    _activePointers[event.pointer] = event.localPosition;
    final pointerCount = _activePointers.length;

    setState(() {
      _ripplePos = event.localPosition;
    });

    if (pointerCount == 1 && _lastFirstPointerPos != null) {
      var dx = event.localPosition.dx - _lastFirstPointerPos!.dx;
      var dy = event.localPosition.dy - _lastFirstPointerPos!.dy;

      if (_startFirstPointerPos != null) {
        final totalDist = (event.localPosition - _startFirstPointerPos!).distance;
        if (totalDist > 8) {
          _hasMoved = true;
          if (!_isDragging) {
            _dragTimer?.cancel();
          }
        }
      }

      // Cursor Acceleration curve
      if (_cursorAcceleration) {
        final speed = math.sqrt(dx * dx + dy * dy);
        final accelFactor = speed > 5.0 ? math.min(2.2, 1.0 + (speed - 5.0) * 0.08) : 1.0;
        dx *= accelFactor;
        dy *= accelFactor;
      }

      _send({
        'type': 'touch_move',
        'dx': dx * _sensitivity,
        'dy': dy * _sensitivity,
      });

      _lastFirstPointerPos = event.localPosition;
    } else if (pointerCount == 2) {
      _scrollAccumulator += event.delta.dy;
      if (_scrollAccumulator.abs() > 14) {
        // Natural scroll orientation check
        final rawDir = _scrollAccumulator > 0 ? 'up' : 'down';
        final actualDir = _naturalScroll ? rawDir : (rawDir == 'up' ? 'down' : 'up');

        _send({
          'type': 'scroll',
          'dir': actualDir,
        });
        _scrollAccumulator = 0;
      }
    } else if (pointerCount == 3 && _startThreeFingerAvg != null && !_threeFingerFired) {
      double totalX = 0, totalY = 0;
      for (final p in _activePointers.values) {
        totalX += p.dx;
        totalY += p.dy;
      }
      final currentAvg = Offset(totalX / 3, totalY / 3);
      final delta = currentAvg - _startThreeFingerAvg!;

      const threshold = 35.0;
      if (delta.dy < -threshold) {
        _send({'type': 'swipe', 'dir': 'up'});
        _threeFingerFired = true;
        _triggerHaptic('medium');
      } else if (delta.dy > threshold) {
        _send({'type': 'swipe', 'dir': 'down'});
        _threeFingerFired = true;
        _triggerHaptic('medium');
      } else if (delta.dx < -threshold) {
        _send({'type': 'swipe', 'dir': 'left'});
        _threeFingerFired = true;
        _triggerHaptic('medium');
      } else if (delta.dx > threshold) {
        _send({'type': 'swipe', 'dir': 'right'});
        _threeFingerFired = true;
        _triggerHaptic('medium');
      }
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    final pointerCountBeforeRemove = _activePointers.length;
    _activePointers.remove(event.pointer);

    if (_activePointers.isEmpty) {
      setState(() => _ripplePos = null);
    }

    _dragTimer?.cancel();

    if (_isDragging) {
      setState(() => _isDragging = false);
      _send({'type': 'drag_end'});
      _triggerHaptic('medium');
      return;
    }

    if (pointerCountBeforeRemove == 1 && _activePointers.isEmpty) {
      final duration = DateTime.now().millisecondsSinceEpoch - _touchStartTime;
      if (!_hasMoved && duration < 320) {
        final now = DateTime.now().millisecondsSinceEpoch;
        final timeSinceLastTap = now - _lastTapTime;

        if (timeSinceLastTap > 0 && timeSinceLastTap < 380) {
          _send({'type': 'double_click'});
          _triggerHaptic('medium');
          _lastTapTime = 0;
        } else {
          _send({'type': 'click'});
          _triggerHaptic('light');
          _lastTapTime = now;
        }
      }
    } else if (pointerCountBeforeRemove == 2 && _activePointers.isEmpty) {
      final duration = DateTime.now().millisecondsSinceEpoch - _touchStartTime;
      if (!_hasMoved && duration < 350) {
        _send({'type': 'rightclick'});
        _triggerHaptic('medium');
      }
    }

    if (_activePointers.isEmpty) {
      _lastFirstPointerPos = null;
      _startFirstPointerPos = null;
      _startThreeFingerAvg = null;
      _scrollAccumulator = 0;
      _hasMoved = false;
    }
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _activePointers.remove(event.pointer);
    if (_activePointers.isEmpty) {
      setState(() {
        _ripplePos = null;
        _isDragging = false;
      });
      _dragTimer?.cancel();
    }
  }

  void _showSettingsDialog() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF161822),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Trackpad Settings', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.pop(context),
                      )
                    ],
                  ),
                  const SizedBox(height: 12),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Natural Scrolling'),
                    subtitle: const Text('Content moves in direction of fingers (Mac default)', style: TextStyle(fontSize: 12)),
                    value: _naturalScroll,
                    activeTrackColor: const Color(0xFF0A84FF),
                    onChanged: (val) async {
                      setModalState(() => _naturalScroll = val);
                      setState(() => _naturalScroll = val);
                      final prefs = await SharedPreferences.getInstance();
                      await prefs.setBool('natural_scroll', val);
                      _triggerHaptic('selection');
                    },
                  ),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Cursor Acceleration'),
                    subtitle: const Text('Small movements are precise, fast flings traverse displays', style: TextStyle(fontSize: 12)),
                    value: _cursorAcceleration,
                    activeTrackColor: const Color(0xFF0A84FF),
                    onChanged: (val) async {
                      setModalState(() => _cursorAcceleration = val);
                      setState(() => _cursorAcceleration = val);
                      final prefs = await SharedPreferences.getInstance();
                      await prefs.setBool('cursor_acceleration', val);
                      _triggerHaptic('selection');
                    },
                  ),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Haptic Feedback'),
                    subtitle: const Text('Physical vibration on clicks, taps, and gestures', style: TextStyle(fontSize: 12)),
                    value: _hapticsEnabled,
                    activeTrackColor: const Color(0xFF0A84FF),
                    onChanged: (val) {
                      setModalState(() => _hapticsEnabled = val);
                      setState(() => _hapticsEnabled = val);
                      _triggerHaptic('light');
                    },
                  ),
                  const SizedBox(height: 14),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _showGesturesDialog() {
    final isWin = _targetOs == 'windows';

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF161822),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        final gestures = [
          {'name': '1-Finger Move', 'action': 'Move Cursor'},
          {'name': '1-Finger Tap', 'action': 'Left Click'},
          {'name': 'Double Tap', 'action': 'Double Click'},
          {'name': 'Tap & Hold (350ms)', 'action': 'Click & Drag'},
          {'name': '2-Finger Tap', 'action': 'Right Click'},
          {'name': '2-Finger Slide', 'action': 'Scroll Page'},
          {
            'name': '3-Finger Swipe Up',
            'action': isWin ? 'Task View (Win+Tab)' : 'Mission Control',
          },
          {
            'name': '3-Finger Swipe Down',
            'action': isWin ? 'Show Desktop (Win+D)' : 'App Exposé',
          },
          {
            'name': '3-Finger Left/Right',
            'action': isWin ? 'Switch Desktops (Ctrl+Win)' : 'Switch Spaces',
          },
        ];

        return Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Icon(
                        isWin ? Icons.window_rounded : Icons.apple_rounded,
                        color: const Color(0xFF0A84FF),
                        size: 24,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        isWin ? 'Windows Gestures' : 'macOS Gestures',
                        style: const TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  )
                ],
              ),
              const SizedBox(height: 12),
              ...gestures.map((g) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 7.0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(g['name']!, style: const TextStyle(color: Colors.white70, fontSize: 13)),
                        Text(
                          g['action']!,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF0A84FF),
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  )),
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }

  void _sendKey(String key, [List<String>? modifiers]) {
    final payload = <String, dynamic>{
      'type': 'key_tap',
      'key': key,
    };
    if (modifiers != null) {
      payload['modifiers'] = modifiers;
    }
    _send(payload);
    _triggerHaptic('light');
  }

  void _sendTypedText(String text) {
    if (text.isEmpty) return;
    _send({
      'type': 'type_text',
      'text': text,
    });
    _triggerHaptic('selection');
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _discoveryService.stopDiscovery();
    _disconnect(isDisposing: true);
    _ipController.dispose();
    _textInputController.dispose();
    _pinController.dispose();
    _dragTimer?.cancel();
    _heartbeatTimer?.cancel();
    _reconnectTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isTabletOrDesktop = screenWidth >= 650;

    return Scaffold(
      body: SafeArea(
        child: _isConnected
            ? (isTabletOrDesktop ? _buildTabletControlView() : _buildPhoneControlView())
            : _buildConnectView(),
      ),
    );
  }

  // =========================================================================
  // CONNECT SCREEN (WITH AUTO-DISCOVERY & PAIRING)
  // =========================================================================
  Widget _buildConnectView() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(
                  color: const Color(0xFF161822),
                  borderRadius: BorderRadius.circular(26),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF0A84FF).withValues(alpha: 0.3),
                      blurRadius: 30,
                      offset: const Offset(0, 10),
                    )
                  ],
                ),
                child: const Icon(
                  Icons.touch_app_rounded,
                  size: 44,
                  color: Color(0xFF0A84FF),
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'Magic Trackpad Pro',
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, letterSpacing: -0.5),
              ),
              const SizedBox(height: 4),
              const Text(
                'Wireless remote for Mac & Windows',
                style: TextStyle(color: Colors.white54, fontSize: 13),
              ),
              const SizedBox(height: 28),

              // AUTO-DISCOVERED COMPUTERS ON LOCAL WI-FI
              if (_discoveredHosts.isNotEmpty) ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: Row(
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: const BoxDecoration(
                          color: Color(0xFF30D158),
                          shape: BoxShape.circle,
                          boxShadow: [BoxShadow(color: Color(0xFF30D158), blurRadius: 6)],
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        'FOUND ON YOUR WI-FI (TAP TO CONNECT)',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.7,
                          color: Color(0xFF30D158),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                ..._discoveredHosts.values.map((host) {
                  final hostname = host['hostname'] ?? 'Computer';
                  final ip = host['ip'] ?? '';
                  final isMac = host['os'] == 'mac';

                  return Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF161822),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: const Color(0xFF30D158).withValues(alpha: 0.3)),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Icon(
                              isMac ? Icons.apple_rounded : Icons.window_rounded,
                              size: 22,
                              color: const Color(0xFF0A84FF),
                            ),
                            const SizedBox(width: 12),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  hostname,
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                                ),
                                Text(
                                  ip,
                                  style: const TextStyle(color: Colors.white38, fontSize: 12),
                                ),
                              ],
                            ),
                          ],
                        ),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF30D158),
                            foregroundColor: Colors.black,
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          onPressed: () {
                            _triggerHaptic('medium');
                            _ipController.text = ip;
                            _connect(ip);
                          },
                          child: const Text('Connect', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                        )
                      ],
                    ),
                  );
                }),
                const SizedBox(height: 14),
              ],

              // MANUAL IP CONNECTION CARD
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: const Color(0xFF161822),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'CONNECT VIA IP OR DOMAIN',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.8,
                        color: Colors.white54,
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _ipController,
                      keyboardType: TextInputType.text,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                      decoration: InputDecoration(
                        hintText: 'e.g. 192.168.1.4',
                        hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.3)),
                        filled: true,
                        fillColor: Colors.black.withValues(alpha: 0.4),
                        contentPadding: const EdgeInsets.symmetric(vertical: 14),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: const BorderSide(color: Color(0xFF0A84FF), width: 1.5),
                        ),
                      ),
                      onSubmitted: (val) => _connect(),
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: ElevatedButton(
                        onPressed: _isConnecting
                            ? null
                            : () {
                                _triggerHaptic('medium');
                                _connect();
                              },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF0A84FF),
                          foregroundColor: Colors.white,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        child: _isConnecting
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                            : const Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text('Connect to Computer', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                                  SizedBox(width: 8),
                                  Icon(Icons.arrow_forward_rounded, size: 17),
                                ],
                              ),
                      ),
                    ),
                    if (_statusMessage.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Center(
                        child: Text(
                          _statusMessage,
                          style: const TextStyle(
                            color: Color(0xFFFF453A),
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ]
                  ],
                ),
              ),

              // Recent Computers Chips
              if (_recentHosts.isNotEmpty) ...[
                const SizedBox(height: 20),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'RECENT COMPUTERS',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.8,
                      color: Colors.white.withValues(alpha: 0.4),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _recentHosts.map((host) {
                    return ActionChip(
                      backgroundColor: const Color(0xFF161822),
                      side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
                      label: Text(host, style: const TextStyle(fontSize: 12)),
                      avatar: const Icon(Icons.devices_rounded, size: 15, color: Color(0xFF0A84FF)),
                      onPressed: () {
                        _triggerHaptic('light');
                        _ipController.text = host;
                        _connect(host);
                      },
                    );
                  }).toList(),
                )
              ]
            ],
          ),
        ),
      ),
    );
  }

  // =========================================================================
  // PHONE CONTROL VIEW (PORTRAIT)
  // =========================================================================
  Widget _buildPhoneControlView() {
    return Padding(
      padding: const EdgeInsets.all(12.0),
      child: Column(
        children: [
          _buildTopBar(),
          const SizedBox(height: 10),
          Expanded(child: _buildTrackpadArea()),
          const SizedBox(height: 10),
          _buildDeckTabs(),
          const SizedBox(height: 10),
          _buildActiveDeckContent(),
        ],
      ),
    );
  }

  // =========================================================================
  // TABLET / IPAD / DESKTOP CONTROL VIEW (LANDSCAPE / SPLIT)
  // =========================================================================
  Widget _buildTabletControlView() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        children: [
          _buildTopBar(),
          const SizedBox(height: 12),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(flex: 3, child: _buildTrackpadArea()),
                const SizedBox(width: 16),
                Expanded(
                  flex: 2,
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xFF161822),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                    ),
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildSensitivitySlider(),
                          const SizedBox(height: 16),
                          _buildMouseButtonsRow(),
                          const SizedBox(height: 10),
                          _buildScrollButtonsRow(),
                          const SizedBox(height: 20),
                          _buildMediaControls(),
                          const SizedBox(height: 20),
                          _buildNumpad(),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // --- Top Navigation & Status Bar ---
  Widget _buildTopBar() {
    final isWin = _targetOs == 'windows';

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          ),
          child: Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: _isReconnecting ? const Color(0xFFFF9F0A) : const Color(0xFF30D158),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: _isReconnecting ? const Color(0xFFFF9F0A) : const Color(0xFF30D158),
                      blurRadius: 6,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                isWin ? Icons.window_rounded : Icons.apple_rounded,
                size: 14,
                color: Colors.white70,
              ),
              const SizedBox(width: 6),
              Text(
                _isReconnecting
                    ? 'Reconnecting...'
                    : (_targetHostname.isNotEmpty ? _targetHostname : _ipController.text.trim()),
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.white70),
              ),
            ],
          ),
        ),
        Row(
          children: [
            IconButton(
              icon: const Icon(Icons.settings_outlined, size: 20),
              onPressed: () {
                _triggerHaptic('selection');
                _showSettingsDialog();
              },
            ),
            IconButton(
              icon: const Icon(Icons.help_outline_rounded, size: 20),
              onPressed: () {
                _triggerHaptic('selection');
                _showGesturesDialog();
              },
            ),
            IconButton(
              icon: const Icon(Icons.link_off_rounded, color: Color(0xFFFF453A), size: 20),
              onPressed: () {
                _triggerHaptic('medium');
                _disconnect();
              },
            ),
          ],
        )
      ],
    );
  }

  // --- Interactive Trackpad Area ---
  Widget _buildTrackpadArea() {
    return Listener(
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: double.infinity,
        decoration: BoxDecoration(
          color: _isDragging ? const Color(0xFF152A1C) : const Color(0xFF161822),
          borderRadius: BorderRadius.circular(28),
          border: Border.all(
            color: _isDragging ? const Color(0xFF30D158) : Colors.white.withValues(alpha: 0.12),
            width: _isDragging ? 2.0 : 1.0,
          ),
          boxShadow: _isDragging
              ? [
                  BoxShadow(
                    color: const Color(0xFF30D158).withValues(alpha: 0.25),
                    blurRadius: 30,
                  )
                ]
              : [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.4),
                    blurRadius: 20,
                    offset: const Offset(0, 10),
                  )
                ],
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (_isDragging)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF30D158).withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: const Color(0xFF30D158)),
                ),
                child: const Text(
                  '🟢 DRAGGING ACTIVE',
                  style: TextStyle(
                    color: Color(0xFF30D158),
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5,
                  ),
                ),
              )
            else
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.crop_free_rounded,
                    size: 32,
                    color: Colors.white.withValues(alpha: 0.2),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Glide finger to control cursor',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.3),
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            if (_ripplePos != null)
              Positioned(
                left: _ripplePos!.dx - 30,
                top: _ripplePos!.dy - 30,
                child: Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        const Color(0xFF0A84FF).withValues(alpha: 0.4),
                        Colors.transparent,
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // --- Deck Mode Selector Tabs (Phone) ---
  Widget _buildDeckTabs() {
    return Container(
      height: 38,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: const Color(0xFF161822),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        children: [
          _buildDeckTabItem(0, 'Buttons', Icons.mouse_rounded),
          _buildDeckTabItem(1, 'Media', Icons.play_circle_outline_rounded),
          _buildDeckTabItem(2, 'Keyboard', Icons.keyboard_rounded),
        ],
      ),
    );
  }

  Widget _buildDeckTabItem(int index, String title, IconData icon) {
    final isSelected = _activeDeckTab == index;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          setState(() => _activeDeckTab = index);
          _triggerHaptic('selection');
        },
        child: Container(
          decoration: BoxDecoration(
            color: isSelected ? const Color(0xFF0A84FF) : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 15, color: isSelected ? Colors.white : Colors.white54),
              const SizedBox(width: 6),
              Text(
                title,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: isSelected ? Colors.white : Colors.white54,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --- Active Deck Content (Phone) ---
  Widget _buildActiveDeckContent() {
    if (_activeDeckTab == 1) {
      return Column(
        children: [
          _buildMediaControls(),
          const SizedBox(height: 10),
          _buildSensitivitySlider(),
        ],
      );
    } else if (_activeDeckTab == 2) {
      return Column(
        children: [
          _buildKeyboardInputCard(),
          const SizedBox(height: 10),
          _buildSensitivitySlider(),
        ],
      );
    }

    return Column(
      children: [
        _buildMouseButtonsRow(),
        const SizedBox(height: 8),
        _buildScrollButtonsRow(),
        const SizedBox(height: 10),
        _buildSensitivitySlider(),
      ],
    );
  }

  Widget _buildMouseButtonsRow() {
    return Row(
      children: [
        Expanded(
          child: _buildActionButton(
            label: 'Left Click',
            icon: Icons.mouse_rounded,
            isPrimary: true,
            onPressed: () {
              _send({'type': 'drag_end'});
              _send({'type': 'click'});
            },
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _buildActionButton(
            label: 'Right Click',
            icon: Icons.mouse_outlined,
            isPrimary: false,
            onPressed: () {
              _send({'type': 'rightclick'});
            },
          ),
        ),
      ],
    );
  }

  Widget _buildScrollButtonsRow() {
    return Row(
      children: [
        Expanded(
          child: _buildActionButton(
            label: 'Scroll Up',
            icon: Icons.arrow_upward_rounded,
            textColor: const Color(0xFF30D158),
            onPressed: () {
              _send({'type': 'scroll', 'dir': _naturalScroll ? 'up' : 'down'});
            },
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _buildActionButton(
            label: 'Scroll Down',
            icon: Icons.arrow_downward_rounded,
            textColor: const Color(0xFFFF9F0A),
            onPressed: () {
              _send({'type': 'scroll', 'dir': _naturalScroll ? 'down' : 'up'});
            },
          ),
        ),
      ],
    );
  }

  Widget _buildMediaControls() {
    return Row(
      children: [
        Expanded(
          child: _buildActionButton(
            label: 'Play/Pause',
            icon: Icons.play_arrow_rounded,
            onPressed: () => _sendKey('audio_play'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _buildActionButton(
            label: 'Vol -',
            icon: Icons.volume_down_rounded,
            onPressed: () => _sendKey('audio_voldown'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _buildActionButton(
            label: 'Vol +',
            icon: Icons.volume_up_rounded,
            onPressed: () => _sendKey('audio_volup'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _buildActionButton(
            label: 'Mute',
            icon: Icons.volume_off_rounded,
            textColor: const Color(0xFFFF453A),
            onPressed: () => _sendKey('audio_mute'),
          ),
        ),
      ],
    );
  }

  Widget _buildKeyboardInputCard() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF161822),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _textInputController,
                  decoration: InputDecoration(
                    hintText: 'Type text to send to computer...',
                    hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.3), fontSize: 13),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    filled: true,
                    fillColor: Colors.black.withValues(alpha: 0.3),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onSubmitted: (val) {
                    _sendTypedText(val);
                    _textInputController.clear();
                  },
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                icon: const Icon(Icons.send_rounded, size: 18),
                onPressed: () {
                  _triggerHaptic('medium');
                  _sendTypedText(_textInputController.text);
                  _textInputController.clear();
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _buildActionButton(
                  label: 'Enter',
                  icon: Icons.keyboard_return_rounded,
                  onPressed: () => _sendKey('enter'),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _buildActionButton(
                  label: 'Backspace',
                  icon: Icons.backspace_rounded,
                  onPressed: () => _sendKey('backspace'),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _buildActionButton(
                  label: 'Space',
                  icon: Icons.space_bar_rounded,
                  onPressed: () => _sendKey('space'),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _buildActionButton(
                  label: 'Esc',
                  icon: Icons.cancel_rounded,
                  onPressed: () => _sendKey('escape'),
                ),
              ),
            ],
          )
        ],
      ),
    );
  }

  Widget _buildNumpad() {
    const keys = [
      ['7', '8', '9'],
      ['4', '5', '6'],
      ['1', '2', '3'],
      ['0', '.', 'Enter'],
    ];

    return Column(
      children: keys.map((row) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 6.0),
          child: Row(
            children: row.map((key) {
              return Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3.0),
                  child: SizedBox(
                    height: 42,
                    child: ElevatedButton(
                      onPressed: () {
                        _triggerHaptic(key == 'Enter' ? 'medium' : 'light');
                        if (key == 'Enter') {
                          _sendKey('enter');
                        } else {
                          _sendTypedText(key);
                        }
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: key == 'Enter' ? const Color(0xFF0A84FF) : const Color(0xFF1E212D),
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      child: Text(key, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildSensitivitySlider() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF161822),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'SENSITIVITY',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                  color: Colors.white54,
                ),
              ),
              Text(
                '${_sensitivity.toStringAsFixed(1)}×',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF0A84FF),
                ),
              ),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Slider(
              value: _sensitivity,
              min: 0.5,
              max: 5.0,
              divisions: 18,
              activeColor: const Color(0xFF0A84FF),
              inactiveColor: Colors.white.withValues(alpha: 0.1),
              onChanged: (val) {
                if ((val * 4).round() != (_sensitivity * 4).round()) {
                  _triggerHaptic('selection');
                }
                setState(() => _sensitivity = val);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButton({
    required String label,
    required IconData icon,
    required VoidCallback onPressed,
    bool isPrimary = false,
    Color? textColor,
  }) {
    return SizedBox(
      height: 48,
      child: ElevatedButton(
        onPressed: () {
          _triggerHaptic(isPrimary ? 'medium' : 'light');
          onPressed();
        },
        style: ElevatedButton.styleFrom(
          backgroundColor: isPrimary ? const Color(0xFF0A84FF) : const Color(0xFF161822),
          foregroundColor: textColor ?? Colors.white,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(
              color: isPrimary ? Colors.transparent : Colors.white.withValues(alpha: 0.08),
            ),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 16, color: textColor ?? Colors.white),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: textColor ?? Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
