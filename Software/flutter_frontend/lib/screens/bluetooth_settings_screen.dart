import 'dart:async';

import 'package:flutter/material.dart';

import '../services/bluetooth_service.dart';

class BluetoothSettingsScreen extends StatefulWidget {
  const BluetoothSettingsScreen({super.key});

  @override
  State<BluetoothSettingsScreen> createState() => _BluetoothSettingsScreenState();
}

class _BluetoothSettingsScreenState extends State<BluetoothSettingsScreen> {
  final BluetoothService _bluetoothService = BluetoothService.instance;
  
  bool _isEnabled = false;
  bool _isDiscovering = false;
  List<BluetoothDevice> _devices = [];
  bool _isLoading = false;
  String? _errorMessage;
  
  late StreamSubscription<List<BluetoothDevice>> _devicesSubscription;
  late StreamSubscription<bool> _bluetoothStateSubscription;

  @override
  void initState() {
    super.initState();
    _initializeBluetooth();
  }

  @override
  void dispose() {
    _devicesSubscription.cancel();
    _bluetoothStateSubscription.cancel();
    _bluetoothService.stopScan();
    super.dispose();
  }

  Future<void> _initializeBluetooth() async {
    // Subscribe to streams
    _devicesSubscription = _bluetoothService.devicesStream.listen((devices) {
      if (mounted) {
        setState(() {
          _devices = devices;
        });
      }
    });
    
    _bluetoothStateSubscription = _bluetoothService.bluetoothStateStream.listen((enabled) {
      if (mounted) {
        setState(() {
          _isEnabled = enabled;
        });
      }
    });

    // Check initial state
    await _checkBluetoothStatus();
    
    // Load existing devices
    await _loadDevices();
  }

  Future<void> _checkBluetoothStatus() async {
    setState(() => _isLoading = true);
    
    final result = await _bluetoothService.isBluetoothEnabled();
    
    setState(() {
      _isLoading = false;
      if (result.isSuccess) {
        _isEnabled = result.data!;
        _errorMessage = null;
      } else {
        _errorMessage = result.error;
      }
    });
  }

  Future<void> _loadDevices() async {
    final result = await _bluetoothService.getDevices();
    if (result.isSuccess) {
      setState(() {
        _devices = result.data!;
      });
    }
  }

  Future<void> _toggleBluetooth(bool value) async {
    setState(() => _isLoading = true);
    
    final result = await _bluetoothService.setBluetoothEnabled(value);
    
    setState(() => _isLoading = false);
    
    if (result.isFailure) {
      _showSnack(result.error!);
    } else {
      if (value) {
        await _startDiscovery();
      } else {
        await _stopDiscovery();
      }
    }
  }

  Future<void> _startDiscovery() async {
    if (!_isEnabled) {
      _showSnack('Enable Bluetooth before discovering devices.');
      return;
    }

    setState(() => _isDiscovering = true);
    
    final result = await _bluetoothService.startScan();
    
    if (result.isFailure) {
      setState(() => _isDiscovering = false);
      _showSnack(result.error!);
    } else {
      _showSnack('Searching for nearby devices…');
      
      // Auto-stop scanning after 30 seconds
      Timer(const Duration(seconds: 30), () {
        if (mounted && _isDiscovering) {
          _stopDiscovery();
        }
      });
    }
  }

