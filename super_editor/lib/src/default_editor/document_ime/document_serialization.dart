import 'dart:math';

import 'package:flutter/services.dart';
import 'package:super_editor/src/core/document.dart';
import 'package:super_editor/src/default_editor/document_ime/ime_desync.dart';
import 'package:super_editor/src/core/document_selection.dart';
import 'package:super_editor/src/default_editor/selection_upstream_downstream.dart';
import 'package:super_editor/src/default_editor/text.dart';
import 'package:super_editor/src/infrastructure/_logging.dart';

/// Serializes a [Document] and [DocumentSelection] into a form that's understood by
/// the Input Method Engine (IME), and vis-a-versa.
///
/// The IME only understands strings of plain text. Therefore, to make [Document] content
/// available for IME editing, the [Document] structure needs to be serialized into a run of text.
///
/// When the IME alters the given content, that plain text needs to be deserialized back into
/// a [Document] structure.
///
/// This class implements both [Document] serialization and deserialization for the IME.
class DocumentImeSerializer {
  static const _leadingCharacter = '. ';

  DocumentImeSerializer(
    this._doc,
    this.selection,
    this.composingRegion, [
    // Always prepend the placeholder characters because
    // changing the editing value when the IME is composing
    // causes the IME composition to restart.
    //
    // See https://github.com/superlistapp/super_editor/issues/1641 for details.
    this._prependedCharacterPolicy = PrependedCharacterPolicy.include,
  ]) {
    _serialize();
  }

  final Document _doc;
  DocumentSelection selection;
  DocumentRange? composingRegion;
  final imeRangesToDocTextNodes = <TextRange, String>{};
  final docTextNodesToImeRanges = <String, TextRange>{};
  final selectedNodes = <DocumentNode>[];
  late String imeText;
  final PrependedCharacterPolicy _prependedCharacterPolicy;
  String _prependedPlaceholder = '';

  void _serialize() {
    editorImeLog.fine("Creating an IME model from document, selection, and composing region");
    final buffer = StringBuffer();
    int characterCount = 0;

    if (_shouldPrependPlaceholder()) {
      // Put an arbitrary character at the front of the text so that
      // the IME will report backspace buttons when the caret sits at
      // the beginning of the node. For example, the caret is at the
      // beginning of some text and we want to combine this text with
      // the text above it when the user presses backspace.
      //
      //     Text above...
      //     |The selected text node.
      _prependedPlaceholder = _leadingCharacter;
      buffer.write(_prependedPlaceholder);
      characterCount = _prependedPlaceholder.length;
    } else {
      _prependedPlaceholder = '';
    }

    selectedNodes.clear();
    selectedNodes.addAll(_doc.getNodesInContentOrder(selection));
    for (int i = 0; i < selectedNodes.length; i += 1) {
      // Append a newline character before appending another node's text.
      //
      // The choice to separate each node with a newline was a judgement call.
      // There is no OS-level expectation for how structured content should
      // collapse down to IME content.
      if (i != 0) {
        buffer.write('\n');
        characterCount += 1;
      }

      final node = selectedNodes[i];
      if (node is! TextNode) {
        buffer.write('~');
        characterCount += 1;

        final imeRange = TextRange(start: characterCount - 1, end: characterCount);
        imeRangesToDocTextNodes[imeRange] = node.id;
        docTextNodesToImeRanges[node.id] = imeRange;

        continue;
      }

      // Cache mappings between the IME text range and the document position
      // so that we can easily convert between the two, when requested.
      final imeRange = TextRange(start: characterCount, end: characterCount + node.text.length);
      editorImeLog.finer("IME range $imeRange -> text node content '${node.text.toPlainText()}'");
      imeRangesToDocTextNodes[imeRange] = node.id;
      docTextNodesToImeRanges[node.id] = imeRange;

      // Concatenate this node's text with the previous nodes.
      buffer.write(node.text.toPlainText());
      characterCount += node.text.length;
    }

    imeText = buffer.toString();
    editorImeLog.fine("IME serialization:\n'$imeText'");
  }

