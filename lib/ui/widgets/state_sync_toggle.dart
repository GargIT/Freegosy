import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/library_provider.dart';
import '../../providers/romm_provider.dart';

/// Labelled per-emulator switch ("Sync save states" by default). Presentation
/// only: when [supported] is false the switch is disabled, always shows off,
/// and says "Not supported yet".
class StateSyncToggle extends StatelessWidget {
  const StateSyncToggle({
    super.key,
    required this.supported,
    required this.enabled,
    required this.onChanged,
    this.label = 'Sync save states',
  });

  final String label;
  final bool supported;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant.withValues(alpha: supported ? 0.9 : 0.55);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          SizedBox(
            height: 24,
            child: Transform.scale(
              scale: 0.7,
              alignment: Alignment.centerLeft,
              child: Switch(
                value: supported && enabled,
                onChanged: supported ? onChanged : null,
              ),
            ),
          ),
          const SizedBox(width: 4),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: TextStyle(fontSize: 11, color: muted)),
                if (!supported)
                  Text('Not supported yet', style: TextStyle(fontSize: 10, color: muted)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// [StateSyncToggle] wired to the strategy registry (support) and the
/// persisted per-emulator setting.
class StateSyncToggleRow extends ConsumerWidget {
  const StateSyncToggleRow({super.key, required this.emulatorId});

  final String emulatorId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final supported = ref
            .watch(strategyRegistryProvider)
            .asData
            ?.value
            ?.getStrategyById(emulatorId)
            ?.supportsStateSync ??
        false;
    final enabled = ref.watch(stateSyncEnabledProvider(emulatorId));
    return StateSyncToggle(
      supported: supported,
      enabled: enabled,
      onChanged: (value) =>
          ref.read(stateSyncEnabledProvider(emulatorId).notifier).update(value),
    );
  }
}

/// [StateSyncToggle] for "Auto-load resume state on launch", wired to the
/// strategy registry (support) and the persisted per-emulator setting.
class StateAutoLoadToggleRow extends ConsumerWidget {
  const StateAutoLoadToggleRow({super.key, required this.emulatorId});

  final String emulatorId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final supported = ref
            .watch(strategyRegistryProvider)
            .asData
            ?.value
            ?.getStrategyById(emulatorId)
            ?.supportsStateAutoLoad ??
        false;
    final enabled = ref.watch(stateAutoLoadEnabledProvider(emulatorId));
    return StateSyncToggle(
      label: 'Auto-load resume state on launch',
      supported: supported,
      enabled: enabled,
      onChanged: (value) =>
          ref.read(stateAutoLoadEnabledProvider(emulatorId).notifier).update(value),
    );
  }
}
