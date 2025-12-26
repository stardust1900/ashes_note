import 'dart:math';

import 'package:ashes_note/l10n/app_localizations.dart';
import 'package:ashes_note/logging.dart';
import 'package:flutter/material.dart';
import 'package:follow_the_leader/follow_the_leader.dart';
import 'package:overlord/follow_the_leader.dart';
import 'package:overlord/overlord.dart';
import 'package:super_editor/super_editor.dart';

/// Small toolbar that is intended to display near some selected
/// text and offer a few text formatting controls.
///
/// [EditorToolbar] expects to be displayed in a [Stack] where it
/// will position itself based on the given [anchor]. This can be
/// accomplished, for example, by adding [EditorToolbar] to the
/// application [Overlay]. Any other [Stack] should work, too.
class EditorToolbar extends StatefulWidget {
  const EditorToolbar({
    Key? key,
    required this.editorViewportKey,
    required this.editorFocusNode,
    required this.editor,
    required this.document,
    required this.composer,
    required this.anchor,
    required this.closeToolbar,
  }) : super(key: key);

  /// [GlobalKey] that should be attached to a widget that wraps the viewport
  /// area, which keeps the toolbar from appearing outside of the editor area.
  final GlobalKey editorViewportKey;

  /// A [LeaderLink] that should be attached to the boundary of the toolbar
  /// focal area, such as wrapped around the user's selection area.
  ///
  /// The toolbar is positioned relative to this anchor link.
  final LeaderLink anchor;

  /// The [FocusNode] attached to the editor to which this toolbar applies.
  final FocusNode editorFocusNode;

  /// The [editor] is used to alter document content, such as
  /// when the user selects a different block format for a
  /// text blob, e.g., paragraph, header, blockquote, or
  /// to apply styles to text.
  final Editor? editor;

  final Document document;

  /// The [composer] provides access to the user's current
  /// selection within the document, which dictates the
  /// content that is altered by the toolbar's options.
  final DocumentComposer composer;

  /// Delegate that instructs the owner of this [EditorToolbar]
  /// to close the toolbar, such as after submitting a URL
  /// for some text.
  final VoidCallback closeToolbar;

  @override
  State<EditorToolbar> createState() => _EditorToolbarState();
}

class _EditorToolbarState extends State<EditorToolbar> {
  late final FollowerAligner _toolbarAligner;
  late FollowerBoundary _screenBoundary;

  bool _showUrlField = false;
  late FocusNode _popoverFocusNode;
  late FocusNode _urlFocusNode;
  ImeAttributedTextEditingController? _urlController;

  @override
  void initState() {
    super.initState();

    _toolbarAligner = CupertinoPopoverToolbarAligner();

    _popoverFocusNode = FocusNode();

    _urlFocusNode = FocusNode();
    _urlController =
        ImeAttributedTextEditingController(
            controller: SingleLineAttributedTextEditingController(_applyLink),
          ) //
          ..onPerformActionPressed = _onPerformAction
          ..text = AttributedText("https://");
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    _screenBoundary = WidgetFollowerBoundary(
      boundaryKey: widget.editorViewportKey,
    );
  }

  @override
  void dispose() {
    _urlFocusNode.dispose();
    _urlController!.dispose();
    _popoverFocusNode.dispose();

    super.dispose();
  }

  /// Returns true if the currently selected text node is capable of being
  /// transformed into a different type text node, returns false if
  /// multiple nodes are selected, no node is selected, or the selected
  /// node is not a standard text block.
  bool _isConvertibleNode() {
    final selection = widget.composer.selection!;
    if (selection.base.nodeId != selection.extent.nodeId) {
      return false;
    }

    final selectedNode = widget.document.getNodeById(selection.extent.nodeId);
    return selectedNode is ParagraphNode || selectedNode is ListItemNode;
  }

  /// Returns the block type of the currently selected text node.
  ///
  /// Throws an exception if the currently selected node is not a text node.
  _TextType _getCurrentTextType() {
    final selectedNode = widget.document.getNodeById(
      widget.composer.selection!.extent.nodeId,
    );
    if (selectedNode is ParagraphNode) {
      final type = selectedNode.getMetadataValue('blockType');

      if (type == header1Attribution) {
        return _TextType.header1;
      } else if (type == header2Attribution) {
        return _TextType.header2;
      } else if (type == header3Attribution) {
        return _TextType.header3;
      } else if (type == blockquoteAttribution) {
        return _TextType.blockquote;
      } else {
        return _TextType.paragraph;
      }
    } else if (selectedNode is ListItemNode) {
      return selectedNode.type == ListItemType.ordered
          ? _TextType.orderedListItem
          : _TextType.unorderedListItem;
    } else {
      throw Exception(
        'Alignment does not apply to node of type: $selectedNode',
      );
    }
  }

