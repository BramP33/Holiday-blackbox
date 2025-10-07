import 'dart:async';

import 'package:flutter/material.dart';

import '../services/bluetooth_service.dart';

class BluetoothDebugScreen extends StatefulWidget {
  const BluetoothDebugScreen({super.key});

  @override
  State<BluetoothDebugScreen> createState() => _BluetoothDebugScreenState();
}

class _BluetoothDebugScreenState extends State<BluetoothDebugScreen> {
  final BluetoothService _bluetoothService = BluetoothService.instance;
  final List<String> _logs = [];
  final ScrollController _scrollController = ScrollController();
  bool _isEnabled = false;
  bool _isScanning = false;
  List<BluetoothDevice> _devices = [];

  @override
  void initState() {
    super.initState();
    _log('Bluetooth Debug Screen initialized');
    _checkBluetoothStatus();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _log(String message) {
    final timestamp = DateTime.now().toIso8601String().substring(11, 19);
    setState(() {
      _logs.add('[$timestamp] $message');
    });
    
    // Auto-scroll to bottom
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _checkBluetoothStatus() async {
    _log('Checking Bluetooth status...');
    
    final result = await _bluetoothService.isBluetoothEnabled();
    
    if (result.isSuccess) {
      _isEnabled = result.data!;
      _log('Bluetooth is ${_isEnabled ? 'enabled' : 'disabled'}');
      setState(() {});
    } else {
      _log('ERROR: Failed to check Bluetooth status - ${result.error}');
    }
  }

  Future<void> _toggleBluetooth() async {
    final newState = !_isEnabled;
    _log('${newState ? 'Enabling' : 'Disabling'} Bluetooth...');
    
    final result = await _bluetoothService.setBluetoothEnabled(newState);
    
    if (result.isSuccess) {
      _isEnabled = result.data!;
      _log('Bluetooth ${_isEnabled ? 'enabled' : 'disabled'} successfully');
      setState(() {});
    } else {
      _log('ERROR: Failed to ${newState ? 'enable' : 'disable'} Bluetooth - ${result.error}');
    }
  }

  Future<void> _startScan() async {
    if (!_isEnabled) {
      _log('Cannot start scan - Bluetooth is disabled');
      return;
    }

    _log('Starting Bluetooth scan...');
    _isScanning = true;
    setState(() {});
    
    final result = await _bluetoothService.startScan();
    
    if (result.isSuccess) {
      _log('Bluetooth scan started successfully');
      
      // Get devices periodically while scanning
      Timer.periodic(const Duration(seconds: 3), (timer) async {
        if (!_isScanning) {
          timer.cancel();
          return;
        }
        
        await _refreshDevices();
      });
      
    } else {
      _log('ERROR: Failed to start scan - ${result.error}');
      _isScanning = false;
      setState(() {});
    }
  }

  Future<void> _stopScan() async {
    _log('Stopping Bluetooth scan...');
    
    final result = await _bluetoothService.stopScan();
    
    _isScanning = false;
    setState(() {});
    
    if (result.isSuccess) {
      _log('Bluetooth scan stopped successfully');
    } else {
      _log('ERROR: Failed to stop scan - ${result.error}');
    }
  }

  Future<void> _refreshDevices() async {
    _log('Refreshing device list...');
    
    final result = await _bluetoothService.getDevices();
    
    if (result.isSuccess) {
      final newDevices = result.data!;
      final foundNewDevices = newDevices.length != _devices.length;
      
      _devices = newDevices;
      setState(() {});
      
      if (foundNewDevices || _devices.isNotEmpty) {
        _log('Found ${_devices.length} devices');
        for (final device in _devices) {
          _log('  - ${device.name} (${device.address}) [${device.status.name}]');
        }
      }
    } else {
      _log('ERROR: Failed to get devices - ${result.error}');
    }
  }

  Future<void> _getPairedDevices() async {
    _log('Getting paired devices...');
    
    final result = await _bluetoothService.getPairedDevices();
    
    if (result.isSuccess) {
      final pairedDevices = result.data!;
      _log('Found ${pairedDevices.length} paired devices');
      for (final device in pairedDevices) {
        _log('  - ${device.name} (${device.address}) [${device.status.name}]');
      }
    } else {
      _log('ERROR: Failed to get paired devices - ${result.error}');
    }
  }

  Future<void> _testDeviceInfo() async {
    if (_devices.isEmpty) {
      _log('No devices available for info test');
      return;
    }

    final device = _devices.first;
    _log('Getting info for device: ${device.name} (${device.address})');
    
    final result = await _bluetoothService.getDeviceInfo(device.address);
    
    if (result.isSuccess && result.data != null) {
      final info = result.data!;
      _log('Device info retrieved:');
      _log('  - Name: ${info.name}');
      _log('  - Address: ${info.address}');
      _log('  - Status: ${info.status.name}');
      _log('  - Type: ${info.deviceType ?? 'Unknown'}');
      _log('  - RSSI: ${info.rssi ?? 'N/A'} dBm');
    } else {
      _log('ERROR: Failed to get device info - ${result.error}');
    }
  }

  Future<void> _setDiscoverable() async {
    _log('Making device discoverable...');
    
    final result = await _bluetoothService.setDiscoverable(true);
    
    if (result.isSuccess) {
      _log('Device is now discoverable');
    } else {
      _log('ERROR: Failed to make device discoverable - ${result.error}');
    }
  }

  void _clearLogs() {
    setState(() {
      _logs.clear();
    });
    _log('Logs cleared');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: const Row(
          children: [
            Icon(Icons.bug_report),
            SizedBox(width: 8),
            Text('Bluetooth Debug'),
          ],
        ),
        actions: [
          IconButton(
            onPressed: _clearLogs,
            icon: const Icon(Icons.clear_all),
          ),
        ],
      ),
      body: Column(
        children: [
          // Status and controls
          Container(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      _isEnabled ? Icons.bluetooth : Icons.bluetooth_disabled,
                      color: _isEnabled ? Colors.blue : Colors.grey,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Bluetooth: ${_isEnabled ? 'ON' : 'OFF'}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const Spacer(),
                    if (_isScanning)
                      const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ElevatedButton.icon(
                      onPressed: _checkBluetoothStatus,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Check Status'),
                    ),
                    ElevatedButton.icon(
                      onPressed: _toggleBluetooth,
                      icon: Icon(_isEnabled ? Icons.bluetooth_disabled : Icons.bluetooth),
                      label: Text(_isEnabled ? 'Disable' : 'Enable'),
                    ),
                    ElevatedButton.icon(
                      onPressed: _isEnabled && !_isScanning ? _startScan : null,
                      icon: const Icon(Icons.search),
                      label: const Text('Start Scan'),
                    ),
                    ElevatedButton.icon(
                      onPressed: _isScanning ? _stopScan : null,
                      icon: const Icon(Icons.stop),
                      label: const Text('Stop Scan'),
                    ),
                    ElevatedButton.icon(
                      onPressed: _refreshDevices,
                      icon: const Icon(Icons.devices),
                      label: const Text('Refresh'),
                    ),
                    ElevatedButton.icon(
                      onPressed: _getPairedDevices,
                      icon: const Icon(Icons.link),
                      label: const Text('Paired'),
                    ),
                    ElevatedButton.icon(
                      onPressed: _devices.isNotEmpty ? _testDeviceInfo : null,
                      icon: const Icon(Icons.info),
                      label: const Text('Test Info'),
                    ),
                    ElevatedButton.icon(
                      onPressed: _isEnabled ? _setDiscoverable : null,
                      icon: const Icon(Icons.visibility),
                      label: const Text('Discoverable'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Divider(),
          // Device list
          if (_devices.isNotEmpty) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  const Icon(Icons.devices, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    'Found Devices (${_devices.length})',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ],
              ),
            ),
            Container(
              height: 120,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: ListView.builder(
                itemCount: _devices.length,
                itemBuilder: (context, index) {
                  final device = _devices[index];
                  return ListTile(
                    dense: true,
                    leading: Icon(_getDeviceIcon(device.status)),
                    title: Text(device.name),
                    subtitle: Text('${device.address} • ${device.status.name}'),
                    trailing: device.rssi != null
                        ? Text('${device.rssi} dBm')
                        : null,
                  );
                },
              ),
            ),
            const Divider(),
          ],
          // Logs
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.terminal, size: 20),
                      const SizedBox(width: 8),
                      Text(
                        'Debug Logs',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.black,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: ListView.builder(
                        controller: _scrollController,
                        itemCount: _logs.length,
                        itemBuilder: (context, index) {
                          final log = _logs[index];
                          return Text(
                            log,
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                              color: log.contains('ERROR') 
                                  ? Colors.red 
                                  : Colors.green,
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  IconData _getDeviceIcon(BluetoothDeviceStatus status) {
    switch (status) {
      case BluetoothDeviceStatus.connected:
        return Icons.bluetooth_connected;
      case BluetoothDeviceStatus.paired:
        return Icons.devices;
      case BluetoothDeviceStatus.connecting:
      case BluetoothDeviceStatus.pairing:
        return Icons.bluetooth_searching;
      case BluetoothDeviceStatus.available:
        return Icons.bluetooth;
    }
  }
}