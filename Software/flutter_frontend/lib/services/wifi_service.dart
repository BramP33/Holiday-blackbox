import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:http/http.dart' as http;

// Enable debug logging
const bool _kDebugWiFi = true;

void _debugLog(String message) {
  if (_kDebugWiFi) {
    print('[WiFiService] $message');
  }
}

class WiFiNetwork {
  const WiFiNetwork({
    required this.ssid,
    required this.bssid,
    required this.security,
    required this.signalStrength,
    required this.frequency,
    this.isConnected = false,
    this.isKnown = false,
  });

  final String ssid;
  final String bssid;
  final String security;
  final int signalStrength; // dBm
  final String frequency; // e.g., "2.4 GHz"
  final bool isConnected;
  final bool isKnown;

  bool get isSecure => security.isNotEmpty && security != '--';

  int get signalBars {
    // Convert signal strength to bars (1-4)
    if (signalStrength >= -50) return 4;
    if (signalStrength >= -60) return 3;
    if (signalStrength >= -70) return 2;
    return 1;
  }

  WiFiNetwork copyWith({
    bool? isConnected,
    bool? isKnown,
  }) {
    return WiFiNetwork(
      ssid: ssid,
      bssid: bssid,
      security: security,
      signalStrength: signalStrength,
      frequency: frequency,
      isConnected: isConnected ?? this.isConnected,
      isKnown: isKnown ?? this.isKnown,
    );
  }

  @override
  String toString() => 'WiFiNetwork(ssid: $ssid, signal: $signalStrength dBm, secure: $isSecure)';
}

class WiFiConnectionResult {
  const WiFiConnectionResult({
    required this.success,
    this.error,
  });

  final bool success;
  final String? error;


}

class WiFiService {
  WiFiService._();
  static final WiFiService instance = WiFiService._();

  final Connectivity _connectivity = Connectivity();
  
  StreamSubscription<ConnectivityResult>? _connectivitySubscription;
  final StreamController<List<WiFiNetwork>> _networksController = 
      StreamController<List<WiFiNetwork>>.broadcast();
  final StreamController<WiFiNetwork?> _currentNetworkController = 
      StreamController<WiFiNetwork?>.broadcast();

  List<WiFiNetwork> _cachedNetworks = [];
  WiFiNetwork? _currentNetwork;
  Timer? _scanTimer;

  Stream<List<WiFiNetwork>> get networksStream => _networksController.stream;
  Stream<WiFiNetwork?> get currentNetworkStream => _currentNetworkController.stream;
  
  List<WiFiNetwork> get cachedNetworks => List.unmodifiable(_cachedNetworks);
  WiFiNetwork? get currentNetwork => _currentNetwork;

  Future<void> initialize() async {
    _debugLog('Initializing WiFi service...');
    
    // Start monitoring connectivity changes
    _connectivitySubscription = _connectivity.onConnectivityChanged.listen((result) => _onConnectivityChanged(result));
    
    // Get initial connectivity state
    await _updateCurrentNetwork();
    
    // Start periodic scanning
    await startPeriodicScanning();
    
    _debugLog('WiFi service initialized');
  }

  void dispose() {
    _connectivitySubscription?.cancel();
    _scanTimer?.cancel();
    _networksController.close();
    _currentNetworkController.close();
  }

  Future<bool> isNetworkManagerAvailable() async {
    try {
      final result = await Process.run('which', ['nmcli']);
      final available = result.exitCode == 0;
      _debugLog('NetworkManager available: $available');
      return available;
    } catch (e) {
      _debugLog('Error checking NetworkManager: $e');
      return false;
    }
  }

