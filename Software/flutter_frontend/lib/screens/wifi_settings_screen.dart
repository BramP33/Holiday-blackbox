import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/wifi_service.dart';
import '../state/providers.dart';

class WifiSettingsScreen extends ConsumerStatefulWidget {
  const WifiSettingsScreen({super.key});

  @override
  ConsumerState<WifiSettingsScreen> createState() => _WifiSettingsScreenState();
}

class _WifiSettingsScreenState extends ConsumerState<WifiSettingsScreen> {
  bool _wifiEnabled = false;
  bool _apEnabled = false;
  bool _isScanning = false;
  List<WiFiNetwork> _networks = const [];
  WiFiNetwork? _currentNetwork;
  late WiFiService _wifiService;
  StreamSubscription<List<WiFiNetwork>>? _networksSubscription;
  StreamSubscription<WiFiNetwork?>? _currentNetworkSubscription;

  @override
  void initState() {
    super.initState();
    _wifiService = WiFiService.instance;
    _initializeWiFi();
  }

  @override
  void dispose() {
    _networksSubscription?.cancel();
    _currentNetworkSubscription?.cancel();
    super.dispose();
  }

  Future<void> _initializeWiFi() async {
    await _wifiService.initialize();
    
    // Listen to network changes
    _networksSubscription = _wifiService.networksStream.listen((networks) {
      if (mounted) {
        setState(() {
          _networks = networks;
          _isScanning = false;
        });
      }
    });
    
    _currentNetworkSubscription = _wifiService.currentNetworkStream.listen((network) {
      if (mounted) {
        setState(() {
          _currentNetwork = network;
          _wifiEnabled = network != null;
        });
      }
    });
    
    // Get initial networks
    if (_wifiService.cachedNetworks.isNotEmpty) {
      setState(() {
        _networks = _wifiService.cachedNetworks;
        _currentNetwork = _wifiService.currentNetwork;
        _wifiEnabled = _currentNetwork != null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final configAsync = ref.watch(configProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Wi-Fi'),
        leading: const BackButton(),
      ),
      body: configAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) => _ErrorState(
          onRetry: () => ref.invalidate(configProvider),
          message: error.toString(),
        ),
        data: (config) {
          final apConfig = (config['ap'] as Map?)?.cast<String, dynamic>() ?? const {};

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _SwitchCard(
                title: 'Wi-Fi',
                subtitle: 'Join a wireless network',
                value: _wifiEnabled,
                icon: Icons.wifi,
                onChanged: _handleWifiToggle,
              ),
              const SizedBox(height: 12),
              _SwitchCard(
                title: 'Access Point',
                subtitle: 'Broadcast your own network',
                value: _apEnabled,
                icon: Icons.wifi_tethering,
                onChanged: _handleApToggle,
              ),
              const SizedBox(height: 24),
              if (_wifiEnabled && !_apEnabled) ...[
                Row(
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: _isScanning ? null : _startScan,
                      icon: const Icon(Icons.radar),
                      label: const Text('Scan'),
                    ),
                    if (_isScanning) ...[
                      const SizedBox(width: 12),
                      Expanded(
                        child: Row(
                          children: const [
                            SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Scanning for networks…',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 16),
                _NetworksCard(
                  networks: _networks,
                  onSelect: _handleNetworkTap,
                  onForget: _handleForgetNetwork,
                ),
              ]
              else
                _DisabledNetworksNotice(apEnabled: _apEnabled),
              if (_apEnabled) ...[
                const SizedBox(height: 24),
                _ApConfigCard(config: apConfig),
              ] else if (_currentNetwork != null) ...[
                const SizedBox(height: 24),
                _CurrentNetworkCard(network: _currentNetwork!),
              ],
            ],
          );
        },
      ),
    );
  }

  void _handleWifiToggle(bool value) {
    setState(() {
      _wifiEnabled = value;
      if (value) {
        _apEnabled = false;
        _startScan();
      } else {
        _isScanning = false;
        _wifiService.stopPeriodicScanning();
      }
    });
  }

  void _handleApToggle(bool value) {
    setState(() {
      _apEnabled = value;
      if (value) {
        _wifiEnabled = false;
        _isScanning = false;
        _wifiService.stopPeriodicScanning();
      }
    });
  }

  Future<void> _startScan() async {
    if (!_wifiEnabled || _apEnabled) return;

    setState(() {
      _isScanning = true;
    });

    try {
      await _wifiService.scanNetworks();
    } catch (e) {
      if (mounted) {
        _showSnack('Failed to scan networks: $e');
        setState(() {
          _isScanning = false;
        });
      }
    }
  }

  void _handleNetworkTap(WiFiNetwork network) async {
    if (!_wifiEnabled || _apEnabled) {
      return;
    }

    if (network.isConnected) {
      // Already connected, maybe show network details or offer to disconnect
      return;
    }

    String? password;
    if (network.isSecure) {
      password = await _promptForPassword(network);
      if (password == null) {
        return;
      }
    }

    _showSnack('Connecting to ${network.ssid}…');
    
    try {
      final result = await _wifiService.connectToNetwork(
        ssid: network.ssid,
        password: password,
      );
      
      if (result.success) {
        _showSnack('Connected to ${network.ssid}');
      } else {
        _showSnack(result.error ?? 'Failed to connect');
      }
    } catch (e) {
      _showSnack('Failed to connect: $e');
    }
  }

  Future<String?> _promptForPassword(WiFiNetwork network) async {
    final controller = TextEditingController();
    final formKey = GlobalKey<FormState>();

    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text('Join "${network.ssid}"'),
          content: Form(
            key: formKey,
            child: TextFormField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Password'),
              obscureText: true,
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return 'Enter the network password';
                }
                return null;
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (formKey.currentState?.validate() ?? false) {
                  Navigator.of(dialogContext).pop(controller.text);
                }
              },
              child: const Text('Connect'),
            ),
          ],
        );
      },
    );

    controller.dispose();
    return result;
  }

  void _handleForgetNetwork(WiFiNetwork network) async {
    try {
      await _wifiService.forgetNetwork(network.ssid);
      _showSnack('Forgot network ${network.ssid}');
    } catch (e) {
      _showSnack('Failed to forget network: $e');
    }
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _SwitchCard extends StatelessWidget {
  const _SwitchCard({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    required this.icon,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SwitchListTile.adaptive(
        value: value,
        onChanged: onChanged,
        title: Text(title),
        subtitle: Text(subtitle),
        secondary: Icon(icon),
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      ),
    );
  }
}

class _NetworksCard extends StatelessWidget {
  const _NetworksCard({
    required this.networks, 
    required this.onSelect,
    required this.onForget,
  });

  final List<WiFiNetwork> networks;
  final ValueChanged<WiFiNetwork> onSelect;
  final ValueChanged<WiFiNetwork> onForget;

  @override
  Widget build(BuildContext context) {
    if (networks.isEmpty) {
      return const _EmptyNetworksState();
    }

    return Material(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(16),
      child: Column(
        children: networks
            .map(
              (network) => Column(
                children: [
                  ListTile(
                    leading: Icon(
                      network.isSecure ? Icons.lock : Icons.wifi,
                      color: _networkIconColor(context, network),
                    ),
                    title: Text(network.ssid),
                    subtitle: Text(_networkSubtitle(network)),
                    trailing: network.isConnected
                        ? Icon(Icons.check_circle, color: Theme.of(context).colorScheme.primary)
                        : _SignalIndicator(bars: network.signalBars),
                    onTap: () => onSelect(network),
                    onLongPress: network.isKnown ? () => _showNetworkOptions(context, network, onForget) : null,
                  ),
                  if (network != networks.last)
                    const Divider(indent: 72, height: 0),
                ],
              ),
            )
            .toList(),
      ),
    );
  }

  String _networkSubtitle(WiFiNetwork network) {
    if (network.isConnected) {
      return 'Connected';
    }
    return network.isSecure ? 'Secured network' : 'Open network';
  }

  Color _networkIconColor(BuildContext context, WiFiNetwork network) {
    if (network.isConnected) {
      return Theme.of(context).colorScheme.primary;
    }
    return Theme.of(context).colorScheme.onSurfaceVariant;
  }

  void _showNetworkOptions(BuildContext context, WiFiNetwork network, ValueChanged<WiFiNetwork> onForget) {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: Text('Network Details'),
              subtitle: Text('SSID: ${network.ssid}\nSecurity: ${network.security}\nSignal: ${network.signalStrength} dBm'),
            ),
            if (network.isKnown)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Forget Network'),
                onTap: () {
                  Navigator.pop(context);
                  onForget(network);
                },
              ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

class _SignalIndicator extends StatelessWidget {
  const _SignalIndicator({required this.bars});

  final int bars;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final filledColor = theme.colorScheme.primary;
    final emptyColor = theme.colorScheme.onSurface.withOpacity(0.2);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(4, (index) {
        final active = index < bars;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 1.5),
          child: Container(
            width: 4,
            height: 8 + index * 4,
            decoration: BoxDecoration(
              color: active ? filledColor : emptyColor,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        );
      }),
    );
  }
}