  /// Returns the text alignment of the currently selected text node.
  ///
  /// Throws an exception if the currently selected node is not a text node.
  TextAlign _getCurrentTextAlignment() {
    final selectedNode = widget.document.getNodeById(
      widget.composer.selection!.extent.nodeId,
    );
    if (selectedNode is ParagraphNode) {
      final align = selectedNode.getMetadataValue('textAlign');
      switch (align) {
        case 'left':
          return TextAlign.left;
        case 'center':
          return TextAlign.center;
        case 'right':
          return TextAlign.right;
        case 'justify':
          return TextAlign.justify;
        default:
          return TextAlign.left;
      }
    } else {
      throw Exception('Invalid node type: $selectedNode');
    }
  }

  /// Returns true if a single text node is selected and that text node
  /// is capable of respecting alignment, returns false otherwise.
  bool _isTextAlignable() {
    final selection = widget.composer.selection!;
    if (selection.base.nodeId != selection.extent.nodeId) {
      return false;
    }

    final selectedNode = widget.document.getNodeById(selection.extent.nodeId);
    return selectedNode is ParagraphNode;
  }

  /// Converts the currently selected text node into a new type of
  /// text node, represented by [newType].
  ///
  /// For example: convert a paragraph to a blockquote, or a header
  /// to a list item.
  void _convertTextToNewType(_TextType? newType) {
    final existingTextType = _getCurrentTextType();

    if (existingTextType == newType) {
      // The text is already the desired type. Return.
      return;
    }

    if (_isListItem(existingTextType) && _isListItem(newType)) {
      widget.editor!.execute([
        ChangeListItemTypeRequest(
          nodeId: widget.composer.selection!.extent.nodeId,
          newType: newType == _TextType.orderedListItem
              ? ListItemType.ordered
              : ListItemType.unordered,
        ),
      ]);
    } else if (_isListItem(existingTextType) && !_isListItem(newType)) {
      widget.editor!.execute([
        ConvertListItemToParagraphRequest(
          nodeId: widget.composer.selection!.extent.nodeId,
          paragraphMetadata: {'blockType': _getBlockTypeAttribution(newType)},
        ),
      ]);
    } else if (!_isListItem(existingTextType) && _isListItem(newType)) {
      widget.editor!.execute([
        ConvertParagraphToListItemRequest(
          nodeId: widget.composer.selection!.extent.nodeId,
          type: newType == _TextType.orderedListItem
              ? ListItemType.ordered
              : ListItemType.unordered,
        ),
      ]);
    } else {
      // Apply a new block type to an existing paragraph node.
      widget.editor!.execute([
        ChangeParagraphBlockTypeRequest(
          nodeId: widget.composer.selection!.extent.nodeId,
          blockType: _getBlockTypeAttribution(newType),
        ),
      ]);
    }
  }

  /// Returns true if the given [_TextType] represents an
  /// ordered or unordered list item, returns false otherwise.
  bool _isListItem(_TextType? type) {
    return type == _TextType.orderedListItem ||
        type == _TextType.unorderedListItem;
  }

  /// Returns the text [Attribution] associated with the given
  /// [_TextType], e.g., [_TextType.header1] -> [header1Attribution].
  Attribution? _getBlockTypeAttribution(_TextType? newType) {
    switch (newType) {
      case _TextType.header1:
        return header1Attribution;
      case _TextType.header2:
        return header2Attribution;
      case _TextType.header3:
        return header3Attribution;
      case _TextType.blockquote:
        return blockquoteAttribution;
      case _TextType.paragraph:
      default:
        return null;
    }
  }

  /// Toggles bold styling for the current selected text.
  void _toggleBold() {
    widget.editor!.execute([
      ToggleTextAttributionsRequest(
        documentRange: widget.composer.selection!,
        attributions: {boldAttribution},
      ),
    ]);
  }

  /// Toggles italic styling for the current selected text.
  void _toggleItalics() {
    widget.editor!.execute([
      ToggleTextAttributionsRequest(
        documentRange: widget.composer.selection!,
        attributions: {italicsAttribution},
      ),
    ]);
  }

  /// Toggles strikethrough styling for the current selected text.
  void _toggleStrikethrough() {
    widget.editor!.execute([
      ToggleTextAttributionsRequest(
        documentRange: widget.composer.selection!,
        attributions: {strikethroughAttribution},
      ),
    ]);
  }

  /// Toggles superscript styling for the current selected text.
  void _toggleSuperscript() {
    widget.editor!.execute([
      ToggleTextAttributionsRequest(
        documentRange: widget.composer.selection!,
        attributions: {superscriptAttribution},
      ),
    ]);
  }

  /// Toggles subscript styling for the current selected text.
  void _toggleSubscript() {
    widget.editor!.execute([
      ToggleTextAttributionsRequest(
        documentRange: widget.composer.selection!,
        attributions: {subscriptAttribution},
      ),
    ]);
  }

