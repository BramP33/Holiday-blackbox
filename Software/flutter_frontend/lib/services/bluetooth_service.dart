import 'dart:async';
import 'dart:io';

enum BluetoothDeviceStatus { connected, paired, available, connecting, pairing }

class BluetoothDevice {
  const BluetoothDevice({
    required this.name,
    required this.address,
    required this.status,
    this.deviceType,
    this.rssi,
  });

  final String name;
  final String address; // MAC address like "AA:BB:CC:DD:EE:FF"
  final BluetoothDeviceStatus status;
  final String? deviceType;
  final int? rssi; // Signal strength

  BluetoothDevice copyWith({
    String? name,
    String? address,
    BluetoothDeviceStatus? status,
    String? deviceType,
    int? rssi,
  }) {
    return BluetoothDevice(
      name: name ?? this.name,
      address: address ?? this.address,
      status: status ?? this.status,
      deviceType: deviceType ?? this.deviceType,
      rssi: rssi ?? this.rssi,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BluetoothDevice &&
          runtimeType == other.runtimeType &&
          address == other.address;

  @override
  int get hashCode => address.hashCode;

  @override
  String toString() {
    return 'BluetoothDevice{name: $name, address: $address, status: $status}';
  }
}

class BluetoothServiceResult<T> {
  const BluetoothServiceResult.success(this.data) : error = null;
  const BluetoothServiceResult.failure(this.error) : data = null;

  final T? data;
  final String? error;

  bool get isSuccess => error == null;
  bool get isFailure => error != null;
}

class BluetoothService {
  BluetoothService._();
  static final BluetoothService instance = BluetoothService._();

  final StreamController<List<BluetoothDevice>> _devicesController =
      StreamController<List<BluetoothDevice>>.broadcast();
  final StreamController<bool> _bluetoothStateController =
      StreamController<bool>.broadcast();

  Stream<List<BluetoothDevice>> get devicesStream => _devicesController.stream;
  Stream<bool> get bluetoothStateStream => _bluetoothStateController.stream;

  final List<BluetoothDevice> _devices = [];
  bool _isScanning = false;
  bool _isEnabled = false;

  /// Check if Bluetooth is enabled
  Future<BluetoothServiceResult<bool>> isBluetoothEnabled() async {
    try {
      final result = await Process.run('bluetoothctl', ['show'], runInShell: true);
      if (result.exitCode != 0) {
        return BluetoothServiceResult.failure('Failed to check Bluetooth status: ${result.stderr}');
      }

      final output = result.stdout as String;
      final isPowered = output.contains('Powered: yes');
      _isEnabled = isPowered;
      _bluetoothStateController.add(_isEnabled);
      return BluetoothServiceResult.success(isPowered);
    } catch (e) {
      return BluetoothServiceResult.failure('Error checking Bluetooth status: $e');
    }
  }

  /// Enable or disable Bluetooth
  Future<BluetoothServiceResult<bool>> setBluetoothEnabled(bool enabled) async {
    try {
      final command = enabled ? 'power on' : 'power off';
      final result = await Process.run('bluetoothctl', [command], runInShell: true);
      
      if (result.exitCode != 0) {
        return BluetoothServiceResult.failure('Failed to ${enabled ? 'enable' : 'disable'} Bluetooth: ${result.stderr}');
      }

      // Wait a moment for the change to take effect
      await Future.delayed(const Duration(seconds: 1));
      
      // Verify the change
      final statusResult = await isBluetoothEnabled();
      if (statusResult.isFailure) {
        return statusResult;
      }

      _isEnabled = statusResult.data ?? false;
      _bluetoothStateController.add(_isEnabled);
      return BluetoothServiceResult.success(_isEnabled);
    } catch (e) {
      return BluetoothServiceResult.failure('Error toggling Bluetooth: $e');
    }
  }

  /// Make device discoverable
  Future<BluetoothServiceResult<bool>> setDiscoverable(bool discoverable) async {
    try {
      final command = discoverable ? 'discoverable on' : 'discoverable off';
      final result = await Process.run('bluetoothctl', [command], runInShell: true);
      
      if (result.exitCode != 0) {
        return BluetoothServiceResult.failure('Failed to set discoverable mode: ${result.stderr}');
      }

      return const BluetoothServiceResult.success(true);
    } catch (e) {
      return BluetoothServiceResult.failure('Error setting discoverable mode: $e');
    }
  }

  /// Start scanning for devices
  Future<BluetoothServiceResult<bool>> startScan() async {
    if (_isScanning) {
      return const BluetoothServiceResult.success(true);
    }

    try {
      // First ensure Bluetooth is enabled
      final enabledResult = await isBluetoothEnabled();
      if (enabledResult.isFailure || !enabledResult.data!) {
        return BluetoothServiceResult.failure('Bluetooth is not enabled');
      }

      // Clear old devices from bluetoothctl cache to get fresh scan
      await Process.run('bluetoothctl', ['remove', '*'], runInShell: true);
      
      // Start scanning
      final result = await Process.run('bluetoothctl', ['scan', 'on'], runInShell: true);
      if (result.exitCode != 0) {
        return BluetoothServiceResult.failure('Failed to start Bluetooth scan: ${result.stderr}');
      }

      _isScanning = true;
      
      // Start discovering devices in background
      _discoverDevices();
      
      return const BluetoothServiceResult.success(true);
    } catch (e) {
      return BluetoothServiceResult.failure('Error starting Bluetooth scan: $e');
    }
  }

  /// Stop scanning for devices
  Future<BluetoothServiceResult<bool>> stopScan() async {
    try {
      _isScanning = false;
      
      // Kill the scan process if it's running
      if (_scanProcess != null) {
        _scanProcess!.kill();
        _scanProcess = null;
      }
      
      final result = await Process.run('bluetoothctl', ['scan', 'off'], runInShell: true);
      if (result.exitCode != 0) {
        return BluetoothServiceResult.failure('Failed to stop Bluetooth scan: ${result.stderr}');
      }

      return const BluetoothServiceResult.success(true);
    } catch (e) {
      return BluetoothServiceResult.failure('Error stopping Bluetooth scan: $e');
    }
  }

  /// Get list of all known devices
  Future<BluetoothServiceResult<List<BluetoothDevice>>> getDevices() async {
    try {
      final result = await Process.run('bluetoothctl', ['devices'], runInShell: true);
      if (result.exitCode != 0) {
        return BluetoothServiceResult.failure('Failed to get devices: ${result.stderr}');
      }

      final devices = await _parseDevicesList(result.stdout as String);
      return BluetoothServiceResult.success(devices);
    } catch (e) {
      return BluetoothServiceResult.failure('Error getting devices: $e');
    }
  }

  /// Get paired devices only
  Future<BluetoothServiceResult<List<BluetoothDevice>>> getPairedDevices() async {
    try {
      final result = await Process.run('bluetoothctl', ['paired-devices'], runInShell: true);
      if (result.exitCode != 0) {
        return BluetoothServiceResult.failure('Failed to get paired devices: ${result.stderr}');
      }

      final devices = await _parseDevicesList(result.stdout as String);
      return BluetoothServiceResult.success(devices);
    } catch (e) {
      return BluetoothServiceResult.failure('Error getting paired devices: $e');
    }
  }

  /// Pair with a device
  Future<BluetoothServiceResult<bool>> pairDevice(String deviceAddress) async {
    try {
      // First trust the device
      await Process.run('bluetoothctl', ['trust', deviceAddress], runInShell: true);
      
      // Then pair
      final result = await Process.run('bluetoothctl', ['pair', deviceAddress], runInShell: true);
      if (result.exitCode != 0) {
        return BluetoothServiceResult.failure('Failed to pair with device: ${result.stderr}');
      }

      // Update device status
      await _updateDeviceStatus(deviceAddress, BluetoothDeviceStatus.paired);
      
      return const BluetoothServiceResult.success(true);
    } catch (e) {
      return BluetoothServiceResult.failure('Error pairing device: $e');
    }
  }

  /// Connect to a paired device
  Future<BluetoothServiceResult<bool>> connectDevice(String deviceAddress) async {
    try {
      final result = await Process.run('bluetoothctl', ['connect', deviceAddress], runInShell: true);
      if (result.exitCode != 0) {
        return BluetoothServiceResult.failure('Failed to connect to device: ${result.stderr}');
      }

      // Update device status
      await _updateDeviceStatus(deviceAddress, BluetoothDeviceStatus.connected);
      
      return const BluetoothServiceResult.success(true);
    } catch (e) {
      return BluetoothServiceResult.failure('Error connecting to device: $e');
    }
  }

  /// Disconnect from a device
  Future<BluetoothServiceResult<bool>> disconnectDevice(String deviceAddress) async {
    try {
      final result = await Process.run('bluetoothctl', ['disconnect', deviceAddress], runInShell: true);
      if (result.exitCode != 0) {
        return BluetoothServiceResult.failure('Failed to disconnect from device: ${result.stderr}');
      }

      // Update device status
      await _updateDeviceStatus(deviceAddress, BluetoothDeviceStatus.paired);
      
      return const BluetoothServiceResult.success(true);
    } catch (e) {
      return BluetoothServiceResult.failure('Error disconnecting from device: $e');
    }
  }

  /// Remove/unpair a device
  Future<BluetoothServiceResult<bool>> removeDevice(String deviceAddress) async {
    try {
      final result = await Process.run('bluetoothctl', ['remove', deviceAddress], runInShell: true);
      if (result.exitCode != 0) {
        return BluetoothServiceResult.failure('Failed to remove device: ${result.stderr}');
      }

      // Remove from local list
      _devices.removeWhere((device) => device.address == deviceAddress);
      _devicesController.add(List.from(_devices));
      
      return const BluetoothServiceResult.success(true);
    } catch (e) {
      return BluetoothServiceResult.failure('Error removing device: $e');
    }
  }

  /// Get detailed info about a specific device
  Future<BluetoothServiceResult<BluetoothDevice?>> getDeviceInfo(String deviceAddress) async {
    try {
      final result = await Process.run('bluetoothctl', ['info', deviceAddress], runInShell: true);
      if (result.exitCode != 0) {
        return BluetoothServiceResult.failure('Failed to get device info: ${result.stderr}');
      }

      final device = _parseDeviceInfo(deviceAddress, result.stdout as String);
      return BluetoothServiceResult.success(device);
    } catch (e) {
      return BluetoothServiceResult.failure('Error getting device info: $e');
    }
  }

  /// Parse devices list output from bluetoothctl
  Future<List<BluetoothDevice>> _parseDevicesList(String output) async {
    final devices = <BluetoothDevice>[];
    final lines = output.split('\n');
    
    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      
      // Format: "Device AA:BB:CC:DD:EE:FF Device Name"
      final match = RegExp(r'Device ([A-Fa-f0-9:]{17}) (.+)').firstMatch(line);
      if (match != null) {
        final address = match.group(1)!;
        final name = match.group(2)!;
        
        // Get detailed info to determine status (but don't fail if it doesn't work)
        try {
          final infoResult = await getDeviceInfo(address);
          final deviceInfo = infoResult.data;
          
          final device = BluetoothDevice(
            name: name,
            address: address,
            status: deviceInfo?.status ?? BluetoothDeviceStatus.available,
            deviceType: deviceInfo?.deviceType,
            rssi: deviceInfo?.rssi,
          );
          
          devices.add(device);
        } catch (e) {
          // If getting detailed info fails, just add basic device info
          final device = BluetoothDevice(
            name: name,
            address: address,
            status: BluetoothDeviceStatus.available,
          );
          devices.add(device);
        }
      }
    }
    
    return devices;
  }

  /// Parse device info output from bluetoothctl info command
  BluetoothDevice? _parseDeviceInfo(String address, String output) {
    if (output.trim().isEmpty) return null;
    
    final lines = output.split('\n');
    String? name;
    BluetoothDeviceStatus status = BluetoothDeviceStatus.available;
    String? deviceType;
    int? rssi;
    bool paired = false;
    bool connected = false;
    
    for (final line in lines) {
      final trimmed = line.trim();
      
      if (trimmed.startsWith('Name: ')) {
        name = trimmed.substring(6);
      } else if (trimmed.startsWith('Connected: ')) {
        connected = trimmed.substring(11) == 'yes';
      } else if (trimmed.startsWith('Paired: ')) {
        paired = trimmed.substring(8) == 'yes';
      } else if (trimmed.startsWith('Class: ')) {
        deviceType = trimmed.substring(7);
      } else if (trimmed.startsWith('Icon: ')) {
        // Alternative way to determine device type
        if (deviceType == null) {
          deviceType = trimmed.substring(6);
        }
      } else if (trimmed.startsWith('RSSI: ')) {
        final rssiStr = trimmed.substring(6);
        rssi = int.tryParse(rssiStr);
      }
    }
    
    // Determine status based on connection and pairing state
    if (connected) {
      status = BluetoothDeviceStatus.connected;
    } else if (paired) {
      status = BluetoothDeviceStatus.paired;
    } else {
      status = BluetoothDeviceStatus.available;
    }
    
    // If we don't have a name, use the address as fallback
    name ??= address;
    
    return BluetoothDevice(
      name: name,
      address: address,
      status: status,
      deviceType: deviceType,
      rssi: rssi,
    );
  }

  /// Update device status in local list
  Future<void> _updateDeviceStatus(String deviceAddress, BluetoothDeviceStatus newStatus) async {
    for (int i = 0; i < _devices.length; i++) {
      if (_devices[i].address == deviceAddress) {
        _devices[i] = _devices[i].copyWith(status: newStatus);
        break;
      }
    }
    _devicesController.add(List.from(_devices));
  }

  /// Background task to discover devices while scanning
  Process? _scanProcess;

  void _discoverDevices() async {
    try {
      // Start bluetoothctl in interactive mode to monitor scan results
      _scanProcess = await Process.start('bluetoothctl', ['scan', 'on']);
      
      // Listen to stdout for device discoveries
      _scanProcess!.stdout.transform(systemEncoding.decoder).listen((output) {
        // Look for device discovery lines
        // Format: "[NEW] Device AA:BB:CC:DD:EE:FF Device Name"
        final lines = output.split('\n');
        for (final line in lines) {
          final match = RegExp(r'\[(?:NEW|CHG)\] Device ([A-Fa-f0-9:]{17}) (.+)').firstMatch(line);
          if (match != null) {
            final address = match.group(1)!;
            final name = match.group(2)!.trim();
            
            // Add or update device
            final existingIndex = _devices.indexWhere((d) => d.address == address);
            final device = BluetoothDevice(
              name: name,
              address: address,
              status: BluetoothDeviceStatus.available,
            );
            
            if (existingIndex >= 0) {
              _devices[existingIndex] = device;
            } else {
              _devices.add(device);
            }
            
            _devicesController.add(List.from(_devices));
          }
        }
      });
      
      // Also poll for paired/known devices every 5 seconds
      Timer.periodic(const Duration(seconds: 5), (timer) async {
        if (!_isScanning) {
          timer.cancel();
          return;
        }
        
        final devicesResult = await getDevices();
        if (devicesResult.isSuccess) {
          // Merge with existing discovered devices
          for (final device in devicesResult.data!) {
            if (!_devices.any((d) => d.address == device.address)) {
              _devices.add(device);
            }
          }
          _devicesController.add(List.from(_devices));
        }
      });
    } catch (e) {
      print('Error in _discoverDevices: $e');
    }
  }

  /// Dispose resources
  void dispose() {
    _devicesController.close();
    _bluetoothStateController.close();
  }
}