import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors/app_exception.dart';
import '../../core/utils/validators.dart';
import '../../domain/entities/project.dart';
import 'repositories_provider.dart';

/// The project editor's form state (create or edit mode).
///
/// [editing] is `null` in create mode. Validation errors ([nameError]) and
/// sync/storage failures ([submissionError]) are user-safe strings for
/// accessible form error semantics; both clear as the user types.
class ProjectEditorState {
  /// Creates the state.
  const ProjectEditorState({
    this.editing,
    this.name = '',
    this.colorValue = defaultColorValue,
    this.nameError,
    this.submissionError,
    this.isSaving = false,
  });

  /// Default accent for new projects (the app's deep-green seed).
  static const int defaultColorValue = 0xFF2E7D32;

  /// The project being edited, or `null` when creating.
  final Project? editing;

  /// Current name field text.
  final String name;

  /// Current accent color (ARGB int).
  final int colorValue;

  /// Validation error for the name field, or `null` when valid.
  final String? nameError;

  /// User-safe error from the last save attempt, or `null`.
  final String? submissionError;

  /// Whether a save/delete is in flight (disables the submit button).
  final bool isSaving;

  /// Whether this state edits an existing project.
  bool get isEditing => editing != null;

  /// The pristine state.
  static const ProjectEditorState initial = ProjectEditorState();

  /// Sentinel distinguishing "field not provided" from "clear this field".
  static const _unset = Object();

  /// Returns a copy with the given fields replaced; passing `null` to
  /// [nameError]/[submissionError] clears them.
  ProjectEditorState copyWith({
    Project? editing,
    String? name,
    int? colorValue,
    Object? nameError = _unset,
    Object? submissionError = _unset,
    bool? isSaving,
  }) {
    return ProjectEditorState(
      editing: editing ?? this.editing,
      name: name ?? this.name,
      colorValue: colorValue ?? this.colorValue,
      nameError: identical(nameError, _unset)
          ? this.nameError
          : nameError as String?,
      submissionError: identical(submissionError, _unset)
          ? this.submissionError
          : submissionError as String?,
      isSaving: isSaving ?? this.isSaving,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ProjectEditorState &&
        other.editing == editing &&
        other.name == name &&
        other.colorValue == colorValue &&
        other.nameError == nameError &&
        other.submissionError == submissionError &&
        other.isSaving == isSaving;
  }

  @override
  int get hashCode => Object.hash(
    editing,
    name,
    colorValue,
    nameError,
    submissionError,
    isSaving,
  );
}

/// Drives the project editor form: create, edit and delete projects with
/// inline validation.
///
/// Usage: call [startCreate] / [startEdit] when the editor opens; call
/// [save] from the submit button (returns whether it succeeded).
final projectEditorProvider =
    NotifierProvider<ProjectEditorController, ProjectEditorState>(
      ProjectEditorController.new,
    );

/// The [projectEditorProvider] notifier.
class ProjectEditorController extends Notifier<ProjectEditorState> {
  @override
  ProjectEditorState build() => ProjectEditorState.initial;

  /// Resets the form for creating a new project.
  void startCreate() {
    state = ProjectEditorState.initial;
  }

  /// Loads [project] into the form for editing.
  void startEdit(Project project) {
    state = ProjectEditorState(
      editing: project,
      name: project.name,
      colorValue: project.colorValue,
    );
  }

  /// Updates the name field, clearing stale validation errors.
  void setName(String value) {
    state = state.copyWith(name: value, nameError: null, submissionError: null);
  }

  /// Updates the accent color.
  void setColor(int value) {
    state = state.copyWith(colorValue: value, submissionError: null);
  }

  /// Clears the user-facing errors (e.g. when the error banner dismisses).
  void clearErrors() {
    state = state.copyWith(nameError: null, submissionError: null);
  }

  /// Validates and persists the form: creates or updates the project and
  /// returns whether it succeeded.
  ///
  /// Failures are mapped to [ProjectEditorState.submissionError] — never a
  /// raw exception.
  Future<bool> save() async {
    final nameError = Validators.projectName(state.name);
    if (nameError != null) {
      state = state.copyWith(nameError: nameError);
      return false;
    }
    state = state.copyWith(isSaving: true, submissionError: null);
    try {
      final repository = ref.read(projectRepositoryProvider);
      final name = state.name.trim();
      if (state.editing case final editing?) {
        await repository.updateProject(
          editing.copyWith(name: name, colorValue: state.colorValue),
        );
      } else {
        await repository.createProject(
          name: name,
          colorValue: state.colorValue,
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

  /// Deletes the edited project (cascades to its tasks) and returns
  /// whether it succeeded. A no-op returning `false` in create mode.
  Future<bool> delete() async {
    final editing = state.editing;
    if (editing == null) return false;
    state = state.copyWith(isSaving: true, submissionError: null);
    try {
      await ref.read(projectRepositoryProvider).deleteProject(editing.id);
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
}
