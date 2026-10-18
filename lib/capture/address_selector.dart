import 'dart:async';

import 'package:flutter/material.dart';

import 'controller.dart';

class AddressSelector extends StatefulWidget {
  final CaptureController controller;
  final String kind, label;
  const AddressSelector({
    super.key,
    required this.controller,
    required this.kind,
    required this.label,
  });

  @override
  State<AddressSelector> createState() => _AddressSelectorState();
}

class _AddressSelectorState extends State<AddressSelector> {
  final search = TextEditingController();
  Timer? debounce;
  final rows = <Map<String, dynamic>>[];
  late final int session;
  int generation = 0, page = 0;
  bool loading = false, more = false;
  String? error;

  bool get active =>
      mounted &&
      widget.controller.authenticated &&
      widget.controller.sessionGeneration == session;

  @override
  void initState() {
    super.initState();
    session = widget.controller.sessionGeneration;
    load(reset: true);
  }

  Future<void> load({bool reset = false}) async {
    final request = ++generation;
    final next = reset ? 1 : page + 1;
    setState(() {
      loading = true;
      error = null;
      if (reset) {
        rows.clear();
        page = 0;
        more = false;
      }
    });
    try {
      final result = await widget.controller.searchAddress(
        widget.kind,
        search.text,
        page: next,
      );
      if (!active || request != generation) return;
      final found = (result['data'] as List)
          .map((r) => Map<String, dynamic>.from(r as Map))
          .toList();
      final meta = result['meta'] as Map;
      setState(() {
        rows.addAll(found);
        page = next;
        more = (meta['current_page'] as num) < (meta['last_page'] as num);
        loading = false;
      });
    } catch (_) {
      if (!active || request != generation) return;
      setState(() {
        loading = false;
        error = 'Не удалось загрузить список.';
      });
    }
  }

  @override
  void dispose() {
    ++generation;
    debounce?.cancel();
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Выбрать: ${widget.label}'),
    content: SizedBox(
      width: 350,
      height: 350,
      child: Column(
        children: [
          TextField(
            controller: search,
            decoration: const InputDecoration(labelText: 'Название'),
            onChanged: (_) {
              debounce?.cancel();
              ++generation;
              setState(() {
                rows.clear();
                loading = true;
                error = null;
                more = false;
                page = 0;
              });
              debounce = Timer(
                const Duration(milliseconds: 300),
                () => load(reset: true),
              );
            },
          ),
          if (loading) const LinearProgressIndicator(),
          if (error != null) ...[
            Text(error!),
            TextButton(
              onPressed: () => load(reset: page == 0),
              child: const Text('Повторить'),
            ),
          ],
          if (!loading && error == null && rows.isEmpty)
            const Text('Ничего не найдено'),
          Expanded(
            child: ListView(
              children: [
                for (final row in rows)
                  ListTile(
                    title: Text(row['name'] as String),
                    onTap: () {
                      if (active) Navigator.pop(context, row);
                    },
                  ),
                if (more && error == null)
                  TextButton(
                    onPressed: loading ? null : () => load(),
                    child: const Text('Загрузить ещё'),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
    ],
  );
}