  /// Returns true if the current text selection includes part
  /// or all of a single link, returns false if zero links are
  /// in the selection or if 2+ links are in the selection.
  bool _isSingleLinkSelected() {
    return _getSelectedLinkSpans().length == 1;
  }

  /// Returns true if the current text selection includes 2+
  /// links, returns false otherwise.
  bool _areMultipleLinksSelected() {
    return _getSelectedLinkSpans().length >= 2;
  }

  /// Returns any link-based [AttributionSpan]s that appear partially
  /// or wholly within the current text selection.
  Set<AttributionSpan> _getSelectedLinkSpans() {
    final selection = widget.composer.selection!;
    final baseOffset = (selection.base.nodePosition as TextPosition).offset;
    final extentOffset = (selection.extent.nodePosition as TextPosition).offset;
    final selectionStart = min(baseOffset, extentOffset);
    final selectionEnd = max(baseOffset, extentOffset);
    final selectionRange = SpanRange(selectionStart, selectionEnd - 1);

    final textNode =
        widget.document.getNodeById(selection.extent.nodeId) as TextNode;
    final text = textNode.text;

    final overlappingLinkAttributions = text.getAttributionSpansInRange(
      attributionFilter: (Attribution attribution) =>
          attribution is LinkAttribution,
      range: selectionRange,
    );

    return overlappingLinkAttributions;
  }

  /// Takes appropriate action when the toolbar's link button is
  /// pressed.
  void _onLinkPressed() {
    final selection = widget.composer.selection!;
    final baseOffset = (selection.base.nodePosition as TextPosition).offset;
    final extentOffset = (selection.extent.nodePosition as TextPosition).offset;
    final selectionStart = min(baseOffset, extentOffset);
    final selectionEnd = max(baseOffset, extentOffset);
    final selectionRange = SpanRange(selectionStart, selectionEnd - 1);

    final textNode =
        widget.document.getNodeById(selection.extent.nodeId) as TextNode;
    final text = textNode.text;

    final overlappingLinkAttributions = text.getAttributionSpansInRange(
      attributionFilter: (Attribution attribution) =>
          attribution is LinkAttribution,
      range: selectionRange,
    );

    if (overlappingLinkAttributions.length >= 2) {
      // Do nothing when multiple links are selected.
      return;
    }

    if (overlappingLinkAttributions.isNotEmpty) {
      // The selected text contains one other link.
      final overlappingLinkSpan = overlappingLinkAttributions.first;
      final isLinkSelectionOnTrailingEdge =
          (overlappingLinkSpan.start >= selectionRange.start &&
              overlappingLinkSpan.start <= selectionRange.end) ||
          (overlappingLinkSpan.end >= selectionRange.start &&
              overlappingLinkSpan.end <= selectionRange.end);

      if (isLinkSelectionOnTrailingEdge) {
        // The selected text covers the beginning, or the end, or the entire
        // existing link. Remove the link attribution from the selected text.
        text.removeAttribution(overlappingLinkSpan.attribution, selectionRange);
      } else {
        // The selected text sits somewhere within the existing link. Remove
        // the entire link attribution.
        text.removeAttribution(
          overlappingLinkSpan.attribution,
          overlappingLinkSpan.range,
        );
      }
    } else {
      // There are no other links in the selection. Show the URL text field.
      setState(() {
        _showUrlField = true;
        _urlFocusNode.requestFocus();
      });
    }
  }

  /// Takes the text from the [urlController] and applies it as a link
  /// attribution to the currently selected text.
  void _applyLink() {
    final url = _urlController!.text.toPlainText(includePlaceholders: false);

    final selection = widget.composer.selection!;
    final baseOffset = (selection.base.nodePosition as TextPosition).offset;
    final extentOffset = (selection.extent.nodePosition as TextPosition).offset;
    final selectionStart = min(baseOffset, extentOffset);
    final selectionEnd = max(baseOffset, extentOffset);
    final selectionRange = TextRange(
      start: selectionStart,
      end: selectionEnd - 1,
    );

    final textNode =
        widget.document.getNodeById(selection.extent.nodeId) as TextNode;
    final text = textNode.text;

    final trimmedRange = _trimTextRangeWhitespace(text, selectionRange);

    final linkAttribution = LinkAttribution.fromUri(Uri.parse(url));

    widget.editor!.execute([
      AddTextAttributionsRequest(
        documentRange: DocumentRange(
          start: DocumentPosition(
            nodeId: textNode.id,
            nodePosition: TextNodePosition(offset: trimmedRange.start),
          ),
          end: DocumentPosition(
            nodeId: textNode.id,
            nodePosition: TextNodePosition(offset: trimmedRange.end),
          ),
        ),
        attributions: {linkAttribution},
      ),
    ]);

    // Clear the field and hide the URL bar
    _urlController!.clearTextAndSelection();
    setState(() {
      _showUrlField = false;
      _urlFocusNode.unfocus(
        disposition: UnfocusDisposition.previouslyFocusedChild,
      );
      widget.closeToolbar();
    });
  }

