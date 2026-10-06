import 'package:flutter_test/flutter_test.dart';
import 'package:super_editor/super_editor.dart';

void main() {
  group("Editor > failed transaction >", () {
    test("keeps the changes made before a command throws", () {
      final (:editor, :document, :composer, :edits) = _createEditor(text: "Hello");

      _placeCaret(editor, 5);
      edits.clear();

      expect(
        () => editor.execute([
          _insertText(5, " world"),
          const _ThrowingRequest(),
        ]),
        throwsStateError,
      );

      // Nothing is rolled back, and listeners hear about what changed.
      expect(_text(document), "Hello world");
      expect(edits, isNotEmpty);
    });

    test("keeps editing after a command throws", () {
      final (:editor, :document, :composer, :edits) = _createEditor(text: "Hello");

      _placeCaret(editor, 5);
      expect(() => editor.execute([const _ThrowingRequest()]), throwsStateError);
      edits.clear();

      editor.execute([const InsertPlainTextAtCaretRequest("!")]);

      expect(_text(document), "Hello!");
      expect(composer.selection, _caretAt(6));
      // Listeners hear about edits again, so the UI keeps updating.
      expect(edits, isNotEmpty);
    });

    test("recovers from inserting at a negative caret offset", () {
      // The production failure: a caret at offset -1 in an empty paragraph,
      // then an insert at the caret throws a RangeError.
      final (:editor, :document, :composer, :edits) = _createEditor(text: "");

      _placeCaret(editor, -1);
      expect(() => editor.execute([const InsertPlainTextAtCaretRequest("a")]), throwsRangeError);

      _placeCaret(editor, 0);
      edits.clear();
      editor.execute([const InsertPlainTextAtCaretRequest("a")]);

      expect(_text(document), "a");
      expect(edits, isNotEmpty);
    });

    test("drops commands that a failed command queued", () {
      final (:editor, :document, :composer, :edits) = _createEditor(text: "Hello");

      _placeCaret(editor, 5);
      expect(
        () => editor.execute([_ThrowingRequest(queueBeforeThrowing: _insertTextCommand(5, "LEAKED"))]),
        throwsStateError,
      );

      editor.execute([const InsertPlainTextAtCaretRequest("!")]);

      expect(_text(document), "Hello!");
    });

    test("closes an explicit transaction when a command throws", () {
      final (:editor, :document, :composer, :edits) = _createEditor(text: "Hello");

      _placeCaret(editor, 5);

      editor.startTransaction();
      editor.execute([_insertText(5, " world")]);
      expect(() => editor.execute([const _ThrowingRequest()]), throwsStateError);
      // The transaction is already closed, so ending it is a no-op.
      editor.endTransaction();

      expect(_text(document), "Hello world");

      editor.execute([_insertText(11, "!")]);
      expect(_text(document), "Hello world!");
    });

    test("undo reverts what a failed transaction changed", () {
      final (:editor, :document, :composer, :edits) = _createEditor(text: "Hello");

      _placeCaret(editor, 5);
      editor.execute([_insertText(5, " world")]);
      expect(() => editor.execute([_insertText(11, "!"), const _ThrowingRequest()]), throwsStateError);

      expect(_text(document), "Hello world!");

      // The failed transaction is its own undo step.
      editor.undo();
      expect(_text(document), "Hello world");

      editor.undo();
      expect(_text(document), "Hello");
    });

    test("keeps the changes made so far when history is disabled", () {
      final (:editor, :document, :composer, :edits) = _createEditor(text: "Hello", isHistoryEnabled: false);

      _placeCaret(editor, 5);
      edits.clear();

      expect(
        () => editor.execute([
          _insertText(5, " world"),
          const _ThrowingRequest(),
        ]),
        throwsStateError,
      );

      // Without history there is nothing to replay, so the transaction can't
      // be rolled back. It is still closed, and listeners hear about it.
      expect(_text(document), "Hello world");
      expect(edits, isNotEmpty);

      editor.execute([_insertText(11, "!")]);
      expect(_text(document), "Hello world!");
    });

    test("keeps the edit when a reaction throws", () {
      final (:editor, :document, :composer, :edits) = _createEditor(text: "Hello");
      final reaction = _ThrowingReaction();
      editor.reactionPipeline.add(reaction);

      _placeCaret(editor, 5);
      reaction.isArmed = true;

      expect(() => editor.execute([_insertText(5, "!")]), throwsStateError);

      // Rolling back here would let a broken reaction undo every edit.
      expect(_text(document), "Hello!");

      reaction.isArmed = false;
      edits.clear();
      editor.execute([_insertText(6, "?")]);

      expect(_text(document), "Hello!?");
      expect(edits, isNotEmpty);
    });
  });
}

const _paragraphId = "1";

({Editor editor, MutableDocument document, MutableDocumentComposer composer, List<EditEvent> edits}) _createEditor({
  required String text,
  bool isHistoryEnabled = true,
}) {
  final document = MutableDocument(
    nodes: [ParagraphNode(id: _paragraphId, text: AttributedText(text))],
  );
  final composer = MutableDocumentComposer();
  final editor = createDefaultDocumentEditor(
    document: document,
    composer: composer,
    isHistoryEnabled: isHistoryEnabled,
  );
  editor.requestHandlers.add(
    (editor, request) => request is _ThrowingRequest ? _ThrowingCommand(request.queueBeforeThrowing) : null,
  );

  final edits = <EditEvent>[];
  editor.addListener(FunctionalEditListener(edits.addAll));

  return (editor: editor, document: document, composer: composer, edits: edits);
}

String _text(MutableDocument document) => (document.getNodeById(_paragraphId) as TextNode).text.toPlainText();

DocumentSelection _caretAt(int offset) => DocumentSelection.collapsed(
      position: DocumentPosition(nodeId: _paragraphId, nodePosition: TextNodePosition(offset: offset)),
    );

void _placeCaret(Editor editor, int offset) {
  editor.execute([
    ChangeSelectionRequest(_caretAt(offset), SelectionChangeType.placeCaret, SelectionReason.userInteraction),
  ]);
}

InsertTextRequest _insertText(int offset, String text) => InsertTextRequest(
      documentPosition: DocumentPosition(nodeId: _paragraphId, nodePosition: TextNodePosition(offset: offset)),
      textToInsert: text,
      attributions: {},
    );

InsertTextCommand _insertTextCommand(int offset, String text) => InsertTextCommand(
      documentPosition: DocumentPosition(nodeId: _paragraphId, nodePosition: TextNodePosition(offset: offset)),
      textToInsert: text,
      attributions: {},
    );

class _ThrowingRequest implements EditRequest {
  const _ThrowingRequest({this.queueBeforeThrowing});

  /// A command to queue on the executor before throwing, like a compound
  /// command that fails part-way through.
  final EditCommand? queueBeforeThrowing;
}

class _ThrowingCommand extends EditCommand {
  const _ThrowingCommand(this.queueBeforeThrowing);

  final EditCommand? queueBeforeThrowing;

  @override
  void execute(EditContext context, CommandExecutor executor) {
    if (queueBeforeThrowing != null) {
      executor.appendCommand(queueBeforeThrowing!);
    }
    throw StateError("Command failed");
  }
}

class _ThrowingReaction extends EditReaction {
  bool isArmed = false;

  @override
  void react(EditContext editorContext, RequestDispatcher requestDispatcher, List<EditEvent> changeList) {
    if (isArmed) {
      throw StateError("Reaction failed");
    }
  }
}
