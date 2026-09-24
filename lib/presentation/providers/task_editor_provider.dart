import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors/app_exception.dart';
import '../../core/utils/validators.dart';
import '../../domain/entities/task.dart';
import 'repositories_provider.dart';

/// The task editor's form state (create or edit mode).
///
/// [editing] is `null` in create mode. Empty [notes] means "no notes" and
/// is persisted as `null` (unlike `Task.copyWith`, which cannot clear a
/// note — the controller builds the full entity instead). [dueDate] is
/// UTC millis; the presentation layer converts to/from `yyyy-MM-dd` text
/// with [Validators].
class TaskEditorState {
  /// Creates the state.
  const TaskEditorState({
    this.editing,
    this.projectId = '',
    this.title = '',
    this.notes = '',
    this.priority = TaskPriority.medium,
    this.dueDate,
    this.isCompleted = false,
    this.titleError,
    this.submissionError,
    this.isSaving = false,
  });

  /// The task being edited, or `null` when creating.
  final Task? editing;

  /// Target project for the task.
  final String projectId;

  /// Current title field text.
  final String title;

  /// Current notes field text (`''` = no notes).
  final String notes;

  /// Current priority.
  final TaskPriority priority;

  /// Due date (UTC millis), or `null` for none.
  final int? dueDate;

  /// Completion checkbox value.
  final bool isCompleted;

  /// Validation error for the title field, or `null` when valid.
  final String? titleError;

  /// User-safe error from the last save/delete, or `null`.
  final String? submissionError;

  /// Whether a save/delete is in flight (disables the submit button).
  final bool isSaving;

  /// Whether this state edits an existing task.
  bool get isEditing => editing != null;

  /// The pristine state.
  static const TaskEditorState initial = TaskEditorState();

  /// Sentinel distinguishing "field not provided" from "clear this field".
  static const _unset = Object();

  /// Returns a copy with the given fields replaced; passing `null` to
  /// [dueDate]/[titleError]/[submissionError] clears them.
  TaskEditorState copyWith({
    Task? editing,
    String? projectId,
    String? title,
    String? notes,
    TaskPriority? priority,
    Object? dueDate = _unset,
    bool? isCompleted,
    Object? titleError = _unset,
    Object? submissionError = _unset,
    bool? isSaving,
  }) {
    return TaskEditorState(
      editing: editing ?? this.editing,
      projectId: projectId ?? this.projectId,
      title: title ?? this.title,
      notes: notes ?? this.notes,
      priority: priority ?? this.priority,
      dueDate: identical(dueDate, _unset) ? this.dueDate : dueDate as int?,
      isCompleted: isCompleted ?? this.isCompleted,
      titleError: identical(titleError, _unset)
          ? this.titleError
          : titleError as String?,
      submissionError: identical(submissionError, _unset)
          ? this.submissionError
          : submissionError as String?,
      isSaving: isSaving ?? this.isSaving,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is TaskEditorState &&
        other.editing == editing &&
        other.projectId == projectId &&
        other.title == title &&
        other.notes == notes &&
        other.priority == priority &&
        other.dueDate == dueDate &&
        other.isCompleted == isCompleted &&
        other.titleError == titleError &&
        other.submissionError == submissionError &&
        other.isSaving == isSaving;
  }

  @override
  int get hashCode => Object.hash(
    editing,
    projectId,
    title,
    notes,
    priority,
    dueDate,
    isCompleted,
    titleError,
    submissionError,
    isSaving,
  );
}

/// Drives the task editor form: create, edit, delete and complete-toggle.
///
/// Usage: call [startCreate] / [startEdit] when the editor opens; call
/// [save] from the submit button (returns whether it succeeded);
/// [toggleCompleted] also works standalone from list tiles.
final taskEditorProvider =
    NotifierProvider<TaskEditorController, TaskEditorState>(
      TaskEditorController.new,
    );

/// The [taskEditorProvider] notifier.
class TaskEditorController extends Notifier<TaskEditorState> {
  @override
  TaskEditorState build() => TaskEditorState.initial;