  /// Given [text] and a [range] within the [text], the [range] is
  /// shortened on both sides to remove any trailing whitespace and
  /// the new range is returned.
  SpanRange _trimTextRangeWhitespace(AttributedText text, TextRange range) {
    int startOffset = range.start;
    int endOffset = range.end;

    final plainText = text.toPlainText();
    while (startOffset < range.end && plainText[startOffset] == ' ') {
      startOffset += 1;
    }
    while (endOffset > startOffset && plainText[endOffset] == ' ') {
      endOffset -= 1;
    }

    // Add 1 to the end offset because SpanRange treats the end offset to be exclusive.
    return SpanRange(startOffset, endOffset + 1);
  }

  /// Changes the alignment of the current selected text node
  /// to reflect [newAlignment].
  void _changeAlignment(TextAlign? newAlignment) {
    if (newAlignment == null) {
      return;
    }

    widget.editor!.execute([
      ChangeParagraphAlignmentRequest(
        nodeId: widget.composer.selection!.extent.nodeId,
        alignment: newAlignment,
      ),
    ]);
  }

  /// Returns the localized name for the given [_TextType], e.g.,
  /// "Paragraph" or "Header 1".
  String _getTextTypeName(_TextType textType) {
    switch (textType) {
      case _TextType.header1:
        return AppLocalizations.of(context)!.labelHeader1;
      case _TextType.header2:
        return AppLocalizations.of(context)!.labelHeader2;
      case _TextType.header3:
        return AppLocalizations.of(context)!.labelHeader3;
      case _TextType.paragraph:
        return AppLocalizations.of(context)!.labelParagraph;
      case _TextType.blockquote:
        return AppLocalizations.of(context)!.labelBlockquote;
      case _TextType.orderedListItem:
        return AppLocalizations.of(context)!.labelOrderedListItem;
      case _TextType.unorderedListItem:
        return AppLocalizations.of(context)!.labelUnorderedListItem;
    }
  }

  void _onPerformAction(TextInputAction action) {
    if (action == TextInputAction.done) {
      _applyLink();
    }
  }

  /// Called when the user selects a block type on the toolbar.
  void _onBlockTypeSelected(SuperEditorDemoTextItem? selectedItem) {
    if (selectedItem != null) {
      setState(() {
        _convertTextToNewType(
          _TextType
              .values //
              .where((e) => e.name == selectedItem.id)
              .first,
        );
      });
    }
  }

