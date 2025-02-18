import 'package:flutter/material.dart';

/// A standard Button using [ElevatedButton] for the CPReady app.
/// Performs [onPressed] when pressed and has a [label].
class CprStandardButton extends StatelessWidget {
  const CprStandardButton(
      {super.key, required VoidCallback onPressed, required String label,})
      : _onPressed = onPressed,
        _label = label;

  /// The function that is executed when the button is pressed.
  final VoidCallback _onPressed;

  /// The label that is displayed on the button.
  final String _label;

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.all(Colors.redAccent),
        elevation: WidgetStateProperty.all(20),
        shape: WidgetStateProperty.all(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(5),
          ),
        ),
      ),
      onPressed: _onPressed,
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Text(_label, style: Theme.of(context).textTheme.bodyLarge,),
      ),
    );
  }
}
