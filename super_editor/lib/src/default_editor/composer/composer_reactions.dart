import 'dart:ui';

import 'package:attributed_text/attributed_text.dart';
import 'package:collection/collection.dart';
import 'package:super_editor/src/core/document.dart';
import 'package:super_editor/src/core/document_composer.dart';
import 'package:super_editor/src/core/document_selection.dart';
import 'package:super_editor/src/core/editor.dart';
import 'package:super_editor/src/default_editor/attributions.dart';
import 'package:super_editor/src/default_editor/text.dart';

/// [EditReaction] that synchronizes the active composer styles with the caret's
/// position, when the caret moves in relevant ways.
///
/// When the user places the caret at a new position in a document, the caret might
/// sit immediately before or after some text with existing styles, e.g., bold,
/// italics, underline. Based on the situation, the user expects these styles to
/// be automatically applied to newly typed text. This reaction identifies these
/// situations and activates the desired styles in the [DocumentComposer].
///
/// Only the given [styleValuesToExtend], [styleTypesToExtend], [styleSelectorsToExtend]
/// are automatically activated.
///
/// Styles are activated when placing the caret at the beginning of a paragraph,
/// and the first character has a style:
///
///     **Hello, world**
///     |**Hello, world**
///     **F|Hello, world**
///
/// Styles are activated when placing the caret immediately after a style:
///
///     **Hello**, world
///     **Hello**|, world
///     **HelloF**|, world
///
/// The selection can change for many reasons. This reaction only activates
/// styles when it believes that the user explicitly moved the caret.
/// Conversely, if the caret moves due to the user typing a character, or
/// if the selection is expanded, then this reaction doesn't activate any
/// styles.
///
/// When the user deletes content, styles are usually re-activated from the text
/// before the caret. The exception is when the user explicitly typed with other
/// styles right after that text, e.g., toggled bold off after bold text, typed
/// some plain text, and then deleted that plain text. In that case the caret is
/// back where the user chose the other styles, so those styles are restored,
/// even if the user keeps deleting into the preceding text:
///
///     **Hello **|         <- toggle bold off
///     **Hello **world|
///     **Hello **|         <- delete "world"
///     **Hello **again|    <- still not bold
///     **Hello**|          <- delete "again" and the space
///     **Hello**again|     <- still not bold
///
/// Moving the caret, e.g., by tapping or with the arrow keys, drops these styles,
/// and styles are activated from the text around the caret again.
class UpdateComposerTextStylesReaction extends EditReaction {
  UpdateComposerTextStylesReaction({
    @Deprecated("Use styleValuesToExtend instead") //
    Set<Attribution>? stylesToExtend,
    Set<Attribution>? styleValuesToExtend,
    Set<Type> styleTypesToExtend = defaultExtendableTypes,
    Set<AttributionExtensionSelector> styleSelectorsToExtend = const {},
  })  : assert(
          stylesToExtend == null || styleValuesToExtend == null,
          "stylesToExtend and styleValuesToExtend are the same thing - you should only provide one",
        ),
        _styleValuesToExtend = styleValuesToExtend ?? stylesToExtend ?? defaultExtendableStyles,
        _styleTypesToExtend = styleTypesToExtend,
        _styleSelectorsToExtend = styleSelectorsToExtend;

  final Set<Attribution> _styleValuesToExtend;
  final Set<Type> _styleTypesToExtend;
  final Set<AttributionExtensionSelector> _styleSelectorsToExtend;

  DocumentSelection? _previousSelection;

  /// The position where the user most recently typed with styles that differ from
  /// the styles extended from the preceding text, e.g., after toggling bold off
  /// following bold text.
  _StyleOverride? _styleOverride;

  @override
  void react(EditContext editContext, RequestDispatcher requestDispatcher, List<EditEvent> changeList) {
    final lastSelectionChange =
        changeList.lastWhereOrNull((element) => element is SelectionChangeEvent) as SelectionChangeEvent?;

    _updateStyleOverride(editContext.document, changeList, lastSelectionChange);

    if (lastSelectionChange == null) {
      // The selection didn't change in this transaction.
      return;
    }

    switch (lastSelectionChange.changeType) {
      case SelectionChangeType.placeCaret:
      case SelectionChangeType.pushCaret:
      case SelectionChangeType.collapseSelection:
      case SelectionChangeType.deleteContent:
        _updateComposerStylesAtCaret(editContext);
      default:
      // We don't want change the composer styles for the other types of selection changes.
    }

    // Update our internal accounting.
    final composer = editContext.find<MutableDocumentComposer>(Editor.composerKey);
    _previousSelection = composer.selection;
  }

