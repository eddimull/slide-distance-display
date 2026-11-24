/// When something happened, as the app says it: "Today 14:05",
/// "Yesterday 19:20", "Nov 21" (this year), "Nov 21, 2025".
String friendlyWhen(DateTime t, {DateTime? now}) {
  final n = now ?? DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  final time = '${two(t.hour)}:${two(t.minute)}';
  final day = DateTime(t.year, t.month, t.day);
  final today = DateTime(n.year, n.month, n.day);
  final days = today.difference(day).inDays;
  if (days == 0) return 'Today $time';
  if (days == 1) return 'Yesterday $time';
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final date = '${months[t.month - 1]} ${t.day}';
  return t.year == n.year ? date : '$date, ${t.year}';
}
