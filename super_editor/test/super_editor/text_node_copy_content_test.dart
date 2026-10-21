import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_test_robots/flutter_test_robots.dart';
import 'package:flutter_test_runners/flutter_test_runners.dart';
import 'package:super_editor/super_editor.dart';
import 'package:super_editor/super_editor_test.dart';

void main() {
  group('TextNode > copyContent >', () {
    // "Hi " + placeholder + " there": the placeholder sits at offset 3.
    TextNode nodeWith(Object placeholder) => ParagraphNode(
          id: '1',
          text: AttributedText('Hi  there', null, {3: placeholder}),
        );

    test('writes copyText for a CopyablePlaceholder', () {
      final node = nodeWith(const _Mention('@Alice'));

      expect(node.copyContent(const TextSelection(baseOffset: 0, extentOffset: 10)), 'Hi @Alice there');
    });

    test('writes the replacement character for other placeholders', () {
      final node = nodeWith(const _Plain());

      expect(
        node.copyContent(const TextSelection(baseOffset: 0, extentOffset: 10)),
        'Hi ${AttributedText.placeholderCharacter} there',
      );
    });

    test('copies only the selected range', () {
      final node = nodeWith(const _Mention('@Alice'));

      expect(node.copyContent(const TextSelection(baseOffset: 3, extentOffset: 7)), '@Alice th');
      expect(node.copyContent(const TextSelection(baseOffset: 4, extentOffset: 10)), ' there');
    });

    test('handles an upstream selection', () {
      final node = nodeWith(const _Mention('@Alice'));

      expect(node.copyContent(const TextSelection(baseOffset: 10, extentOffset: 0)), 'Hi @Alice there');
    });

    test('leaves toPlainText unchanged', () {
      final node = nodeWith(const _Mention('@Alice'));

      expect(node.text.toPlainText(), 'Hi ${AttributedText.placeholderCharacter} there');
    });
  });

  group('SuperEditor > copy >', () {
    testWidgetsOnMac('copies a CopyablePlaceholder as its copyText', (tester) async {
      await tester
          .createDocument()
          .withCustomContent(
            MutableDocument(
              nodes: [
                ParagraphNode(
                  id: '1',
                  text: AttributedText('Hi  there', null, {3: const _Mention('@Alice')}),
                ),
              ],
            ),
          )
          .useStylesheet(defaultStylesheet.copyWith(inlineWidgetBuilders: [_mentionBuilder]))
          .pump();

      await tester.placeCaretInParagraph('1', 0);
      tester.simulateClipboard();
      await tester.pressCmdA();
      await tester.pressCmdC();

      expect(tester.getSimulatedClipboardContent(), 'Hi @Alice there');
    });
  });
}

Widget? _mentionBuilder(BuildContext context, TextStyle textStyle, Object placeholder) {
  if (placeholder is! _Mention) return null;
  return Text(placeholder.copyText, style: textStyle);
}

class _Mention implements CopyablePlaceholder {
  const _Mention(this.copyText);

  @override
  final String copyText;
}

class _Plain {
  const _Plain();
}
