import 'package:flutter/material.dart';
import '../domain/playback.dart';
import 'player_theme.dart';

class PlayerRateInput extends StatefulWidget {
  const PlayerRateInput({super.key, required this.rate, required this.onApply});
  final double rate;
  final Future<void> Function(double) onApply;

  @override
  State<PlayerRateInput> createState() => _PlayerRateInputState();
}

class _PlayerRateInputState extends State<PlayerRateInput> {
  late final input = TextEditingController(text: '${widget.rate}');
  String? error;
  bool busy = false;

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  Future<void> apply() async {
    if (busy) return;
    final value = double.tryParse(
      input.text.trim().replaceAll(',', '.').replaceAll('。', '.'),
    );
    if (value == null ||
        !value.isFinite ||
        value < PlaybackPreferences.minRate ||
        value > PlaybackPreferences.maxRate) {
      setState(() => error = '请输入 0.25 至 4 之间的倍速');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.onApply(double.parse(value.toStringAsFixed(2)));
    } catch (_) {
      if (mounted) setState(() => error = '倍速设置失败，请重试');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      TextField(
        key: const Key('player-custom-rate'),
        controller: input,
        enabled: !busy,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        textInputAction: TextInputAction.done,
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          labelText: '自定义倍速',
          filled: true,
          fillColor: const Color(0xff25272d),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 18,
          ),
          floatingLabelBehavior: FloatingLabelBehavior.always,
          helperText: '0.25–4 倍，支持两位小数',
          suffixText: '×',
          errorText: error,
          labelStyle: const TextStyle(color: Colors.white70),
          helperStyle: const TextStyle(color: Colors.white60),
          suffixStyle: const TextStyle(color: Colors.white70),
          enabledBorder: const OutlineInputBorder(
            borderSide: BorderSide(color: Colors.white24),
          ),
          focusedBorder: const OutlineInputBorder(
            borderSide: BorderSide(color: playerAccent),
          ),
        ),
        onChanged: (_) {
          if (error != null) setState(() => error = null);
        },
        onSubmitted: (_) => apply(),
      ),
      const SizedBox(height: 12),
      FilledButton(
        key: const Key('player-apply-custom-rate'),
        onPressed: busy ? null : apply,
        style: FilledButton.styleFrom(
          backgroundColor: playerAccent,
          foregroundColor: const Color(0xff18191b),
        ),
        child: Text(busy ? '正在设置' : '应用倍速'),
      ),
    ],
  );
}
