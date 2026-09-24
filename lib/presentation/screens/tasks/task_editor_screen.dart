import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/utils/formatters.dart';
import '../../../domain/entities/task.dart';
import '../../providers/entity_by_id_providers.dart';
import '../../providers/project_list_provider.dart';
import '../../providers/task_editor_provider.dart';
import '../../widgets/confirm_delete_dialog.dart';
import '../../widgets/empty_view.dart';

/// Create or edit a task — a full page, never a sheet.
///
/// All form state lives in [taskEditorProvider] (title validation, priority,
/// due date, project, completion, saving flag, submission error); this
/// widget renders and forwards. The project picker validates through the
/// [Form] so the dropdown announces its error like every other field.
///
/// Edit mode primes from the route's task snapshot when available and
/// otherwise loads the task through [taskByIdProvider] (deep links, state
/// restoration).
class TaskEditorScreen extends ConsumerStatefulWidget {
  /// Creates the editor in edit mode for [taskId] (with an optional
  /// snapshot passed as route `extra`), or in create mode targeting
  /// [projectId].
  const TaskEditorScreen({
    super.key,
    this.taskId,
    this.projectId,
    this.initialTask,
  });

  /// The task being edited, or `null` in create mode.
  final String? taskId;

  /// The preset project for a new task, or `null` (the editor then offers
  /// the project dropdown).
  final String? projectId;

  /// Snapshot of the edited task, when available, to prime the form without
  /// waiting for the database stream.
  final Task? initialTask;

  @override
  ConsumerState<TaskEditorScreen> createState() => _TaskEditorScreenState();
}