  bool _shouldPrependPlaceholder() {
    if (_prependedCharacterPolicy == PrependedCharacterPolicy.include) {
      // The client explicitly requested prepended characters. This is
      // useful, for example, when a client has an existing serialization that
      // includes prepended characters and wants to compare that serialization
      // to a new serialization. The client wants to ensure that the new
      // serialization has prepended characters, too.
      return true;
    } else if (_prependedCharacterPolicy == PrependedCharacterPolicy.exclude) {
      return false;
    }

    // We want to prepend an arbitrary placeholder character whenever the
    // user's selection is collapsed at the beginning of a node. Without the
    // arbitrary character, the IME would assume that there's no content
    // before the current node and therefore it wouldn't report the backspace
    // button.
    final selectedNode = _doc.getNode(selection.extent)!;
    return selection.isCollapsed && selection.extent.nodePosition == selectedNode.beginningPosition;
  }

  bool get didPrependPlaceholder => _prependedPlaceholder.isNotEmpty;

  DocumentSelection? imeToDocumentSelection(TextSelection imeSelection) {
    editorImeLog.fine("Creating doc selection from IME selection: $imeSelection");
    if (!imeSelection.isValid) {
      editorImeLog.fine("The IME selection is empty. Returning a null document selection.");
      return null;
    }

    if (didPrependPlaceholder) {
      // The IME might be trying to select our invisible prepended characters.
      // If so, we need to adjust the IME selection bounds.
      if ((imeSelection.isCollapsed && imeSelection.extentOffset < _prependedPlaceholder.length) ||
          (imeSelection.start < _prependedPlaceholder.length && imeSelection.end == _prependedPlaceholder.length)) {
        // The IME is only trying to select our invisible characters. Return null
        // for an empty document selection.
        editorImeLog.fine("The IME only selected invisible characters. Returning a null document selection.");
        return null;
      } else if (imeSelection.start < _prependedPlaceholder.length) {
        // The IME is trying to select some invisible characters and some real
        // characters. Remove the invisible characters from the IME selection before
        // converting it to a document selection.
        editorImeLog.fine("Removing invisible characters from IME selection.");
        imeSelection = imeSelection.copyWith(
          baseOffset: max(imeSelection.baseOffset, _prependedPlaceholder.length),
          extentOffset: max(imeSelection.extentOffset, _prependedPlaceholder.length),
        );
        editorImeLog.fine("Adjusted IME selection is: $imeSelection");
      } else {
        editorImeLog.fine("The IME only selected visible characters. No adjustment necessary.");
      }
    } else {
      editorImeLog.fine("The serialization doesn't have any invisible characters. No adjustment necessary.");
    }

    editorImeLog.fine("Calculating the base DocumentPosition for the DocumentSelection");
    final base = _imeToDocumentPosition(
      imeSelection.base,
      isUpstream: imeSelection.base.affinity == TextAffinity.upstream,
    );
    editorImeLog.fine("Selection base: $base");

    editorImeLog.fine("Calculating the extent DocumentPosition for the DocumentSelection");
    final extent = _imeToDocumentPosition(
      imeSelection.extent,
      isUpstream: imeSelection.extent.affinity == TextAffinity.upstream,
    );
    editorImeLog.fine("Selection extent: $extent");

    return DocumentSelection(base: base, extent: extent);
  }

  DocumentRange? imeToDocumentRange(TextRange imeRange) {
    editorImeLog.fine("Creating doc range from IME range: $imeRange");
    if (!imeRange.isValid) {
      editorImeLog.fine("The IME range is empty. Returning null document range.");
      // The range is empty. Return null.
      return null;
    }

    if (didPrependPlaceholder) {
      // The IME might be trying to select our invisible prepended characters.
      // If so, we need to adjust the IME selection bounds.
      if ((imeRange.isCollapsed && imeRange.end < _prependedPlaceholder.length) ||
          (imeRange.start < _prependedPlaceholder.length && imeRange.end == _prependedPlaceholder.length)) {
        // The IME is only trying to select our invisible characters. Return null
        // for an empty document range.
        editorImeLog
            .fine("The IME tried to create a range around invisible characters. Returning null document range.");
        return null;
      } else {
        // The IME is trying to select some invisible characters and some real
        // characters. Remove the invisible characters from the IME range before
        // converting it to a document range.
        editorImeLog.fine("Removing arbitrary character from IME range.");
        editorImeLog.fine("Before adjustment, range: $imeRange");
        editorImeLog.fine("Prepended characters length: ${_prependedPlaceholder.length}");
        imeRange = TextRange(
          start: max(imeRange.start, _prependedPlaceholder.length),
          end: max(imeRange.end, _prependedPlaceholder.length),
        );
        editorImeLog.fine("Adjusted IME range to: $imeRange");
      }
    } else {
      editorImeLog.fine("The IME is only composing visible characters. No adjustment necessary.");
    }

    return DocumentRange(
      start: _imeToDocumentPosition(
        TextPosition(offset: imeRange.start),
        isUpstream: false,
      ),
      end: _imeToDocumentPosition(
        TextPosition(offset: imeRange.end),
        isUpstream: false,
      ),
    );
  }