  /// Resets the form for creating a task in [projectId].
  void startCreate({
    required String projectId,
    TaskPriority priority = TaskPriority.medium,
  }) {
    state = TaskEditorState(projectId: projectId, priority: priority);
  }

  /// Loads [task] into the form for editing.
  void startEdit(Task task) {
    state = TaskEditorState(
      editing: task,
      projectId: task.projectId,
      title: task.title,
      notes: task.notes ?? '',
      priority: task.priority,
      dueDate: task.dueDate,
      isCompleted: task.isCompleted,
    );
  }

  /// Updates the target project (moving the task between projects).
  void setProjectId(String value) {
    state = state.copyWith(projectId: value, submissionError: null);
  }

  /// Updates the title field, clearing stale validation errors.
  void setTitle(String value) {
    state = state.copyWith(
      title: value,
      titleError: null,
      submissionError: null,
    );
  }

  /// Updates the notes field (`''` will clear the stored notes on save).
  void setNotes(String value) {
    state = state.copyWith(notes: value, submissionError: null);
  }

  /// Updates the priority.
  void setPriority(TaskPriority value) {
    state = state.copyWith(priority: value, submissionError: null);
  }

  /// Sets the due date (UTC millis) or clears it with `null`.
  void setDueDate(int? millis) {
    state = state.copyWith(dueDate: millis, submissionError: null);
  }

  /// Updates the completion checkbox.
  void setCompleted(bool value) {
    state = state.copyWith(isCompleted: value, submissionError: null);
  }

  /// Clears the user-facing errors (e.g. when the error banner dismisses).
  void clearErrors() {
    state = state.copyWith(titleError: null, submissionError: null);
  }

  /// Validates and persists the form: creates or updates the task and
  /// returns whether it succeeded.
  ///
  /// Failures are mapped to [TaskEditorState.submissionError] — never a
  /// raw exception.
  Future<bool> save() async {
    final titleError = Validators.taskTitle(state.title);
    if (titleError != null) {
      state = state.copyWith(titleError: titleError);
      return false;
    }
    state = state.copyWith(isSaving: true, submissionError: null);
    try {
      final repository = ref.read(taskRepositoryProvider);
      final title = state.title.trim();
      final notes = state.notes.trim().isEmpty ? null : state.notes.trim();
      if (state.editing case final editing?) {
        await repository.updateTask(
          Task(
            id: editing.id,
            projectId: state.projectId,
            title: title,
            notes: notes,
            priority: state.priority,
            dueDate: state.dueDate,
            isCompleted: state.isCompleted,
            createdAt: editing.createdAt,
            updatedAt: editing.updatedAt,
            version: editing.version,
            isDeleted: editing.isDeleted,
          ),
        );
      } else {
        await repository.createTask(
          projectId: state.projectId,
          title: title,
          notes: notes,
          priority: state.priority,
          dueDate: state.dueDate,
        );
      }
      state = state.copyWith(isSaving: false);
      return true;
    } on AppException catch (error) {
      state = state.copyWith(
        isSaving: false,
        submissionError: error.userMessage,
      );
      return false;
    }
  }

  /// Deletes the edited task and returns whether it succeeded. A no-op
  /// returning `false` in create mode.
  Future<bool> delete() async {
    final editing = state.editing;
    if (editing == null) return false;
    state = state.copyWith(isSaving: true, submissionError: null);
    try {
      await ref.read(taskRepositoryProvider).deleteTask(editing.id);
      state = state.copyWith(isSaving: false);
      return true;
    } on AppException catch (error) {
      state = state.copyWith(
        isSaving: false,
        submissionError: error.userMessage,
      );
      return false;
    }
  }

  /// Toggles the completion of the task with [taskId] — usable from the
  /// editor as well as standalone from list tiles.
  ///
  /// Reads the current row first (never trusts a stale snapshot), so rapid
  /// taps converge correctly.
  Future<void> toggleCompleted(String taskId) async {
    try {
      final repository = ref.read(taskRepositoryProvider);
      final task = await repository.getTaskById(taskId);
      if (task == null) return;
      await repository.setCompleted(taskId, !task.isCompleted);
    } on AppException catch (error) {
      state = state.copyWith(submissionError: error.userMessage);
    }
  }
}