  /// Records, moves, or forgets the [_styleOverride] based on the given [changeList].
  void _updateStyleOverride(
    Document document,
    List<EditEvent> changeList,
    SelectionChangeEvent? lastSelectionChange,
  ) {
    for (final event in changeList) {
      if (event is! DocumentEdit) {
        continue;
      }

      final change = event.change;
      final override = _styleOverride;
      if (change is TextInsertionEvent) {
        if (override != null && change.nodeId == override.nodeId && change.offset < override.offset) {
          // Content was inserted before the override, so the text before the
          // override is no longer the text the user chose to diverge from.
          _styleOverride = null;
        }

        _recordStyleOverrideIfNeeded(document, change);
      } else if (change is TextDeletedEvent) {
        if (override != null && change.nodeId == override.nodeId && change.offset < override.offset) {
          // Text before the override was deleted, e.g., the user kept deleting past it.
          // The user hasn't chosen other styles since, so keep the override where the
          // deletion started, or shift it along with the text that follows the deletion.
          final deletionEnd = change.offset + change.deletedText.length;
          _styleOverride = _StyleOverride(
            override.nodeId,
            deletionEnd >= override.offset ? change.offset : override.offset - change.deletedText.length,
            override.styles,
          );
        }
      } else if (change is NodeDocumentChange && override != null && change.nodeId == override.nodeId) {
        // The node changed in some other way, e.g., it was split, merged, or removed.
        _styleOverride = null;
      }
    }

    switch (lastSelectionChange?.changeType) {
      case null:
      case SelectionChangeType.insertContent:
      case SelectionChangeType.deleteContent:
      case SelectionChangeType.alteredContent:
        // The caret moved as a result of typing or deleting, so the override still applies.
        break;
      default:
        // The user moved the selection, which is when styles are re-activated from
        // the text around the caret, so the override no longer applies.
        _styleOverride = null;
    }
  }

  void _recordStyleOverrideIfNeeded(Document document, TextInsertionEvent insertion) {
    if (insertion.offset == 0 || insertion.text.isEmpty) {
      // There's no preceding text whose styles could have been extended.
      return;
    }

    final node = document.getNodeById(insertion.nodeId);
    if (node is! TextNode || insertion.offset > node.text.length) {
      return;
    }

    final precedingStyles = _extendableStyles(node.text.getAllAttributionsAt(insertion.offset - 1));
    final insertedStyles = _extendableStyles(insertion.text.getAllAttributionsAt(0));
    if (const SetEquality<Attribution>().equals(precedingStyles, insertedStyles)) {
      if (_styleOverride?.nodeId == insertion.nodeId && _styleOverride?.offset == insertion.offset) {
        // The user typed with the extended styles again at the override.
        _styleOverride = null;
      }
      return;
    }

    _styleOverride = _StyleOverride(insertion.nodeId, insertion.offset, insertedStyles);
  }

  /// Returns the subset of [attributions] that this reaction extends to newly typed text,
  /// excluding links, which are handled separately.
  Set<Attribution> _extendableStyles(Set<Attribution> attributions) {
    return {
      // Extend any attributions whose value matches a desired value.
      ...attributions.where((attribution) => _styleValuesToExtend.contains(attribution)),
      // Extend any attribution whose class type matches a desired attribution type.
      if (_styleTypesToExtend.isNotEmpty) //
        ...attributions.where((attribution) => _styleTypesToExtend.contains(attribution.runtimeType)),
      // Extend any attribution that's explicitly selected by a given selector.
      if (_styleSelectorsToExtend.isNotEmpty) //
        ...attributions.where(
            (attribution) => _styleSelectorsToExtend.firstWhereOrNull((selector) => selector(attribution)) != null),
    };
  }