  Future<List<WiFiNetwork>> scanNetworks() async {
    _debugLog('Starting WiFi network scan...');
    
    try {
      final isAvailable = await isNetworkManagerAvailable();
      if (!isAvailable) {
        throw Exception('NetworkManager (nmcli) is not available');
      }

      // Use nmcli to scan for WiFi networks
      _debugLog('Running nmcli scan command...');
      final result = await Process.run('nmcli', [
        '-t', // Terse output
        '-f', 'SSID,BSSID,MODE,CHAN,FREQ,RATE,SIGNAL,BARS,SECURITY',
        'dev',
        'wifi',
        'list'
      ]);

      if (result.exitCode != 0) {
        _debugLog('nmcli scan failed: ${result.stderr}');
        throw Exception('Failed to scan networks: ${result.stderr}');
      }

      final lines = (result.stdout as String).split('\n');
      final networks = <WiFiNetwork>[];
      final seenSSIDs = <String>{};

      _debugLog('Processing ${lines.length} scan result lines...');
      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        
        final parts = line.split(':');
        if (parts.length < 9) continue;

        final ssid = parts[0].trim();
        if (ssid.isEmpty || seenSSIDs.contains(ssid)) continue;
        
        seenSSIDs.add(ssid);

        final bssid = parts[1].trim();
        final signal = int.tryParse(parts[6].trim()) ?? -100;
        final security = parts[8].trim();
        
        // Determine frequency from channel
        final channel = parts[3].trim();
        final frequency = _getFrequencyFromChannel(channel);

        networks.add(WiFiNetwork(
          ssid: ssid,
          bssid: bssid,
          security: security,
          signalStrength: signal,
          frequency: frequency,
        ));
      }

      // Sort by signal strength (strongest first)
      networks.sort((a, b) => b.signalStrength.compareTo(a.signalStrength));

      _debugLog('Found ${networks.length} unique networks');
      _cachedNetworks = networks;
      await _updateNetworksWithConnectionStatus();
      _networksController.add(_cachedNetworks);

      return _cachedNetworks;
    } catch (e) {
      _debugLog('WiFi scan failed: $e');
      throw Exception('Failed to scan WiFi networks: $e');
    }
  }

  Future<void> startPeriodicScanning({Duration interval = const Duration(seconds: 15)}) async {
    _scanTimer?.cancel();
    
    final isAvailable = await isNetworkManagerAvailable();
    if (!isAvailable) return;

    _scanTimer = Timer.periodic(interval, (_) async {
      try {
        await scanNetworks();
      } catch (e) {
        // Silently ignore scan errors in background
      }
    });
  }

  void stopPeriodicScanning() {
    _scanTimer?.cancel();
    _scanTimer = null;
  }

  Future<WiFiConnectionResult> connectToNetwork({
    required String ssid, 
    String? password,
  }) async {
    _debugLog('Attempting to connect to network: $ssid');
    
    try {
      final isAvailable = await isNetworkManagerAvailable();
      if (!isAvailable) {
        return const WiFiConnectionResult(
          success: false, 
          error: 'NetworkManager is not available'
        );
      }

      // First check if this network is already known
      final knownConnections = await _getKnownConnections();
      final existingConnection = knownConnections[ssid];

      if (existingConnection != null) {
        _debugLog('Found existing connection for $ssid, attempting to connect...');
        // Try to connect to existing connection
        final result = await Process.run('nmcli', [
          'connection',
          'up',
          existingConnection,
        ]);

        if (result.exitCode == 0) {
          _debugLog('Successfully connected to existing connection');
          await _updateCurrentNetwork();
          return const WiFiConnectionResult(success: true);
        } else {
          _debugLog('Failed to connect to existing connection: ${result.stderr}');
        }
      }

      // Create new connection
      _debugLog('Creating new connection for $ssid');
      final args = [
        'nmcli',
        'dev',
        'wifi',
        'connect',
        ssid,
      ];

      if (password != null && password.isNotEmpty) {
        args.addAll(['password', password]);
        _debugLog('Using password for connection');
      }

      final result = await Process.run(args[0], args.skip(1).toList());

      if (result.exitCode == 0) {
        _debugLog('Successfully connected to $ssid');
        await _updateCurrentNetwork();
        return const WiFiConnectionResult(success: true);
      } else {
        final error = result.stderr as String;
        _debugLog('Connection failed: $error');
        String friendlyError = 'Failed to connect';
        
        if (error.contains('password') || error.contains('authentication')) {
          friendlyError = 'Invalid password or authentication failed';
        } else if (error.contains('timeout')) {
          friendlyError = 'Connection timeout';
        } else if (error.contains('not found')) {
          friendlyError = 'Network not found';
        }
        
        return WiFiConnectionResult(success: false, error: friendlyError);
      }
    } catch (e) {
      _debugLog('Exception during connection: $e');
      return WiFiConnectionResult(success: false, error: e.toString());
    }
  }

  Future<void> forgetNetwork(String ssid) async {
    try {
      final knownConnections = await _getKnownConnections();
      final connectionId = knownConnections[ssid];
      
      if (connectionId != null) {
        await Process.run('nmcli', [
          'connection',
          'delete',
          connectionId,
        ]);
        
        // Update our cache
        await scanNetworks();
      }
    } catch (e) {
      // Ignore errors when forgetting networks
    }
  }

  Future<Map<String, String>> _getKnownConnections() async {
    try {
      final result = await Process.run('nmcli', [
        '-t',
        '-f', 'NAME,TYPE',
        'connection',
        'show',
      ]);

      if (result.exitCode != 0) return {};

      final connections = <String, String>{};
      final lines = (result.stdout as String).split('\n');
      
      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        final parts = line.split(':');
        if (parts.length >= 2 && parts[1].trim() == '802-11-wireless') {
          final name = parts[0].trim();
          connections[name] = name;
        }
      }
      
      return connections;
    } catch (e) {
      return {};
    }
  }

  String _getFrequencyFromChannel(String channel) {
    final channelNum = int.tryParse(channel);
    if (channelNum == null) return 'Unknown';
    
    if (channelNum <= 14) {
      return '2.4 GHz';
    } else {
      return '5 GHz';
    }
  }

  Future<void> _onConnectivityChanged(ConnectivityResult result) async {
    await _updateCurrentNetwork();
    if (_cachedNetworks.isNotEmpty) {
      await _updateNetworksWithConnectionStatus();
      _networksController.add(_cachedNetworks);
    }
  }

  Future<void> _updateCurrentNetwork() async {
    try {
      final result = await Process.run('nmcli', [
        '-t',
        '-f', 'ACTIVE,SSID,BSSID,MODE,CHAN,FREQ,RATE,SIGNAL,BARS,SECURITY',
        'dev',
        'wifi',
        'list'
      ]);

      if (result.exitCode != 0) {
        _currentNetwork = null;
        _currentNetworkController.add(null);
        return;
      }

      final lines = (result.stdout as String).split('\n');
      
      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        
        final parts = line.split(':');
        if (parts.length < 10) continue;
        
        final active = parts[0].trim();
        if (active != 'yes' && active != '*') continue;
        
        final ssid = parts[1].trim();
        if (ssid.isEmpty) continue;
        
        final bssid = parts[2].trim();
        final signal = int.tryParse(parts[7].trim()) ?? -100;
        final security = parts[9].trim();
        final channel = parts[4].trim();
        final frequency = _getFrequencyFromChannel(channel);

        _currentNetwork = WiFiNetwork(
          ssid: ssid,
          bssid: bssid,
          security: security,
          signalStrength: signal,
          frequency: frequency,
          isConnected: true,
        );
        
        _currentNetworkController.add(_currentNetwork);
        return;
      }
      
      _currentNetwork = null;
      _currentNetworkController.add(null);
    } catch (e) {
      _currentNetwork = null;
      _currentNetworkController.add(null);
    }
  }

  Future<void> _updateNetworksWithConnectionStatus() async {
    final currentSsid = _currentNetwork?.ssid;
    final knownConnections = await _getKnownConnections();
    
    _cachedNetworks = _cachedNetworks.map((network) => network.copyWith(
      isConnected: network.ssid == currentSsid,
      isKnown: knownConnections.containsKey(network.ssid),
    )).toList();
  }

  // Access Point functionality
  String get _baseUrl {
    return const String.fromEnvironment(
      'BLACKBOX_BASE_URL',
      defaultValue: 'http://127.0.0.1:8080',
    );
  }

  Future<Map<String, dynamic>> getApStatus() async {
    _debugLog('Getting AP status...');
    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/api/ap/status'),
        headers: {'Accept': 'application/json'},
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        _debugLog('AP status: ${data['active'] ? 'active' : 'inactive'}');
        return data;
      } else {
        throw Exception('Failed to get AP status: ${response.statusCode}');
      }
    } catch (e) {
      _debugLog('Error getting AP status: $e');
      rethrow;
    }
  }

  Future<bool> startAccessPoint() async {
    _debugLog('Starting Access Point...');
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/api/ap/start'),
        headers: {'Accept': 'application/json'},
      );

      final data = json.decode(response.body) as Map<String, dynamic>;
      
      if (response.statusCode == 200 && data['success'] == true) {
        _debugLog('Access Point started successfully');
        // When AP starts, WiFi client mode should be disabled
        await _updateCurrentNetwork();
        return true;
      } else {
        final error = data['error'] ?? 'Unknown error starting AP';
        _debugLog('Failed to start AP: $error');
        throw Exception(error);
      }
    } catch (e) {
      _debugLog('Error starting Access Point: $e');
      rethrow;
    }
  }

  Future<bool> stopAccessPoint() async {
    _debugLog('Stopping Access Point...');
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/api/ap/stop'),
        headers: {'Accept': 'application/json'},
      );

      final data = json.decode(response.body) as Map<String, dynamic>;
      
      if (response.statusCode == 200 && data['success'] == true) {
        _debugLog('Access Point stopped successfully');
        return true;
      } else {
        final error = data['error'] ?? 'Unknown error stopping AP';
        _debugLog('Failed to stop AP: $error');
        throw Exception(error);
      }
    } catch (e) {
      _debugLog('Error stopping Access Point: $e');
      rethrow;
    }
  }

  /// Get Access Point status
  Future<Map<String, dynamic>> getAccessPointStatus() async {
    try {
      _debugLog('Getting Access Point status...');
      
      final response = await http.get(
        Uri.parse('$_baseUrl/api/ap/status'),
        headers: {'Accept': 'application/json'},
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        _debugLog('AP status retrieved successfully: ${data['active']}');
        return data;
      } else {
        final error = 'Failed to get AP status: ${response.statusCode}';
        _debugLog(error);
        throw Exception(error);
      }
    } catch (e) {
      _debugLog('Error getting Access Point status: $e');
      rethrow;
    }
  }
}