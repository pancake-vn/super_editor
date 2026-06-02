/// Telemetry events surfaced on [Editor.telemetry].
///
/// super_editor stays analytics-agnostic: these events only describe *what*
/// happened, in editor terms. A consumer (e.g. an app's product analytics)
/// listens to the stream and decides whether and how to record each event.
///
/// This exists because some editor behaviors — built-in keyboard shortcuts and
/// markdown auto-conversions — are awkward to observe from outside the editor
/// (a keyboard action may halt an event before an external observer sees it).
/// Emitting from the inside, onto one stream, gives consumers a single reliable
/// hook.
sealed class EditorTelemetryEvent {
  const EditorTelemetryEvent();
}

/// How a formatting action was triggered.
enum EditorFormattingTrigger {
  /// A formatting toolbar control was used.
  toolbar,

  /// A formatting keyboard shortcut was pressed (e.g. Cmd/Ctrl+B).
  keyboardShortcut,

  /// Markdown shorthand was typed and auto-converted (e.g. `- `, `` `code` ``).
  markdownShorthand,
}

/// Emitted when a rich-text format is applied through the editor.
///
/// [format] is a free-form, stable identifier such as `bold`, `code_block`, or
/// `bullet_list`. It's intentionally a string so the editor isn't coupled to any
/// particular consumer's taxonomy.
class FormattingAppliedEvent extends EditorTelemetryEvent {
  const FormattingAppliedEvent({required this.format, required this.trigger});

  /// Stable identifier for the format, e.g. `bold`, `italic`, `code_block`.
  final String format;

  /// Where the formatting action came from.
  final EditorFormattingTrigger trigger;

  @override
  String toString() => 'FormattingAppliedEvent(format: $format, trigger: ${trigger.name})';
}