class _CurrentNetworkCard extends StatelessWidget {
  const _CurrentNetworkCard({required this.network});

  final WiFiNetwork network;

  @override
  Widget build(BuildContext context) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  network.isSecure ? Icons.lock : Icons.wifi,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Connected to ${network.ssid}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                _SignalIndicator(bars: network.signalBars),
              ],
            ),
            const SizedBox(height: 16),
            _NetworkInfoRow(label: 'Network Name', value: network.ssid),
            const SizedBox(height: 12),
            _NetworkInfoRow(label: 'Security', value: network.isSecure ? network.security : 'Open'),
            const SizedBox(height: 12),
            _NetworkInfoRow(label: 'Signal Strength', value: '${network.signalStrength} dBm'),
            const SizedBox(height: 12),
            _NetworkInfoRow(label: 'Frequency', value: network.frequency),
          ],
        ),
      ),
    );
  }
}

class _NetworkInfoRow extends StatelessWidget {
  const _NetworkInfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 2),
        Text(value, style: theme.textTheme.bodyMedium),
      ],
    );
  }
}

class _ApConfigCard extends StatelessWidget {
  const _ApConfigCard({required this.config});

  final Map<String, dynamic> config;

  @override
  Widget build(BuildContext context) {
    final ssid = config['ssid']?.toString() ?? 'Unknown SSID';
    final password = config['password']?.toString() ?? 'No password';
    final channel = config['channel']?.toString() ?? 'Auto';
    final region = config['region']?.toString() ?? '—';

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Access point settings', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 16),
            _ApConfigRow(label: 'SSID', value: ssid),
            const SizedBox(height: 12),
            _ApConfigRow(label: 'Password', value: password),
            const SizedBox(height: 12),
            _ApConfigRow(label: 'Channel', value: channel),
            const SizedBox(height: 12),
            _ApConfigRow(label: 'Region', value: region),
          ],
        ),
      ),
    );
  }
}

class _ApConfigRow extends StatelessWidget {
  const _ApConfigRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 2),
        Text(value, style: theme.textTheme.bodyMedium),
      ],
    );
  }
}

class _DisabledNetworksNotice extends StatelessWidget {
  const _DisabledNetworksNotice({required this.apEnabled});

  final bool apEnabled;

  @override
  Widget build(BuildContext context) {
    final message = apEnabled
        ? 'Wi-Fi is disabled while the access point is active.'
        : 'Enable Wi-Fi to scan for nearby networks.';

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            Icon(Icons.wifi_off, color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                message,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyNetworksState extends StatelessWidget {
  const _EmptyNetworksState();

  @override
  Widget build(BuildContext context) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            Icon(Icons.wifi, color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                'No networks found nearby. Try scanning again.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.onRetry, required this.message});

  final VoidCallback onRetry;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48),
            const SizedBox(height: 12),
            Text('Unable to load configuration', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }
}
