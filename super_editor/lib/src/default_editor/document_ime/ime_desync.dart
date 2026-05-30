import 'package:attributed_text/attributed_text.dart';
import 'package:super_editor/src/core/document.dart';
import 'package:super_editor/src/core/document_selection.dart';
import 'package:super_editor/src/default_editor/text.dart';
import 'package:super_editor/src/infrastructure/_logging.dart';

/// Pancake fork addition.
///
/// Diagnostic payloads, document-shape description, and reporting for IME ↔
/// document desyncs that the forked `DocumentImeSerializer` recovers from
/// instead of crashing/freezing the editor. See
/// `DocumentImeSerializer.onComposingRegionDesync` (outbound) and
/// `DocumentImeSerializer.onImePositionUnmappable` (inbound).

/// Reports an outbound (document → IME) composing-region desync: logs it and
/// notifies [onReport]. The serializer calls this after dropping the bad
/// composing region. [onReport] is the host's telemetry hook (may be null).
void reportComposingRegionDesync({
  required Document document,
  required DocumentSelection selection,
  required DocumentRange composingRegion,
  required int imeTextLength,
  required Object cause,
  required StackTrace stackTrace,
  required void Function(ImeComposingRegionDesync desync)? onReport,
}) {
  final documentShape = _describeDocumentShape(document, selection, composingRegion);

  editorImeLog.shout(
    "[ime-desync] Dropping invalid IME composing region to keep the editor alive. "
    "composingRegion=$composingRegion, selection=$selection, imeTextLength=$imeTextLength, cause=$cause\n"
    "documentShape: $documentShape",
  );

  onReport?.call(ImeComposingRegionDesync(
    composingRegion: composingRegion,
    selection: selection,
    imeTextLength: imeTextLength,
    cause: cause,
    stackTrace: stackTrace,
    documentShape: documentShape,
  ));
}

/// Reports an inbound (IME → document) position desync: logs it and notifies
/// [onReport]. The serializer calls this after clamping the unmappable position.
void reportImePositionDesync({
  required Document document,
  required DocumentSelection selection,
  required DocumentRange? composingRegion,
  required int imeOffset,
  required int clampedImeOffset,
  required int imeTextLength,
  required String nodeId,
  required void Function(ImePositionDesync desync)? onReport,
}) {
  final documentShape = _describeDocumentShape(document, selection, composingRegion);

  editorImeLog.shout(
    "[ime-desync] Couldn't map IME position (offset $imeOffset) to a document position; clamped to ime offset "
    "$clampedImeOffset (node=$nodeId) to keep the editor alive. imeTextLength=$imeTextLength\n"
    "documentShape: $documentShape",
  );

  onReport?.call(ImePositionDesync(
    imeOffset: imeOffset,
    clampedImeOffset: clampedImeOffset,
    imeTextLength: imeTextLength,
    selection: selection,
    composingRegion: composingRegion,
    documentShape: documentShape,
  ));
}

/// Builds a compact, privacy-safe description of the document's node structure
/// for an IME desync report: per-node type, block type, text length,
/// attribution kinds, and placeholder presence — but never the raw text. The
/// node holding the composing region and the node holding the caret are marked
/// so we can see "where" the desync happened relative to content.
String _describeDocumentShape(Document document, DocumentSelection selection, DocumentRange? composingRegion) {
  final composingNodeId = composingRegion?.start.nodeId;
  final caretNodeId = selection.extent.nodeId;

  final lines = <String>[];
  var index = 0;
  for (final node in document) {
    final marks = <String>[
      if (node.id == composingNodeId) 'COMPOSING',
      if (node.id == caretNodeId) 'CARET',
    ];
    final suffix = marks.isEmpty ? '' : ' <${marks.join(',')}>';
    lines.add('  [$index] ${_describeNode(node)}$suffix');
    index += 1;
  }
  return 'nodes=${document.nodeCount}\n${lines.join('\n')}';
}

String _describeNode(DocumentNode node) {
  if (node is! TextNode) {
    return node.runtimeType.toString();
  }

  final buffer = StringBuffer(node.runtimeType.toString());

  final blockType = node.getMetadataValue('blockType');
  if (blockType is NamedAttribution) {
    buffer.write('(${blockType.id})');
  }

  final plainText = node.text.toPlainText();
  buffer.write(' len=${plainText.length}');

  if (plainText.contains('￼')) {
    buffer.write(' +placeholder');
  }

  final attributionKinds = <String>{};
  for (final span in node.text.getAttributionSpansByFilter((_) => true)) {
    final attribution = span.attribution;
    attributionKinds.add(attribution is NamedAttribution ? attribution.id : attribution.runtimeType.toString());
  }
  if (attributionKinds.isNotEmpty) {
    buffer.write(' attrs=${attributionKinds.join('/')}');
  }

  return buffer.toString();
}

/// Outbound (document → IME) desync: an IME composing region that could not be
/// represented in the current document and was dropped to keep the editor
/// responsive.
class ImeComposingRegionDesync {
  ImeComposingRegionDesync({
    required this.composingRegion,
    required this.selection,
    required this.imeTextLength,
    required this.cause,
    required this.stackTrace,
    required this.documentShape,
  });

  /// The document composing region that failed to map into [imeTextLength].
  final DocumentRange composingRegion;

  /// The document selection at the time of the failure.
  final DocumentSelection selection;

  /// Length of the serialized IME text the composing region was mapped against.
  final int imeTextLength;

  /// The mapping error (an out-of-range message, or the thrown exception when
  /// the composing region's node wasn't part of the serialized selection).
  final Object cause;

  final StackTrace stackTrace;

  /// Compact, privacy-safe description of the document's node structure at the
  /// time of the failure (node types, block types, text lengths, attribution
  /// kinds, placeholder flags — no raw text). The node holding the composing
  /// region and the caret are marked.
  final String documentShape;

  @override
  String toString() => 'ImeComposingRegionDesync(composingRegion: $composingRegion, selection: $selection, '
      'imeTextLength: $imeTextLength, cause: $cause)\n$documentShape';
}

/// Inbound (IME → document) desync: an IME position that couldn't be mapped
/// into the current document and was clamped to the nearest valid position
/// instead of throwing.
class ImePositionDesync {
  ImePositionDesync({
    required this.imeOffset,
    required this.clampedImeOffset,
    required this.imeTextLength,
    required this.selection,
    required this.composingRegion,
    required this.documentShape,
  });

  /// The unmappable IME offset the platform asked us to resolve.
  final int imeOffset;

  /// The in-bounds IME offset we clamped to.
  final int clampedImeOffset;

  /// Length of the serialized IME text the offset was mapped against.
  final int imeTextLength;

  /// The document selection at the time of the failure.
  final DocumentSelection selection;

  /// The document composing region at the time of the failure, if any.
  final DocumentRange? composingRegion;

  /// Compact, privacy-safe description of the document's node structure (see
  /// [ImeComposingRegionDesync.documentShape]).
  final String documentShape;

  @override
  String toString() => 'ImePositionDesync(imeOffset: $imeOffset, clampedImeOffset: $clampedImeOffset, '
      'imeTextLength: $imeTextLength, selection: $selection, composingRegion: $composingRegion)\n$documentShape';
}