class _TaskEditorScreenState extends ConsumerState<TaskEditorScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _titleController;
  late final TextEditingController _notesController;

  /// Whether the editor controller has been primed (create or edit).
  bool _primed = false;

  /// Whether an edit-mode task is still being loaded from the database.
  bool _loadingTask = false;

  @override
  void initState() {
    super.initState();
    final editor = ref.read(taskEditorProvider.notifier);
    final task = widget.initialTask;
    if (task != null) {
      editor.startEdit(task);
      _primed = true;
      _titleController = TextEditingController(text: task.title);
      _notesController = TextEditingController(text: task.notes ?? '');
    } else if (widget.taskId != null) {
      _loadingTask = true;
      unawaited(_loadTask());
      _titleController = TextEditingController();
      _notesController = TextEditingController();
    } else {
      var preset = widget.projectId ?? '';
      if (preset.isEmpty) {
        final projects = ref.read(projectListProvider).value;
        if (projects != null && projects.isNotEmpty) {
          preset = projects.first.id;
        }
      }
      editor.startCreate(projectId: preset);
      _primed = true;
      _titleController = TextEditingController();
      _notesController = TextEditingController();
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _loadTask() async {
    final task = await ref.read(taskByIdProvider(widget.taskId!).future);
    if (!mounted) return;
    setState(() => _loadingTask = false);
    if (task != null) {
      ref.read(taskEditorProvider.notifier).startEdit(task);
      _titleController.text = task.title;
      _notesController.text = task.notes ?? '';
      _primed = true;
    }
  }

  Future<void> _save() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final formOk = _formKey.currentState?.validate() ?? false;
    if (!formOk) return;
    final saved = await ref.read(taskEditorProvider.notifier).save();
    if (saved && mounted) {
      context.pop();
    }
  }

  Future<void> _delete() async {
    final task = ref.read(taskEditorProvider).editing;
    if (task == null) return;
    final confirmed = await showConfirmDeleteDialog(
      context,
      title: 'Delete task?',
      message:
          "'${task.title}' will be deleted on this device. The deletion is "
          'saved locally and will sync to the server when you are back '
          'online.',
      confirmLabel: 'Delete task',
    );
    if (!confirmed || !mounted) return;
    final deleted = await ref.read(taskEditorProvider.notifier).delete();
    if (deleted && mounted) {
      context.pop();
    }
  }

  Future<void> _pickDueDate() async {
    final state = ref.read(taskEditorProvider);
    final now = DateTime.now();
    final initial = state.dueDate != null
        ? DateTime.fromMillisecondsSinceEpoch(state.dueDate!).toLocal()
        : now;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
      helpText: 'DUE DATE',
    );
    if (picked == null || !mounted) return;
    ref.read(taskEditorProvider.notifier).setDueDate(
          DateTime(picked.year, picked.month, picked.day)
              .millisecondsSinceEpoch,
        );
  }

  @override
  Widget build(BuildContext context) {
    // Create mode with projects still loading: pick the default project as
    // soon as the list arrives.
    ref.listen(projectListProvider, (previous, next) {
      final editorState = ref.read(taskEditorProvider);
      final projects = next.value;
      if (!editorState.isEditing &&
          editorState.projectId.isEmpty &&
          projects != null &&
          projects.isNotEmpty) {
        ref.read(taskEditorProvider.notifier).setProjectId(projects.first.id);
      }
    });

    final state = ref.watch(taskEditorProvider);
    final projects = ref.watch(projectListProvider).value ?? const [];

    final appBar = AppBar(
      title: Text(state.isEditing ? 'Edit task' : 'New task'),
      actions: <Widget>[
        if (state.isEditing)
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Delete task',
            onPressed: state.isSaving ? null : () => unawaited(_delete()),
          ),
      ],
    );

    if (_loadingTask) {
      return Scaffold(
        appBar: appBar,
        body: const Center(
          child: Semantics(
            label: 'Loading task',
            child: CircularProgressIndicator(),
          ),
        ),
      );
    }

    if (widget.taskId != null && !_primed) {
      return Scaffold(
        appBar: appBar,
        body: EmptyView(
          icon: Icons.task_alt,
          title: 'Task not found',
          message:
              'This task no longer exists on this device. It may have been '
              'deleted.',
          actionLabel: 'Go back',
          actionIcon: Icons.arrow_back,
          onAction: () => context.pop(),
        ),
      );
    }

    final theme = Theme.of(context);
    final projectIds = projects.map((project) => project.id).toSet();

    return Scaffold(
      appBar: appBar,
      body: SafeArea(
        top: false,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  controller: _titleController,
                  autofocus: !state.isEditing,
                  textInputAction: TextInputAction.next,
                  maxLength: 120,
                  onChanged: ref.read(taskEditorProvider.notifier).setTitle,
                  decoration: InputDecoration(
                    labelText: 'Title',
                    hintText: 'What needs to be done?',
                    errorText: state.titleError,
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _notesController,
                  keyboardType: TextInputType.multiline,
                  minLines: 3,
                  maxLines: 6,
                  onChanged: ref.read(taskEditorProvider.notifier).setNotes,
                  decoration: const InputDecoration(
                    labelText: 'Notes',
                    hintText: 'Optional details',
                  ),
                ),
                const SizedBox(height: 24),
                Text('Priority', style: theme.textTheme.labelLarge),
                const SizedBox(height: 8),
                // Horizontal scrolling keeps the segmented button from
                // overflowing at large text scales.
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SegmentedButton<TaskPriority>(
                    showSelectedIcon: false,
                    segments: [
                      for (final priority in TaskPriority.values)
                        ButtonSegment(
                          value: priority,
                          label: Text(priority.label),
                        ),
                    ],
                    selected: {state.priority},
                    onSelectionChanged: (selection) => ref
                        .read(taskEditorProvider.notifier)
                        .setPriority(selection.first),
                  ),
                ),
                const SizedBox(height: 24),
                Text('Due date', style: theme.textTheme.labelLarge),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: state.isSaving
                            ? null
                            : () => unawaited(_pickDueDate()),
                        icon: const Icon(Icons.calendar_today_outlined),
                        label: Text(
                          state.dueDate != null
                              ? AppFormatters.dueDate(state.dueDate)
                              : 'No due date',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    if (state.dueDate != null)
                      IconButton(
                        icon: const Icon(Icons.close),
                        tooltip: 'Clear due date',
                        onPressed: () => ref
                            .read(taskEditorProvider.notifier)
                            .setDueDate(null),
                      ),
                  ],
                ),
                if (state.dueDate != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    AppFormatters.dueDateRelative(state.dueDate),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                DropdownButtonFormField<String>(
                  initialValue: projectIds.contains(state.projectId)
                      ? state.projectId
                      : null,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Project',
                    prefixIcon: Icon(Icons.folder_outlined),
                  ),
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Choose a project.';
                    }
                    if (!projectIds.contains(value)) {
                      return 'This project no longer exists — choose another.';
                    }
                    return null;
                  },
                  items: [
                    for (final project in projects)
                      DropdownMenuItem(
                        value: project.id,
                        child: Text(
                          project.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      ref
                          .read(taskEditorProvider.notifier)
                          .setProjectId(value);
                    }
                  },
                  hint: projects.isEmpty ? const Text('No projects yet') : null,
                ),
                if (state.isEditing) ...[
                  const SizedBox(height: 8),
                  CheckboxListTile(
                    value: state.isCompleted,
                    onChanged: state.isSaving
                        ? null
                        : (value) {
                            if (value != null) {
                              ref
                                  .read(taskEditorProvider.notifier)
                                  .setCompleted(value);
                            }
                          },
                    title: const Text('Completed'),
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                  ),
                ],
                if (state.submissionError != null) ...[
                  const SizedBox(height: 16),
                  Semantics(
                    liveRegion: true,
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.error_outline,
                            color: theme.colorScheme.onErrorContainer,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              state.submissionError!,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onErrorContainer,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                  ),
                  onPressed: state.isSaving ? null : () => unawaited(_save()),
                  icon: state.isSaving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2.4),
                        )
                      : const Icon(Icons.check),
                  label: Text(state.isEditing ? 'Save changes' : 'Create task'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
