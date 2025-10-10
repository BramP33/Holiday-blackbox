import 'package:flutter/material.dart';
import '../services/wifi_service.dart';

class WiFiDebugScreen extends StatefulWidget {
  const WiFiDebugScreen({super.key});

  @override
  State<WiFiDebugScreen> createState() => _WiFiDebugScreenState();
}

class _WiFiDebugScreenState extends State<WiFiDebugScreen> {
  final WiFiService _wifiService = WiFiService.instance;
  bool _isInitialized = false;
  bool _isScanning = false;
  List<WiFiNetwork> _networks = [];
  WiFiNetwork? _currentNetwork;
  String _logs = '';

  @override
  void initState() {
    super.initState();
    _initializeService();
  }

  Future<void> _initializeService() async {
    _addLog('Initializing WiFi service...');
    try {
      await _wifiService.initialize();
      setState(() {
        _isInitialized = true;
      });
      _addLog('WiFi service initialized successfully');
      
      // Listen to streams
      _wifiService.networksStream.listen((networks) {
        setState(() {
          _networks = networks;
        });
        _addLog('Received ${networks.length} networks from stream');
      });
      
      _wifiService.currentNetworkStream.listen((network) {
        setState(() {
          _currentNetwork = network;
        });
        _addLog('Current network changed: ${network?.ssid ?? 'None'}');
      });
      
    } catch (e) {
      _addLog('Failed to initialize WiFi service: $e');
    }
  }

  Future<void> _scanNetworks() async {
    if (!_isInitialized) return;
    
    setState(() {
      _isScanning = true;
    });
    
    _addLog('Starting network scan...');
    try {
      final networks = await _wifiService.scanNetworks();
      _addLog('Scan completed: found ${networks.length} networks');
    } catch (e) {
      _addLog('Scan failed: $e');
    } finally {
      setState(() {
        _isScanning = false;
      });
    }
  }

  Future<void> _checkNetworkManager() async {
    _addLog('Checking NetworkManager availability...');
    try {
      final available = await _wifiService.isNetworkManagerAvailable();
      _addLog('NetworkManager available: $available');
    } catch (e) {
      _addLog('Error checking NetworkManager: $e');
    }
  }

  void _addLog(String message) {
    final timestamp = DateTime.now().toString().substring(11, 19);
    setState(() {
      _logs += '[$timestamp] $message\n';
    });
  }

  void _clearLogs() {
    setState(() {
      _logs = '';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('WiFi Debug'),
        actions: [
          IconButton(
            icon: const Icon(Icons.clear),
            onPressed: _clearLogs,
            tooltip: 'Clear logs',
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Status section
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Service Status', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Text('Initialized: $_isInitialized'),
                    Text('Current Network: ${_currentNetwork?.ssid ?? 'None'}'),
                    Text('Known Networks: ${_networks.length}'),
                  ],
                ),
              ),
            ),
            
            const SizedBox(height: 16),
            
            // Actions section
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ElevatedButton(
                  onPressed: _checkNetworkManager,
                  child: const Text('Check nmcli'),
                ),
                ElevatedButton(
                  onPressed: _isScanning ? null : _scanNetworks,
                  child: _isScanning 
                      ? const Text('Scanning...') 
                      : const Text('Scan Networks'),
                ),
              ],
            ),
            
            const SizedBox(height: 16),
            
            // Networks section
            if (_networks.isNotEmpty) ...[
              Text('Found Networks:', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              SizedBox(
                height: 150,
                child: ListView.builder(
                  itemCount: _networks.length,
                  itemBuilder: (context, index) {
                    final network = _networks[index];
                    return ListTile(
                      dense: true,
                      leading: Icon(network.isSecure ? Icons.lock : Icons.wifi),
                      title: Text(network.ssid),
                      subtitle: Text('${network.signalStrength} dBm • ${network.security}'),
                      trailing: network.isConnected 
                          ? const Icon(Icons.check_circle, color: Colors.green)
                          : null,
                    );
                  },
                ),
              ),
              const SizedBox(height: 16),
            ],
            
            // Logs section
            Expanded(
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Debug Logs', style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      Expanded(
                        child: SingleChildScrollView(
                          child: Text(
                            _logs.isEmpty ? 'No logs yet...' : _logs,
                            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                          ),
                        ),
                      ),
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
}