  /// Returns `true` if the [imePosition] is inside the prepended placeholder,
  /// or `false` otherwise.
  ///
  /// The placeholder is a sequence of characters that are sent to the IME, but are
  /// invisible to the user.
  bool isPositionInsidePlaceholder(TextPosition imePosition) {
    if (!didPrependPlaceholder) {
      return false;
    }

    if (imePosition.offset <= -1) {
      // The given imePosition might be a selection or a composing region.
      // The IME composing position always has a value. When the IME wants
      // to describe the absence of a composing region, the offset is set to -1.
      // Therefore, this position refers to the absence of a composing region, so
      // this position isn't sitting in the placeholder.
      return false;
    }

    if (imePosition.offset >= _prependedPlaceholder.length) {
      return false;
    }

    return true;
  }

  /// Returns the first visible position in the IME content.
  ///
  /// If a placeholder is prepended, returns the first position after the placeholder,
  /// otherwise, returns the first position.
  TextPosition get firstVisiblePosition {
    return didPrependPlaceholder //
        ? TextPosition(offset: _prependedPlaceholder.length)
        : const TextPosition(offset: 0);
  }

  DocumentPosition _imeToDocumentPosition(TextPosition imePosition, {required bool isUpstream}) {
    for (final range in imeRangesToDocTextNodes.keys) {
      if (range.start <= imePosition.offset && imePosition.offset <= range.end) {
        final node = _doc.getNodeById(imeRangesToDocTextNodes[range]!)!;

        if (node is TextNode) {
          return DocumentPosition(
            nodeId: imeRangesToDocTextNodes[range]!,
            nodePosition: TextNodePosition(offset: imePosition.offset - range.start),
          );
        } else {
          if (imePosition.offset <= range.start) {
            // Return a position at the start of the node.
            return DocumentPosition(
              nodeId: node.id,
              nodePosition: node.beginningPosition,
            );
          } else {
            // Return a position at the end of the node.
            return DocumentPosition(
              nodeId: node.id,
              nodePosition: node.endPosition,
            );
          }
        }
      }
    }

    // Pancake fork: the IME asked us to map a position that isn't inside any
    // serialized node range. This is the inbound twin of the outbound composing
    // desync: the IME's view of the text has drifted past ours (e.g. an edit
    // shortened a node while a composition was active). Upstream throws here,
    // which crashes delta application and freezes input. Instead, clamp to the
    // nearest valid document position — the edit lands slightly off but the
    // editor stays alive and the next serialization re-syncs the IME — and
    // report it so we can root-cause.
    return _clampImeToDocumentPosition(imePosition);
  }

