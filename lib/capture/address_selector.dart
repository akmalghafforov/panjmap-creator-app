import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'address_lookup.dart';
import 'controller.dart';
import 'form_control.dart';

class AddressSelector extends StatefulWidget {
  final CaptureController controller;
  final String kind, label;
  final Future<void> Function(Map<String, dynamic>) onSelected;
  const AddressSelector({
    super.key,
    required this.controller,
    required this.kind,
    required this.label,
    required this.onSelected,
  });

  @override
  State<AddressSelector> createState() => _AddressSelectorState();
}

class _AddressSelectorState extends State<AddressSelector> {
  final search = TextEditingController();
  final focus = FocusNode();
  final scroll = ScrollController();
  final overlay = OverlayPortalController();
  final link = LayerLink();
  final fieldKey = GlobalKey();
  final group = Object();
  late AddressLookup lookup;
  bool searching = false;
  int highlighted = -1;
  String get choiceKey => widget.kind == 'mahallas' ? 'mahalla' : 'street';
  String get committed =>
      (widget.controller.draft?['addressChoices'] as Map?)?[choiceKey]?['name']
          as String? ??
      '';

  @override
  void initState() {
    super.initState();
    lookup = AddressLookup(widget.controller, widget.kind)
      ..addListener(changed);
    restoreLabel();
    focus.addListener(focusChanged);
    scroll.addListener(() {
      if (scroll.hasClients && scroll.position.extentAfter < 100) {
        lookup.loadMore();
      }
    });
  }

  void restoreLabel() {
    if (search.text != committed) {
      search.value = TextEditingValue(
        text: committed,
        selection: TextSelection.collapsed(offset: committed.length),
      );
    }
  }

  void changed() {
    if (!mounted) return;
    if (!lookup.active || widget.controller.busy) dismiss();
    if (!searching) restoreLabel();
    setState(() => highlighted = -1);
    scheduleMore();
  }

  void scheduleMore() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          searching &&
          scroll.hasClients &&
          scroll.position.extentAfter < 100) {
        lookup.loadMore();
      }
    });
  }

  void focusChanged() {
    if (focus.hasFocus) {
      open();
    } else {
      dismiss();
    }
  }

  void open() {
    if (searching || !lookup.active || widget.controller.busy) return;
    setState(() {
      searching = true;
      highlighted = -1;
    });
    lookup.search('');
    search.selection = TextSelection(
      baseOffset: 0,
      extentOffset: search.text.length,
    );
    overlay.show();
    scheduleMore();
  }

  void dismiss() {
    if (!searching) return;
    overlay.hide();
    setState(() {
      searching = false;
      highlighted = -1;
    });
    restoreLabel();
  }

  Future<void> select(Map<String, dynamic> row) async {
    if (!lookup.active || widget.controller.busy) return;
    dismiss();
    focus.unfocus();
    await widget.onSelected(row);
    if (mounted) restoreLabel();
  }

  KeyEventResult keyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape && searching) {
      dismiss();
      focus.unfocus();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown ||
        event.logicalKey == LogicalKeyboardKey.arrowUp) {
      open();
      final rows = lookup.rows;
      if (rows.isNotEmpty) {
        setState(
          () => highlighted = event.logicalKey == LogicalKeyboardKey.arrowDown
              ? (highlighted + 1) % rows.length
              : (highlighted <= 0 ? rows.length - 1 : highlighted - 1),
        );
        if (scroll.hasClients) {
          final offset = highlighted * 56.0;
          scroll.jumpTo(offset.clamp(0, scroll.position.maxScrollExtent));
        }
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter &&
        searching &&
        highlighted >= 0) {
      unawaited(select(lookup.rows[highlighted]));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    lookup.removeListener(changed);
    lookup.dispose();
    focus.removeListener(focusChanged);
    focus.dispose();
    search.dispose();
    scroll.dispose();
    super.dispose();
  }

  Widget dropdown(BuildContext context) {
    final box = fieldKey.currentContext!.findRenderObject() as RenderBox;
    final position = box.localToGlobal(Offset.zero);
    final media = MediaQuery.of(context);
    final bottom =
        media.size.height - media.viewInsets.bottom - media.padding.bottom;
    final below = bottom - position.dy - box.size.height - 8;
    final above = position.dy - media.padding.top - kToolbarHeight - 8;
    final upwards = below < 160 && above > below;
    final height = math.min(280.0, math.max(48.0, upwards ? above : below));
    final rows = lookup.rows;
    return Positioned(
      left: 0,
      top: 0,
      width: box.size.width,
      child: CompositedTransformFollower(
        link: link,
        showWhenUnlinked: false,
        targetAnchor: upwards ? Alignment.topLeft : Alignment.bottomLeft,
        followerAnchor: upwards ? Alignment.bottomLeft : Alignment.topLeft,
        offset: Offset(0, upwards ? -4 : 4),
        child: TapRegion(
          groupId: group,
          child: Material(
            key: ValueKey('dropdown-${widget.kind}'),
            elevation: 8,
            borderRadius: BorderRadius.circular(4),
            clipBehavior: Clip.antiAlias,
            child: SizedBox(
              height: height,
              child: NotificationListener<ScrollNotification>(
                onNotification: (_) {
                  scheduleMore();
                  return false;
                },
                child: ListView.builder(
                  controller: scroll,
                  padding: EdgeInsets.zero,
                  itemCount: rows.length + 1,
                  itemBuilder: (context, index) {
                    if (index < rows.length) {
                      final row = rows[index];
                      return ListTile(
                        selected: index == highlighted,
                        title: Text(row['name'] as String),
                        onTap: () => select(row),
                      );
                    }
                    if (lookup.loading) {
                      return const Padding(
                        padding: EdgeInsets.all(16),
                        child: LinearProgressIndicator(),
                      );
                    }
                    if (lookup.error != null) {
                      return Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          children: [
                            Text(lookup.error!),
                            TextButton(
                              onPressed: () => lookup.load(),
                              child: const Text('Повторить'),
                            ),
                          ],
                        ),
                      );
                    }
                    if (rows.isEmpty) {
                      return const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('Ничего не найдено'),
                      );
                    }
                    return const SizedBox.shrink();
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => TapRegion(
    groupId: group,
    onTapOutside: (_) {
      dismiss();
      focus.unfocus();
    },
    child: OverlayPortal(
      controller: overlay,
      overlayChildBuilder: dropdown,
      child: FormControl(
        name: choiceKey,
        error: widget.controller.fieldErrors[choiceKey],
        child: CompositedTransformTarget(
          link: link,
          child: SizedBox(
            key: fieldKey,
            child: Focus(
              onKeyEvent: keyEvent,
              child: TextField(
                groupId: group,
                focusNode: focus,
                controller: search,
                enabled: lookup.active && !widget.controller.busy,
                decoration: formDecoration(
                  widget.label,
                  suffixIcon: const Icon(Icons.arrow_drop_down),
                ),
                onTap: open,
                onChanged: (value) {
                  open();
                  lookup.search(value);
                  if (scroll.hasClients) scroll.jumpTo(0);
                },
                onSubmitted: (_) {
                  if (searching && highlighted < 0 && lookup.rows.length == 1) {
                    unawaited(select(lookup.rows.single));
                  } else {
                    dismiss();
                  }
                },
                textInputAction: TextInputAction.search,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
