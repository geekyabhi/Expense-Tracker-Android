import 'package:flutter/material.dart';

import '../models/app_event.dart';

IconData _iconFor(AppEvent e) {
  final t = '${e.type} ${e.name}'.toLowerCase();
  if (t.contains('birthday')) return Icons.cake;
  if (t.contains('anniversary')) return Icons.favorite;
  if (t.contains('holiday') || t.contains('festival')) return Icons.celebration;
  return Icons.event;
}

/// The popup for an event: its Title and Subtitle from Notion.
Future<void> showEventDialog(BuildContext context, AppEvent event) =>
    showDialog<void>(
      context: context,
      builder: (_) => EventDialog(event: event),
    );

class EventDialog extends StatelessWidget {
  const EventDialog({super.key, required this.event});
  final AppEvent event;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 34,
              backgroundColor: scheme.primaryContainer,
              child: Icon(_iconFor(event), size: 36, color: scheme.primary),
            ),
            const SizedBox(height: 18),
            Text(
              event.title,
              textAlign: TextAlign.center,
              style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
            ),
            if (event.subtitle.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                event.subtitle,
                textAlign: TextAlign.center,
                style: text.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
            if (event.type.isNotEmpty) ...[
              const SizedBox(height: 14),
              Chip(label: Text(event.type)),
            ],
            const SizedBox(height: 18),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }
}