  /// Pancake fork addition. Maps an out-of-range IME position to the nearest
  /// valid [DocumentPosition] instead of throwing. See [_imeToDocumentPosition].
  DocumentPosition _clampImeToDocumentPosition(TextPosition imePosition) {
    final ranges = imeRangesToDocTextNodes.keys.toList();
    if (ranges.isEmpty) {
      // No serialized content at all — nothing to clamp to. This shouldn't
      // happen (a send requires a selection, which serializes ≥1 node), but
      // preserve the loud failure rather than invent a position.
      throw Exception(
          "Couldn't map an IME position to a document position (no serialized ranges). IME position: $imePosition");
    }

    // Ranges are stored in document order. Pick the one closest to the offset.
    TextRange nearest = ranges.first;
    int nearestDistance = _distanceToRange(imePosition.offset, nearest);
    for (final range in ranges) {
      final distance = _distanceToRange(imePosition.offset, range);
      if (distance < nearestDistance) {
        nearest = range;
        nearestDistance = distance;
      }
    }

    final clampedOffset = imePosition.offset.clamp(nearest.start, nearest.end);
    final node = _doc.getNodeById(imeRangesToDocTextNodes[nearest]!)!;

    reportImePositionDesync(
      document: _doc,
      selection: selection,
      composingRegion: composingRegion,
      imeOffset: imePosition.offset,
      clampedImeOffset: clampedOffset,
      imeTextLength: imeText.length,
      nodeId: node.id,
      onReport: onImePositionUnmappable,
    );

    if (node is TextNode) {
      return DocumentPosition(
        nodeId: node.id,
        nodePosition: TextNodePosition(offset: clampedOffset - nearest.start),
      );
    }
    return DocumentPosition(
      nodeId: node.id,
      nodePosition: clampedOffset <= nearest.start ? node.beginningPosition : node.endPosition,
    );
  }

  int _distanceToRange(int offset, TextRange range) {
    if (offset < range.start) return range.start - offset;
    if (offset > range.end) return offset - range.end;
    return 0;
  }

  /// Pancake fork addition.
  ///
  /// Invoked when an inbound IME position can't be mapped into the current
  /// document and is clamped to the nearest valid position (see
  /// [_imeToDocumentPosition]). Set once at app startup to forward to telemetry.
  /// The serializer recovers regardless of whether this is set.
  static void Function(ImePositionDesync desync)? onImePositionUnmappable;

  TextSelection documentToImeSelection(DocumentSelection docSelection) {
    editorImeLog.fine("Converting doc selection to ime selection: $docSelection");
    final selectionAffinity = _doc.getAffinityForSelection(docSelection);
    final startImePosition = _documentToImePosition(docSelection.base);
    final endImePosition = _documentToImePosition(docSelection.extent);

    editorImeLog.fine("Start IME position: $startImePosition");
    editorImeLog.fine("End IME position: $endImePosition");
    return TextSelection(
      baseOffset: startImePosition.offset,
      extentOffset: endImePosition.offset,
      affinity: selectionAffinity,
    );
  }

  TextRange documentToImeRange(DocumentRange? documentRange) {
    editorImeLog.fine("Converting doc range to ime range: $documentRange");
    if (documentRange == null) {
      editorImeLog.fine("The document range is null. Returning an empty IME range.");
      return const TextRange(start: -1, end: -1);
    }

    final startImePosition = _documentToImePosition(documentRange.start);
    final endImePosition = _documentToImePosition(documentRange.end);

    editorImeLog.fine("After converting DocumentRange to TextRange:");
    editorImeLog.fine("Start IME position: $startImePosition");
    editorImeLog.fine("End IME position: $endImePosition");
    return TextRange(
      start: startImePosition.offset,
      end: endImePosition.offset,
    );
  }

  TextPosition _documentToImePosition(DocumentPosition docPosition) {
    editorImeLog.fine("Converting DocumentPosition to IME TextPosition: $docPosition");
    final imeRange = docTextNodesToImeRanges[docPosition.nodeId];
    if (imeRange == null) {
      throw Exception("No such document position in the IME content: $docPosition");
    }

    final nodePosition = docPosition.nodePosition;

    if (nodePosition is UpstreamDownstreamNodePosition) {
      if (nodePosition.affinity == TextAffinity.upstream) {
        editorImeLog.fine("The doc position is an upstream position on a block.");
        // Return the text position before the special character,
        // e.g., "|~".
        return TextPosition(offset: imeRange.start);
      } else {
        editorImeLog.fine("The doc position is a downstream position on a block.");
        // Return the text position after the special character,
        // e.g., "~|".
        return TextPosition(offset: imeRange.start + 1);
      }
    }

    if (nodePosition is TextNodePosition) {
      return TextPosition(offset: imeRange.start + (docPosition.nodePosition as TextNodePosition).offset);
    }

    throw Exception("Super Editor doesn't know how to convert a $nodePosition into an IME-compatible selection");
  }

