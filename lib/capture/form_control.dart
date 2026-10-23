import 'package:flutter/material.dart';

// Keep the outlined control separate from supporting errors and counters.
double formControlHeight(BuildContext context) =>
    56 +
    (MediaQuery.textScalerOf(context).scale(24) - 24).clamp(0, double.infinity);

InputDecoration formDecoration(String label, {Widget? suffixIcon}) =>
    InputDecoration(
      labelText: label,
      border: const OutlineInputBorder(),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      isDense: true,
      suffixIcon: suffixIcon,
    );

class FormControl extends StatelessWidget {
  final String name;
  final Widget child;
  final String? error, counter;
  const FormControl({
    super.key,
    required this.name,
    required this.child,
    this.error,
    this.counter,
  });
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          key: ValueKey('control-$name'),
          height: formControlHeight(context),
          child: child,
        ),
        if (error != null || counter != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: error == null
                      ? const SizedBox.shrink()
                      : Text(
                          error!,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Theme.of(context).colorScheme.error,
                              ),
                        ),
                ),
                if (counter != null)
                  Text(counter!, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
      ],
    ),
  );
}
