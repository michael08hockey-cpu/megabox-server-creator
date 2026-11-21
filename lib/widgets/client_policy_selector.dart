import 'package:flutter/material.dart';

/// Traffic is stored in bytes; expiry is an absolute Unix timestamp in ms.
class ClientPolicy {
  static const bytesPerGb = 1073741824;
  final int? hours;
  final int trafficGb;
  const ClientPolicy({this.hours, this.trafficGb = 0});

  int get totalBytes {
    if (trafficGb < 0 || trafficGb > 1000000) {
      throw ArgumentError('Traffic must be between 0 and 1000000 GB');
    }
    return trafficGb * bytesPerGb;
  }

  int expiryAt(DateTime now) {
    if (hours == null) return 0;
    if (hours! <= 0) throw ArgumentError('Expiry must be positive');
    return now.add(Duration(hours: hours!)).millisecondsSinceEpoch;
  }
}

class ClientPolicySelector extends StatelessWidget {
  final ClientPolicy value;
  final ValueChanged<ClientPolicy> onChanged;
  const ClientPolicySelector({
    super.key,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      DropdownButtonFormField<int>(
        isExpanded: true,
        initialValue: value.hours ?? 0,
        decoration: const InputDecoration(labelText: 'Срок действия клиента'),
        items: const [
          DropdownMenuItem(value: 0, child: Text('Навсегда / Бессрочно')),
          DropdownMenuItem(value: 720, child: Text('На 30 дней')),
        ],
        onChanged: (hours) => onChanged(
          ClientPolicy(
            hours: hours == 0 ? null : hours,
            trafficGb: value.trafficGb,
          ),
        ),
      ),
      const SizedBox(height: 12),
      DropdownButtonFormField<int>(
        isExpanded: true,
        initialValue: value.trafficGb == 0 ? 0 : 1,
        decoration: const InputDecoration(labelText: 'Лимит трафика клиента'),
        items: const [
          DropdownMenuItem(value: 0, child: Text('Без лимита')),
          DropdownMenuItem(value: 1, child: Text('Заданный объём (ГБ)')),
        ],
        onChanged: (limited) => onChanged(
          ClientPolicy(hours: value.hours, trafficGb: limited == 0 ? 0 : 30),
        ),
      ),
      if (value.trafficGb != 0) ...[
        const SizedBox(height: 12),
        TextFormField(
          initialValue: '${value.trafficGb}',
          decoration: const InputDecoration(labelText: 'Объём трафика (ГБ)'),
          keyboardType: TextInputType.number,
          validator: (text) {
            final gb = int.tryParse(text ?? '');
            return gb == null || gb <= 0 || gb > 1000000
                ? 'Введите от 1 до 1000000 ГБ'
                : null;
          },
          onChanged: (text) {
            final gb = int.tryParse(text);
            if (gb != null && gb > 0 && gb <= 1000000) {
              onChanged(ClientPolicy(hours: value.hours, trafficGb: gb));
            }
          },
        ),
      ],
    ],
  );
}