  TextEditingValue toTextEditingValue() {
    editorImeLog.fine("Creating TextEditingValue from document. Selection: $selection");
    editorImeLog.fine("Text:\n'$imeText'");
    final imeSelection = documentToImeSelection(selection);
    editorImeLog.fine("Selection: $imeSelection");
    final imeComposingRegion = _safeImeComposingRange();
    editorImeLog.fine("Composing region: $imeComposingRegion");

    return TextEditingValue(
      text: imeText,
      selection: imeSelection,
      composing: imeComposingRegion,
    );
  }

  /// Pancake fork addition.
  ///
  /// Maps [composingRegion] to an IME [TextRange] defensively.
  ///
  /// The upstream path calls [documentToImeRange] directly, which has two ways
  /// to produce a [TextEditingValue] the platform rejects:
  ///
  ///  1. it throws ("No such document position in the IME content") when the
  ///     composing region sits on a node that isn't part of the serialized
  ///     selection;
  ///  2. it emits `imeRange.start + offset` with no bounds check, so a region
  ///     whose offset exceeds the (now shorter) node text yields a range past
  ///     the end of [imeText].
  ///
  /// Either case desyncs the document from the IME. Because the editor never
  /// recovers a valid editing value, the platform stops accepting edits and the
  /// text field appears frozen. This happens, rarely, when an edit shortens a
  /// node while an IME composition is still active (e.g. Vietnamese / CJK
  /// input racing a content-collapsing reaction).
  ///
  /// Rather than crash/freeze, we drop a bad composing region to "none" (the
  /// IME re-establishes one on the next delta) and report it via
  /// [onComposingRegionDesync] so the host app can log it and/or clear the
  /// stale composing region to stop it recurring.
  TextRange _safeImeComposingRange() {
    final region = composingRegion;
    if (region == null) return TextRange.empty;

    TextRange range;
    try {
      range = documentToImeRange(region);
    } catch (error, stackTrace) {
      _droppedComposingRegion = true;
      reportComposingRegionDesync(
        document: _doc,
        selection: selection,
        composingRegion: region,
        imeTextLength: imeText.length,
        cause: error,
        stackTrace: stackTrace,
        onReport: onComposingRegionDesync,
      );
      return TextRange.empty;
    }

    // An invalid (-1) range is super_editor's own "no composing region" value
    // and is safe to forward as-is. Anything else must fall within [imeText].
    final isNoRegion = range.start < 0 && range.end < 0;
    final isInBounds = range.start >= 0 && range.end >= range.start && range.end <= imeText.length;
    if (!isNoRegion && !isInBounds) {
      _droppedComposingRegion = true;
      reportComposingRegionDesync(
        document: _doc,
        selection: selection,
        composingRegion: region,
        imeTextLength: imeText.length,
        cause: 'composing region out of range: $range (imeText length ${imeText.length})',
        stackTrace: StackTrace.current,
        onReport: onComposingRegionDesync,
      );
      return TextRange.empty;
    }

    return range;
  }

  /// Pancake fork addition.
  ///
  /// Whether [toTextEditingValue] had to discard an invalid composing region.
  /// The IME communication layer reads this to schedule a recovery that clears
  /// the stale composing region from the composer, so the desync doesn't repeat
  /// on every subsequent frame.
  bool get didDropComposingRegion => _droppedComposingRegion;
  bool _droppedComposingRegion = false;

  /// Pancake fork addition.
  ///
  /// Invoked whenever [toTextEditingValue] has to discard an invalid IME
  /// composing region (see [_safeImeComposingRange]). Set this once at app
  /// startup to forward the event to telemetry and, optionally, to clear the
  /// stale composing region (e.g. dispatch a `ClearComposingRegionRequest`) so
  /// the desync doesn't repeat on every subsequent frame.
  ///
  /// The serializer always self-heals regardless of whether this is set; the
  /// hook only adds observability and an opportunity for the host to recover
  /// the stored composer state.
  static void Function(ImeComposingRegionDesync desync)? onComposingRegionDesync;
}

enum PrependedCharacterPolicy {
  automatic,
  include,
  exclude,
}
