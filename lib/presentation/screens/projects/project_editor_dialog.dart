import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/entities/project.dart';
import '../../providers/project_editor_provider.dart';
import '../../providers/project_stats_provider.dart';
import '../../widgets/confirm_delete_dialog.dart';

/// Outcome of the project editor dialog.
enum ProjectEditorResult {
  /// The project was created or updated.
  saved,

  /// The project was deleted (its detail page should navigate away).
  deleted,
}

/// Opens the project editor dialog.
///
/// `project` is `null` for create mode. The dialog primes the shared
/// [projectEditorProvider] itself, so callers only handle the result.
Future<ProjectEditorResult?> showProjectEditorDialog(
  BuildContext context, {
  Project? project,
}) {
  return showDialog<ProjectEditorResult>(
    context: context,
    barrierDismissible: false,
    builder: (context) => ProjectEditorDialog(project: project),
  );
}

/// Create / edit / delete a project: name + accent color, with inline
/// validation and user-safe submission errors.
class ProjectEditorDialog extends ConsumerStatefulWidget {
  /// Creates the dialog; [project] is `null` in create mode.
  const ProjectEditorDialog({super.key, this.project});

  /// The project being edited, or `null`.
  final Project? project;

  @override
  ConsumerState<ProjectEditorDialog> createState() =>
      _ProjectEditorDialogState();
}

class _ProjectEditorDialogState extends ConsumerState<ProjectEditorDialog> {
  late final TextEditingController _nameController;
  bool _deleteInFlight = false;

  /// The demo palette — warm/earthy accents that sit well next to the
  /// app's green seed. Names double as semantic labels.
  static const List<({int value, String name})> _palette = [
    (value: 0xFF2E7D32, name: 'Forest green'),
    (value: 0xFF00796B, name: 'Teal'),
    (value: 0xFF827717, name: 'Olive'),
    (value: 0xFFF57F17, name: 'Amber'),
    (value: 0xFFE64A19, name: 'Rust orange'),
    (value: 0xFFAD1457, name: 'Berry pink'),
  ];

  @override
  void initState() {
    super.initState();
    final notifier = ref.read(projectEditorProvider.notifier);
    if (widget.project case final project?) {
      notifier.startEdit(project);
    } else {
      notifier.startCreate();
    }
    _nameController = TextEditingController(
      text: ref.read(projectEditorProvider).name,
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final saved = await ref.read(projectEditorProvider.notifier).save();
    if (saved && mounted) {
      Navigator.of(context).pop(ProjectEditorResult.saved);
    }
  }

  Future<void> _delete() async {
    final project = widget.project;
    if (project == null) return;
    final stats =
        ref.read(projectStatsProvider)[project.id] ??
        ProjectStats.empty;
    final taskCount =
        stats.total == 0 ? 'no tasks' : '${stats.total} task(s)';
    final confirmed = await showConfirmDeleteDialog(
      context,
      title: 'Delete project?',
      message:
          "This deletes '${project.name}' and $taskCount on this device. "
          'The deletion is saved locally and will sync to the server when '
          'you are back online.',
      confirmLabel: 'Delete project',
    );
    if (!confirmed || !mounted) return;
    setState(() => _deleteInFlight = true);
    final deleted = await ref.read(projectEditorProvider.notifier).delete();
    if (!mounted) return;
    setState(() => _deleteInFlight = false);
    if (deleted) {
      Navigator.of(context).pop(ProjectEditorResult.deleted);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(projectEditorProvider);
    final theme = Theme.of(context);
    final busy = state.isSaving || _deleteInFlight;

    return AlertDialog(
      title: Text(widget.project == null ? 'New project' : 'Edit project'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _nameController,
              autofocus: widget.project == null,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => unawaited(_save()),
              onChanged: ref.read(projectEditorProvider.notifier).setName,
              maxLength: 120,
              decoration: InputDecoration(
                labelText: 'Name',
                errorText: state.nameError,
              ),
            ),
            const SizedBox(height: 12),
            Text('Accent color', style: theme.textTheme.labelLarge),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final (:value, :name) in _palette)
                  _ColorOption(
                    value: value,
                    name: name,
                    selected: state.colorValue == value,
                    onSelect:
                        ref.read(projectEditorProvider.notifier).setColor,
                  ),
              ],
            ),
            if (state.submissionError != null) ...[
              const SizedBox(height: 12),
              Semantics(
                liveRegion: true,
                child: Row(
                  children: [
                    Icon(
                      Icons.error_outline,
                      color: theme.colorScheme.error,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        state.submissionError!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (widget.project != null) ...[
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  style: TextButton.styleFrom(
                    foregroundColor: theme.colorScheme.error,
                  ),
                  onPressed: busy ? null : () => unawaited(_delete()),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Delete project'),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed:
              busy ? null : () => Navigator.of(context).pop(null),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: busy ? null : () => unawaited(_save()),
          child: busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2.4),
                )
              : Text(widget.project == null ? 'Create' : 'Save'),
        ),
      ],
    );
  }
}

/// One accent-color swatch: a 48×48 dp target, announced as
/// "<name> color, selected/not selected".
class _ColorOption extends StatelessWidget {
  const _ColorOption({
    required this.value,
    required this.name,
    required this.selected,
    required this.onSelect,
  });

  final int value;
  final String name;
  final bool selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: selected ? '$name color, selected' : '$name color',
      button: true,
      onTap: () => onSelect(value),
      child: ExcludeSemantics(
        child: InkWell(
          onTap: () => onSelect(value),
          borderRadius: BorderRadius.circular(24),
          child: SizedBox(
            width: 48,
            height: 48,
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: Color(value),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected ? scheme.onSurface : scheme.outlineVariant,
                    width: selected ? 3 : 1,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