  /// Called when the user selects an alignment on the toolbar.
  void _onAlignmentSelected(SuperEditorDemoIconItem? selectedItem) {
    if (selectedItem != null) {
      setState(() {
        _changeAlignment(
          TextAlign.values.firstWhere((e) => e.name == selectedItem.id),
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return BuildInOrder(
      children: [
        FollowerFadeOutBeyondBoundary(
          link: widget.anchor,
          boundary: _screenBoundary,
          child: Follower.withAligner(
            link: widget.anchor,
            aligner: _toolbarAligner,
            boundary: _screenBoundary,
            showWhenUnlinked: false,
            child: _buildToolbars(),
          ),
        ),
      ],
    );
  }

  Widget _buildToolbars() {
    return SuperEditorPopover(
      popoverFocusNode: _popoverFocusNode,
      editorFocusNode: widget.editorFocusNode,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildToolbar(),
          if (_showUrlField) ...[const SizedBox(height: 8), _buildUrlField()],
        ],
      ),
    );
  }

  Widget _buildToolbar() {
    return IntrinsicWidth(
      child: Material(
        shape: const StadiumBorder(),
        elevation: 5,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(
          height: 40,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Only allow the user to select a new type of text node if
              // the currently selected node can be converted.
              if (_isConvertibleNode()) ...[
                Tooltip(
                  message: AppLocalizations.of(context)!.labelTextBlockType,
                  child: _buildBlockTypeSelector(),
                ),
                _buildVerticalDivider(),
              ],
              Center(
                child: IconButton(
                  onPressed: _toggleBold,
                  icon: const Icon(Icons.format_bold),
                  splashRadius: 16,
                  tooltip: AppLocalizations.of(context)!.labelBold,
                ),
              ),
              Center(
                child: IconButton(
                  onPressed: _toggleItalics,
                  icon: const Icon(Icons.format_italic),
                  splashRadius: 16,
                  tooltip: AppLocalizations.of(context)!.labelItalics,
                ),
              ),
              Center(
                child: IconButton(
                  onPressed: _toggleStrikethrough,
                  icon: const Icon(Icons.strikethrough_s),
                  splashRadius: 16,
                  tooltip: AppLocalizations.of(context)!.labelStrikethrough,
                ),
              ),
              Center(
                child: IconButton(
                  onPressed: _toggleSuperscript,
                  icon: const Icon(Icons.superscript),
                  splashRadius: 16,
                  tooltip: AppLocalizations.of(context)!.labelSuperscript,
                ),
              ),
              Center(
                child: IconButton(
                  onPressed: _toggleSubscript,
                  icon: const Icon(Icons.subscript),
                  splashRadius: 16,
                  tooltip: AppLocalizations.of(context)!.labelSubscript,
                ),
              ),
              Center(
                child: IconButton(
                  onPressed: _areMultipleLinksSelected()
                      ? null
                      : _onLinkPressed,
                  icon: const Icon(Icons.link),
                  color: _isSingleLinkSelected()
                      ? const Color(0xFF007AFF)
                      : IconTheme.of(context).color,
                  splashRadius: 16,
                  tooltip: AppLocalizations.of(context)!.labelLink,
                ),
              ),
              // Only display alignment controls if the currently selected text
              // node respects alignment. List items, for example, do not.
              if (_isTextAlignable()) //
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildVerticalDivider(),
                    Tooltip(
                      message: AppLocalizations.of(context)!.labelTextAlignment,
                      child: _buildAlignmentSelector(),
                    ),
                  ],
                ),

              _buildVerticalDivider(),
              Center(
                child: IconButton(
                  onPressed: () {},
                  icon: const Icon(Icons.more_vert),
                  splashRadius: 16,
                  tooltip: AppLocalizations.of(context)!.labelMoreOptions,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAlignmentSelector() {
    final alignment = _getCurrentTextAlignment();
    return SuperEditorDemoIconItemSelector(
      parentFocusNode: widget.editorFocusNode,
      boundaryKey: widget.editorViewportKey,
      value: SuperEditorDemoIconItem(
        id: alignment.name,
        icon: _buildTextAlignIcon(alignment),
      ),
      items:
          const [
                TextAlign.left,
                TextAlign.center,
                TextAlign.right,
                TextAlign.justify,
              ]
              .map(
                (alignment) => SuperEditorDemoIconItem(
                  icon: _buildTextAlignIcon(alignment),
                  id: alignment.name,
                ),
              )
              .toList(),
      onSelected: _onAlignmentSelected,
    );
  }

  Widget _buildBlockTypeSelector() {
    final currentBlockType = _getCurrentTextType();
    return SuperEditorDemoTextItemSelector(
      parentFocusNode: widget.editorFocusNode,
      boundaryKey: widget.editorViewportKey,
      id: SuperEditorDemoTextItem(
        id: currentBlockType.name,
        label: _getTextTypeName(currentBlockType),
      ),
      items: _TextType.values
          .map(
            (blockType) => SuperEditorDemoTextItem(
              id: blockType.name,
              label: _getTextTypeName(blockType),
            ),
          )
          .toList(),
      onSelected: _onBlockTypeSelected,
    );
  }

  Widget _buildUrlField() {
    return Material(
      color: Theme.of(context).colorScheme.surfaceBright,
      shape: const StadiumBorder(),
      elevation: 5,
      clipBehavior: Clip.hardEdge,
      child: Container(
        width: 400,
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: SuperTextField(
                focusNode: _urlFocusNode,
                textController: _urlController,
                minLines: 1,
                maxLines: 1,
                inputSource: TextInputSource.ime,
                hintBehavior: HintBehavior.displayHintUntilTextEntered,
                hintBuilder: (context) {
                  return const Text(
                    "enter a url...",
                    style: TextStyle(color: Colors.red, fontSize: 16),
                  );
                },
                textStyleBuilder: (_) {
                  return Theme.of(context).textTheme.bodyMedium!;
                },
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close),
              iconSize: 20,
              splashRadius: 16,
              padding: EdgeInsets.zero,
              onPressed: () {
                setState(() {
                  _urlFocusNode.unfocus();
                  _showUrlField = false;
                  _urlController!.clearTextAndSelection();
                });
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVerticalDivider() {
    return Container(width: 1, color: Colors.grey.shade300);
  }

  IconData _buildTextAlignIcon(TextAlign align) {
    switch (align) {
      case TextAlign.left:
      case TextAlign.start:
        return Icons.format_align_left;
      case TextAlign.center:
        return Icons.format_align_center;
      case TextAlign.right:
      case TextAlign.end:
        return Icons.format_align_right;
      case TextAlign.justify:
        return Icons.format_align_justify;
    }
  }
}

class SuperEditorDemoIconItem {
  const SuperEditorDemoIconItem({required this.id, required this.icon});

  /// The value that identifies this item.
  final String id;

  /// The icon that is displayed.
  final IconData icon;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SuperEditorDemoIconItem &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;
}

class SuperEditorDemoTextItem {
  const SuperEditorDemoTextItem({required this.id, required this.label});

  /// The value that identifies this item.
  final String id;

  /// The text that is displayed.
  final String label;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SuperEditorDemoTextItem &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;
}

enum _TextType {
  header1,
  header2,
  header3,
  paragraph,
  blockquote,
  orderedListItem,
  unorderedListItem,
}

/// Small toolbar that is intended to display over an image and
/// offer controls to expand or contract the size of the image.
///
/// [ImageFormatToolbar] expects to be displayed in a [Stack] where it
/// will position itself based on the given [anchor]. This can be
/// accomplished, for example, by adding [ImageFormatToolbar] to the
/// application [Overlay]. Any other [Stack] should work, too.
class ImageFormatToolbar extends StatefulWidget {
  const ImageFormatToolbar({
    Key? key,
    required this.anchor,
    required this.composer,
    required this.setWidth,
    required this.closeToolbar,
  }) : super(key: key);

  /// [ImageFormatToolbar] displays itself horizontally centered and
  /// slightly above the given [anchor] value.
  ///
  /// [anchor] is a [ValueNotifier] so that [ImageFormatToolbar] can
  /// reposition itself as the [Offset] value changes.
  final ValueNotifier<Offset?> anchor;

  /// The [composer] provides access to the user's current
  /// selection within the document, which dictates the
  /// content that is altered by the toolbar's options.
  final DocumentComposer composer;

  /// Callback that should update the width of the component with
  /// the given [nodeId] to match the given [width].
  final void Function(String nodeId, double? width) setWidth;

  /// Delegate that instructs the owner of this [ImageFormatToolbar]
  /// to close the toolbar.
  final VoidCallback closeToolbar;

  @override
  State<ImageFormatToolbar> createState() => _ImageFormatToolbarState();
}

class _ImageFormatToolbarState extends State<ImageFormatToolbar> {
  void _makeImageConfined() {
    widget.setWidth(widget.composer.selection!.extent.nodeId, null);
  }

  void _makeImageFullBleed() {
    widget.setWidth(widget.composer.selection!.extent.nodeId, double.infinity);
  }

  @override
  Widget build(BuildContext context) {
    return _PositionedToolbar(
      anchor: widget.anchor,
      composer: widget.composer,
      child: ValueListenableBuilder<DocumentSelection?>(
        valueListenable: widget.composer.selectionNotifier,
        builder: (context, selection, child) {
          appLog.fine("Building image toolbar. Selection: $selection");
          if (selection == null) {
            return const SizedBox();
          }
          if (selection.extent.nodePosition
              is! UpstreamDownstreamNodePosition) {
            // The user selected non-image content. This toolbar is probably
            // about to disappear. Until then, build nothing, because the
            // toolbar needs to inspect selected image to build correctly.
            return const SizedBox();
          }

          return _buildToolbar();
        },
      ),
    );
  }

  Widget _buildToolbar() {
    return Material(
      shape: const StadiumBorder(),
      elevation: 5,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
        height: 40,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: IconButton(
                  onPressed: _makeImageConfined,
                  icon: const Icon(Icons.photo_size_select_large),
                  splashRadius: 16,
                  tooltip: AppLocalizations.of(context)!.labelLimitedWidth,
                ),
              ),
              Center(
                child: IconButton(
                  onPressed: _makeImageFullBleed,
                  icon: const Icon(Icons.photo_size_select_actual),
                  splashRadius: 16,
                  tooltip: AppLocalizations.of(context)!.labelFullWidth,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PositionedToolbar extends StatelessWidget {
  const _PositionedToolbar({
    Key? key,
    required this.anchor,
    required this.composer,
    required this.child,
  }) : super(key: key);

  final ValueNotifier<Offset?> anchor;
  final DocumentComposer composer;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Offset?>(
      valueListenable: anchor,
      builder: (context, offset, _) {
        appLog.fine(
          "(Re)Building _PositionedToolbar widget due to anchor change",
        );
        if (offset == null || composer.selection == null) {
          appLog.fine("Anchor is null. Building an empty box.");
          // When no anchor position is available, or the user hasn't
          // selected any text, show nothing.
          return const SizedBox();
        }

        appLog.fine("Anchor is non-null: $offset, child: $child");
        return SizedBox.expand(
          child: Stack(
            children: [
              Positioned(
                left: offset.dx,
                top: offset.dy,
                child: FractionalTranslation(
                  translation: const Offset(-0.5, -1.4),
                  child: child,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class SingleLineAttributedTextEditingController
    extends AttributedTextEditingController {
  SingleLineAttributedTextEditingController(this.onSubmit);

  final VoidCallback onSubmit;

  @override
  void insertNewline() {
    // Don't insert newline in a single-line text field.

    // Invoke callback to take action on enter.
    onSubmit();

    // TODO: this is a hack. SuperTextField shouldn't insert newlines in a single
    // line field (#697).
  }
}

class SuperEditorDemoIconItemSelector extends StatefulWidget {
  const SuperEditorDemoIconItemSelector({
    super.key,
    this.parentFocusNode,
    this.boundaryKey,
    this.value,
    required this.items,
    required this.onSelected,
  });

  /// The [FocusNode], to which the popover list's [FocusNode] will be added as a child.
  ///
  /// In Flutter, [FocusNode]s have parents and children. This relationship allows an
  /// entire ancestor path to "have focus", but only the lowest level descendant
  /// in that path has "primary focus". This path is important because various
  /// widgets alter their presentation or behavior based on whether or not they
  /// currently have focus, even if they only have "non-primary focus".
  ///
  /// When the popover list of items is visible, that list will have primary focus.
  /// Moreover, because the popover list is built in an `Overlay`, none of your
  /// widgets are in the natural focus path for that popover list. Therefore, if you
  /// need your widget tree to retain focus while the popover list is visible, then
  /// you need to provide the [FocusNode] that the popover list should use as its
  /// parent, thereby retaining focus for your widgets.
  final FocusNode? parentFocusNode;

  /// A [GlobalKey] to a widget that determines the bounds where the popover list can be displayed.
  ///
  /// As the popover list follows the selected item, it can be displayed off-screen if this [SuperEditorDemoIconItemSelector]
  /// is close to the bottom of the screen.
  ///
  /// Passing a [boundaryKey] causes the popover list to be confined to the bounds of the widget
  /// bound to the [boundaryKey].
  ///
  /// If `null`, the popover list is confined to the screen bounds, defined by the result of `MediaQuery.sizeOf`.
  final GlobalKey? boundaryKey;

  /// The currently selected value or `null` if no item is selected.
  ///
  /// This value is used to build the button.
  final SuperEditorDemoIconItem? value;

  /// The items that will be displayed in the popover list.
  ///
  /// For each item, its [SuperEditorDemoIconItem.icon] is displayed.
  final List<SuperEditorDemoIconItem> items;

  /// Called when the user selects an item on the popover list.
  final void Function(SuperEditorDemoIconItem? value) onSelected;

  @override
  State<SuperEditorDemoIconItemSelector> createState() =>
      _SuperEditorDemoIconItemSelectorState();
}

class _SuperEditorDemoIconItemSelectorState
    extends State<SuperEditorDemoIconItemSelector> {
  /// Shows and hides the popover.
  final PopoverController _popoverController = PopoverController();

  /// The [FocusNode] of the popover list.
  final FocusNode _popoverFocusNode = FocusNode();

  @override
  void dispose() {
    _popoverController.dispose();
    _popoverFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopoverScaffold(
      controller: _popoverController,
      buttonBuilder: _buildButton,
      popoverFocusNode: _popoverFocusNode,
      parentFocusNode: widget.parentFocusNode,
      popoverBuilder: (context) => RoundedRectanglePopoverAppearance(
        child: ItemSelectionList<SuperEditorDemoIconItem>(
          value: widget.value,
          items: widget.items,
          itemBuilder: _buildItem,
          onItemSelected: _onItemSelected,
          onCancel: () => _popoverController.close(),
          focusNode: _popoverFocusNode,
        ),
      ),
    );
  }

  Widget _buildItem(
    BuildContext context,
    SuperEditorDemoIconItem item,
    bool isActive,
    VoidCallback onTap,
  ) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: isActive
            ? Colors.grey.withValues(alpha: 0.2)
            : Colors.transparent,
      ),
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(
            minHeight: kMinInteractiveDimension,
          ),
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 20.0),
          child: Icon(item.icon),
        ),
      ),
    );
  }

  Widget _buildButton(BuildContext context) {
    return SuperEditorPopoverButton(
      onTap: () => _popoverController.open(),
      padding: const EdgeInsets.only(left: 8.0, right: 24),
      child:
          widget.value ==
              null //
          ? const SizedBox()
          : Icon(widget.value!.icon),
    );
  }

  void _onItemSelected(SuperEditorDemoIconItem? value) {
    _popoverController.close();
    widget.onSelected(value);
  }
}

class SuperEditorDemoTextItemSelector extends StatefulWidget {
  const SuperEditorDemoTextItemSelector({
    super.key,
    this.parentFocusNode,
    this.boundaryKey,
    this.id,
    required this.items,
    required this.onSelected,
  });

  /// The [FocusNode], to which the popover list's [FocusNode] will be added as a child.
  ///
  /// In Flutter, [FocusNode]s have parents and children. This relationship allows an
  /// entire ancestor path to "have focus", but only the lowest level descendant
  /// in that path has "primary focus". This path is important because various
  /// widgets alter their presentation or behavior based on whether or not they
  /// currently have focus, even if they only have "non-primary focus".
  ///
  /// When the popover list of items is visible, that list will have primary focus.
  /// Moreover, because the popover list is built in an `Overlay`, none of your
  /// widgets are in the natural focus path for that popover list. Therefore, if you
  /// need your widget tree to retain focus while the popover list is visible, then
  /// you need to provide the [FocusNode] that the popover list should use as its
  /// parent, thereby retaining focus for your widgets.
  final FocusNode? parentFocusNode;

  /// A [GlobalKey] to a widget that determines the bounds where the popover list can be displayed.
  ///
  /// As the popover list follows the selected item, it can be displayed off-screen if this [SuperEditorDemoTextItemSelector]
  /// is close to the bottom of the screen.
  ///
  /// Passing a [boundaryKey] causes the popover list to be confined to the bounds of the widget
  /// bound to the [boundaryKey].
  ///
  /// If `null`, the popover list is confined to the screen bounds, defined by the result of `MediaQuery.sizeOf`.
  final GlobalKey? boundaryKey;

  /// The currently selected value or `null` if no item is selected.
  ///
  /// This value is used to build the button.
  final SuperEditorDemoTextItem? id;

  /// The items that will be displayed in the popover list.
  ///
  /// For each item, its [SuperEditorDemoTextItem.label] is displayed.
  final List<SuperEditorDemoTextItem> items;

  /// Called when the user selects an item on the popover list.
  final void Function(SuperEditorDemoTextItem? value) onSelected;

  @override
  State<SuperEditorDemoTextItemSelector> createState() =>
      _SuperEditorDemoTextItemSelectorState();
}

class _SuperEditorDemoTextItemSelectorState
    extends State<SuperEditorDemoTextItemSelector> {
  /// Shows and hides the popover.
  final PopoverController _popoverController = PopoverController();

  /// The [FocusNode] of the popover list.
  final FocusNode _popoverFocusNode = FocusNode();

  @override
  void dispose() {
    _popoverController.dispose();
    _popoverFocusNode.dispose();
    super.dispose();
  }

  void _onItemSelected(SuperEditorDemoTextItem? value) {
    _popoverController.close();
    widget.onSelected(value);
  }

  @override
  Widget build(BuildContext context) {
    return PopoverScaffold(
      controller: _popoverController,
      buttonBuilder: _buildButton,
      popoverFocusNode: _popoverFocusNode,
      parentFocusNode: widget.parentFocusNode,
      boundaryKey: widget.boundaryKey,
      popoverBuilder: (context) => RoundedRectanglePopoverAppearance(
        child: ItemSelectionList<SuperEditorDemoTextItem>(
          focusNode: _popoverFocusNode,
          value: widget.id,
          items: widget.items,
          itemBuilder: _buildPopoverListItem,
          onItemSelected: _onItemSelected,
          onCancel: () => _popoverController.close(),
        ),
      ),
    );
  }

  Widget _buildButton(BuildContext context) {
    return SuperEditorPopoverButton(
      padding: const EdgeInsets.only(left: 16.0, right: 24),
      onTap: () => _popoverController.open(),
      child:
          widget.id ==
              null //
          ? const SizedBox()
          : Text(
              widget.id!.label,
              // style: const TextStyle(color: Colors.black, fontSize: 12),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
    );
  }

  Widget _buildPopoverListItem(
    BuildContext context,
    SuperEditorDemoTextItem item,
    bool isActive,
    VoidCallback onTap,
  ) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: isActive
            ? Colors.grey.withValues(alpha: 0.2)
            : Colors.transparent,
      ),
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(
            minHeight: kMinInteractiveDimension,
          ),
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 20.0),
          child: Text(item.label, style: Theme.of(context).textTheme.bodySmall),
        ),
      ),
    );
  }
}

class SuperEditorPopoverButton extends StatelessWidget {
  const SuperEditorPopoverButton({
    super.key,
    this.padding,
    required this.onTap,
    this.child,
  });

  /// Padding around the [child].
  final EdgeInsets? padding;

  /// Called when the user taps the button.
  final VoidCallback onTap;

  /// The Widget displayed inside this button.
  ///
  /// If `null`, only the arrow is displayed.
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Center(
        child: Stack(
          alignment: Alignment.centerLeft,
          children: [
            if (child != null) //
              Padding(padding: padding ?? EdgeInsets.zero, child: child),
            const Positioned(right: 0, child: Icon(Icons.arrow_drop_down)),
          ],
        ),
      ),
    );
  }
}