  Future<void> _stopDiscovery() async {
    await _bluetoothService.stopScan();
    setState(() => _isDiscovering = false);
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _connectDevice(BluetoothDevice device) async {
    final result = await _bluetoothService.connectDevice(device.address);
    
    if (result.isSuccess) {
      _showSnack('Connected to ${device.name}.');
    } else {
      _showSnack('Failed to connect: ${result.error}');
    }
  }

  Future<void> _disconnectDevice(BluetoothDevice device) async {
    final result = await _bluetoothService.disconnectDevice(device.address);
    
    if (result.isSuccess) {
      _showSnack('Disconnected from ${device.name}.');
    } else {
      _showSnack('Failed to disconnect: ${result.error}');
    }
  }

  Future<void> _pairDevice(BluetoothDevice device) async {
    final result = await _bluetoothService.pairDevice(device.address);
    
    if (result.isSuccess) {
      _showSnack('${device.name} paired.');
    } else {
      _showSnack('Failed to pair: ${result.error}');
    }
  }

  Future<void> _removeDevice(BluetoothDevice device) async {
    final result = await _bluetoothService.removeDevice(device.address);
    
    if (result.isSuccess) {
      _showSnack('${device.name} removed.');
    } else {
      _showSnack('Failed to remove: ${result.error}');
    }
  }

  List<BluetoothDevice> get _sortedDevices {
    final sorted = List<BluetoothDevice>.from(_devices);
    sorted.sort((a, b) {
      final orderA = _statusOrder(a.status);
      final orderB = _statusOrder(b.status);
      if (orderA != orderB) {
        return orderA.compareTo(orderB);
      }
      return a.name.compareTo(b.name);
    });
    return sorted;
  }

  int _statusOrder(BluetoothDeviceStatus status) {
    switch (status) {
      case BluetoothDeviceStatus.connected:
        return 0;
      case BluetoothDeviceStatus.paired:
        return 1;
      case BluetoothDeviceStatus.connecting:
        return 2;
      case BluetoothDeviceStatus.pairing:
        return 3;
      case BluetoothDeviceStatus.available:
        return 4;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: const Row(
          children: [
            Icon(Icons.bluetooth),
            SizedBox(width: 8),
            Text('Bluetooth'),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Row(
              children: [
                Text('Off', style: theme.textTheme.bodySmall),
                Switch(
                  value: _isEnabled, 
                  onChanged: _isLoading ? null : _toggleBluetooth,
                ),
                Text('On', style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Loading Bluetooth...'),
          ],
        ),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 64, color: Colors.red),
            const SizedBox(height: 16),
            Text('Error: $_errorMessage'),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _checkBluetoothStatus,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            FilledButton.tonalIcon(
              onPressed: _isEnabled ? _startDiscovery : null,
              icon: const Icon(Icons.radar),
              label: const Text('Discover'),
            ),
            if (_isDiscovering) ...[
              const SizedBox(width: 12),
              const Expanded(
                child: Row(
                  children: [
                    SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Detecting devices…',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 24),
        for (final device in _sortedDevices) ...[
          _BluetoothDeviceTile(
            device: device,
            onConnect: () => _connectDevice(device),
            onDisconnect: () => _disconnectDevice(device),
            onPair: () => _pairDevice(device),
            onRemove: () => _removeDevice(device),
            enabled: _isEnabled,
          ),
          const SizedBox(height: 12),
        ],
        if (_devices.isEmpty && !_isDiscovering)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: Text(
                'No devices found.\nTap "Discover" to search for nearby devices.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16),
              ),
            ),
          ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _isEnabled ? _startDiscovery : null,
          icon: const Icon(Icons.search),
          label: const Text('Search'),
        ),
      ],
    );
  }
}

class _BluetoothDeviceTile extends StatelessWidget {
  const _BluetoothDeviceTile({
    required this.device,
    required this.onConnect,
    required this.onDisconnect,
    required this.onPair,
    required this.onRemove,
    required this.enabled,
  });

  final BluetoothDevice device;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;
  final VoidCallback onPair;
  final VoidCallback onRemove;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final statusLabel = _statusLabel(device.status);
    final statusColor = _statusColor(theme, device.status);

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(_statusIcon(device.status), color: statusColor),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(device.name, style: theme.textTheme.titleMedium),
                      const SizedBox(height: 4),
                      Text(
                        statusLabel,
                        style: theme.textTheme.bodySmall?.copyWith(color: statusColor),
                      ),
                      if (device.deviceType != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          device.deviceType!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurface.withOpacity(0.6),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (device.rssi != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceVariant,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '${device.rssi} dBm',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: _buildActions(),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildActions() {
    switch (device.status) {
      case BluetoothDeviceStatus.connected:
        return [
          FilledButton.icon(
            onPressed: enabled ? onDisconnect : null,
            icon: const Icon(Icons.link_off),
            label: const Text('Disconnect'),
          ),
          OutlinedButton.icon(
            onPressed: enabled ? onRemove : null,
            icon: const Icon(Icons.delete_outline),
            label: const Text('Remove'),
          ),
        ];
      case BluetoothDeviceStatus.paired:
        return [
          FilledButton.icon(
            onPressed: enabled ? onConnect : null,
            icon: const Icon(Icons.link),
            label: const Text('Connect'),
          ),
          OutlinedButton.icon(
            onPressed: enabled ? onRemove : null,
            icon: const Icon(Icons.delete_outline),
            label: const Text('Remove'),
          ),
        ];
      case BluetoothDeviceStatus.connecting:
        return [
          FilledButton.icon(
            onPressed: null,
            icon: const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            label: const Text('Connecting...'),
          ),
        ];
      case BluetoothDeviceStatus.pairing:
        return [
          FilledButton.icon(
            onPressed: null,
            icon: const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            label: const Text('Pairing...'),
          ),
        ];
      case BluetoothDeviceStatus.available:
        return [
          FilledButton.icon(
            onPressed: enabled ? onPair : null,
            icon: const Icon(Icons.add_link),
            label: const Text('Pair'),
          ),
        ];
    }
  }

  Color _statusColor(ThemeData theme, BluetoothDeviceStatus status) {
    switch (status) {
      case BluetoothDeviceStatus.connected:
        return theme.colorScheme.primary;
      case BluetoothDeviceStatus.paired:
        return theme.colorScheme.tertiary;
      case BluetoothDeviceStatus.connecting:
      case BluetoothDeviceStatus.pairing:
        return theme.colorScheme.secondary;
      case BluetoothDeviceStatus.available:
        return theme.colorScheme.onSurface.withOpacity(0.6);
    }
  }

  IconData _statusIcon(BluetoothDeviceStatus status) {
    switch (status) {
      case BluetoothDeviceStatus.connected:
        return Icons.bluetooth_connected;
      case BluetoothDeviceStatus.paired:
        return Icons.devices;
      case BluetoothDeviceStatus.connecting:
        return Icons.bluetooth_searching;
      case BluetoothDeviceStatus.pairing:
        return Icons.bluetooth_searching;
      case BluetoothDeviceStatus.available:
        return Icons.bluetooth;
    }
  }

  String _statusLabel(BluetoothDeviceStatus status) {
    switch (status) {
      case BluetoothDeviceStatus.connected:
        return 'Connected';
      case BluetoothDeviceStatus.paired:
        return 'Paired';
      case BluetoothDeviceStatus.connecting:
        return 'Connecting...';
      case BluetoothDeviceStatus.pairing:
        return 'Pairing...';
      case BluetoothDeviceStatus.available:
        return 'Available to pair';
    }
  }
}