  void _updateComposerStylesAtCaret(EditContext editContext) {
    final document = editContext.document;
    final composer = editContext.find<MutableDocumentComposer>(Editor.composerKey);

    if (composer.selection?.extent == _previousSelection?.extent && //
        // Ignore the attributions at the caret only if the previous selection
        // was already collapsed. If the selection was expanded and the user
        // placed the caret at the extent of the selection, we should update
        // the composer attributions.
        _previousSelection?.isCollapsed == true) {
      return;
    }

    final previousSelectionExtent = _previousSelection?.extent;
    final selectionExtent = composer.selection?.extent;
    if (selectionExtent != null &&
        selectionExtent.nodePosition is TextNodePosition &&
        previousSelectionExtent != null &&
        previousSelectionExtent.nodePosition is TextNodePosition) {
      // The current and previous selections are text positions. Check for the situation where the two
      // selections are functionally equivalent, but the affinity changed.
      final selectedNodePosition = selectionExtent.nodePosition as TextNodePosition;
      final previousSelectedNodePosition = previousSelectionExtent.nodePosition as TextNodePosition;

      // Ignore the attributions at the caret only if the previous selection
      // was already collapsed. If the selection was expanded and the user
      // placed the caret at the extent of the selection, we should update
      // the composer attributions.
      if (selectionExtent.nodeId == previousSelectionExtent.nodeId &&
          selectedNodePosition.offset == previousSelectedNodePosition.offset &&
          _previousSelection?.isCollapsed == true) {
        // The text selection changed, but only the affinity is different. An affinity change doesn't alter
        // the selection from the user's perspective, so don't alter any preferences. Return.
        return;
      }
    }

    _previousSelection = composer.selection;

    composer.preferences.clearStyles();

    if (composer.selection == null || !composer.selection!.isCollapsed) {
      return;
    }

    final node = document.getNodeById(composer.selection!.extent.nodeId);
    if (node is! TextNode) {
      return;
    }

    final textPosition = composer.selection!.extent.nodePosition as TextPosition;

    if (textPosition.offset == 0 && node.text.isEmpty) {
      return;
    }

    final override = _styleOverride;
    if (override != null && override.nodeId == node.id && override.offset == textPosition.offset) {
      // The caret is back where the user chose different styles than the preceding
      // text, e.g., after deleting the text typed there. Restore those styles.
      composer.preferences.addStyles(override.styles);
      return;
    }

    late int offsetWithAttributionsToExtend;
    if (textPosition.offset == 0) {
      // The inserted text is at the very beginning of the text blob. Therefore, we should apply the
      // same attributions to the inserted text, as the text that immediately follows the inserted text.
      offsetWithAttributionsToExtend = textPosition.offset + 1;
    } else {
      // The inserted text is NOT at the very beginning of the text blob. Therefore, we should apply the
      // same attributions to the inserted text, as the text that immediately precedes the inserted text.
      offsetWithAttributionsToExtend = textPosition.offset - 1;
    }

    Set<Attribution> allAttributions = node.text.getAllAttributionsAt(offsetWithAttributionsToExtend);

    // Add desired expandable styles.
    final newStyles = _extendableStyles(allAttributions);

    // TODO: we shouldn't have such specific behavior in here. Figure out how to generalize this.
    // Add a link attribution only if the selection sits at the middle of the link.
    // As we are dealing with a collapsed selection, we shouldn't have more than one link.
    final linkAttribution = allAttributions.firstWhereOrNull((attribution) => attribution is LinkAttribution);
    if (linkAttribution != null) {
      final range = node.text.getAttributedRange({linkAttribution}, offsetWithAttributionsToExtend);

      if (textPosition.offset > 0 &&
          offsetWithAttributionsToExtend >= range.start &&
          offsetWithAttributionsToExtend < range.end) {
        newStyles.add(linkAttribution);
      }
    }

    composer.preferences.addStyles(newStyles);
  }
}

class _StyleOverride {
  const _StyleOverride(this.nodeId, this.offset, this.styles);

  final String nodeId;
  final int offset;
  final Set<Attribution> styles;
}

/// A function that returns `true` if the given [attribution] should be automatically
/// extended when the caret is placed after such an attributed character, and the
/// user continues to type - or `false` to ignore the [attribution] for future typing.
///
/// Example: Typically, when a user places the caret immediately following a bold character,
/// additional user typing also applies the bold attribution.
///
/// Example: Typically, when a user places the caret immediately following a link, the link
/// doesn't extend to include additional characters.
typedef AttributionExtensionSelector = bool Function(Attribution attribution);

final defaultExtendableStyles = Set.unmodifiable({
  boldAttribution,
  italicsAttribution,
  underlineAttribution,
  strikethroughAttribution,
  codeAttribution,
});

const defaultExtendableTypes = {
  FontSizeAttribution,
  ColorAttribution,
  BackgroundColorAttribution,
};
