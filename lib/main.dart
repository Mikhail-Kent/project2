  // lib/main.dart
  // Smart Alarm - single-file working app entry (Flutter 3.x / Dart 3.x compatible)
  // Features (core): SleepDial UI, create/edit/delete alarms, Hive storage, local notifications (zoned), preview audio, simple snore recording.
  //
  // Required packages (see pubspec.yaml below):
  // hive_flutter, provider, flutter_local_notifications, timezone, flutter_native_timezone,
  // just_audio, record, permission_handler, path_provider
  //
  // IMPORTANT: Add sound files to assets/sounds/ and to android/app/src/main/res/raw/ (see instructions below).
  
  import 'dart:async';
  import 'dart:io';
  import 'package:flutter/material.dart';
  import 'package:flutter/services.dart';
  import 'package:hive_flutter/hive_flutter.dart';
  import 'package:path_provider/path_provider.dart';
  import 'package:provider/provider.dart';
  import 'package:flutter_local_notifications/flutter_local_notifications.dart';
  import 'package:timezone/data/latest_all.dart' as tz;
  import 'package:timezone/timezone.dart' as tz;
  import 'package:flutter_native_timezone/flutter_native_timezone.dart';
  import 'package:just_audio/just_audio.dart';
  import 'package:record/record.dart';
  import 'package:permission_handler/permission_handler.dart';
  
  /// -------------------- Models --------------------
  class Alarm {
    String id;
    DateTime time; // next occurrence time
    List<int> weekdays; // 1..7 = Mon..Sun (empty = one-time)
    String label;
    String soundAsset; // asset path, e.g. assets/sounds/wake_tone_default.mp3
    bool enabled;
  
    Alarm({
      required this.id,
      required this.time,
      required this.weekdays,
      required this.label,
      required this.soundAsset,
      required this.enabled,
    });
  
    Map<String, dynamic> toMap() => {
      'id': id,
      'time': time.millisecondsSinceEpoch,
      'weekdays': weekdays,
      'label': label,
      'soundAsset': soundAsset,
      'enabled': enabled,
    };
  
    factory Alarm.fromMap(Map m) {
      final id = (m['id'] ?? '') as String;
      final ms = (m['time'] ?? DateTime.now().millisecondsSinceEpoch) as int;
      final weekdaysRaw = m['weekdays'];
      final weekdays = (weekdaysRaw is List) ? List<int>.from(weekdaysRaw) : <int>[];
      return Alarm(
        id: id,
        time: DateTime.fromMillisecondsSinceEpoch(ms),
        weekdays: weekdays,
        label: (m['label'] ?? '') as String,
        soundAsset: (m['soundAsset'] ?? 'assets/sounds/wake_tone_default.mp3') as String,
        enabled: (m['enabled'] ?? true) as bool,
      );
    }
  }
  
  /// -------------------- Services --------------------
  /// NotificationService: wraps flutter_local_notifications and timezone initialization.
  class NotificationService {
    static final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  
    static Future<void> init() async {
      const android = AndroidInitializationSettings('@mipmap/ic_launcher');
      const iOS = DarwinInitializationSettings();
  
      await _plugin.initialize(
        const InitializationSettings(android: android, iOS: iOS),
        onDidReceiveNotificationResponse: (NotificationResponse response) {
          // handle taps - for demo we only log
          debugPrint('Notification tapped: ${response.payload}');
        },
      );
  
      // timezone initialization (use flutter_native_timezone)
      tz.initializeTimeZones();
      try {
        final String tzName = await FlutterNativeTimezone.getLocalTimezone();
        tz.setLocalLocation(tz.getLocation(tzName));
        debugPrint('Timezone set to $tzName');
      } catch (e) {
        debugPrint('Failed to set timezone: $e');
      }
    }
  
    static AndroidNotificationDetails _androidDetails({String? soundResource}) {
      final sound = soundResource != null ? RawResourceAndroidNotificationSound(soundResource) : null;
      return AndroidNotificationDetails(
        'alarm_channel',
        'Alarms',
        channelDescription: 'Alarm notifications',
        importance: Importance.max,
        priority: Priority.high,
        playSound: sound != null,
        sound: sound,
        fullScreenIntent: true,
        // set visibility and other flags as needed
      );
    }
  
    static DarwinNotificationDetails _iosDetails({String? soundFile}) {
      return DarwinNotificationDetails(presentSound: soundFile != null, sound: soundFile);
    }
  
    static NotificationDetails platformDetails({String? androidSoundResource, String? iosSoundFile}) {
      return NotificationDetails(
        android: _androidDetails(soundResource: androidSoundResource),
        iOS: _iosDetails(soundFile: iosSoundFile),
      );
    }
  
    static Future<void> scheduleAlarm(Alarm alarm) async {
      if (!alarm.enabled) return;
      final scheduleDate = tz.TZDateTime.from(alarm.time, tz.local);
  
      String? androidSoundName;
      String? iosSoundFile;
      if (alarm.soundAsset.isNotEmpty) {
        final base = alarm.soundAsset.split('/').last;
        androidSoundName = base.split('.').first; // resource name without extension
        iosSoundFile = base; // include extension for iOS bundle
      }
  
      await _plugin.zonedSchedule(
        alarm.id.hashCode,
        alarm.label.isEmpty ? 'Smart Alarm' : alarm.label,
        'Time to wake up',
        scheduleDate,
        platformDetails(androidSoundResource: androidSoundName, iosSoundFile: iosSoundFile),
        androidAllowWhileIdle: true,
        uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
        matchDateTimeComponents: alarm.weekdays.isEmpty ? null : DateTimeComponents.dayOfWeekAndTime,
        payload: alarm.id,
      );
      debugPrint('Scheduled alarm ${alarm.id} at $scheduleDate (tz=${tz.local.name})');
    }
  
    static Future<void> cancelAlarm(Alarm alarm) async {
      await _plugin.cancel(alarm.id.hashCode);
      debugPrint('Cancelled alarm ${alarm.id}');
    }
  }
  
  /// StorageService: simple wrapper around Hive box storing Map<String,dynamic>
  class StorageService {
    static const String boxName = 'alarms_box';
  
    static Future<void> init() async {
      await Hive.initFlutter();
      await Hive.openBox(boxName);
    }
  
    static Box get box => Hive.box(boxName);
  
    static Future<List<Alarm>> loadAlarms() async {
      final box = Hive.box(boxName);
      try {
        final list = box.values.map((e) {
          if (e is Map) {
            return Alarm.fromMap(Map<String, dynamic>.from(e));
          } else if (e is Map<String, dynamic>) {
            return Alarm.fromMap(e);
          } else {
            // attempt to decode from dynamic
            return Alarm.fromMap(Map<String, dynamic>.from(e));
          }
        }).toList();
        return List<Alarm>.from(list);
      } catch (e) {
        debugPrint('Error reading alarms: $e');
        return [];
      }
    }
  
    static Future<void> saveAlarm(Alarm a) async {
      await box.put(a.id, a.toMap());
    }
  
    static Future<void> deleteAlarm(Alarm a) async {
      await box.delete(a.id);
    }
  }
  
  /// AudioService: just_audio wrapper for preview/playback
  class AudioService {
    final AudioPlayer _player = AudioPlayer();
  
    Future<void> playFromAsset(String assetPath) async {
      try {
        await _player.setAsset(assetPath);
        await _player.play();
      } catch (e) {
        debugPrint('Audio play error: $e');
      }
    }
  
    Future<void> stop() async {
      try {
        await _player.stop();
      } catch (e) {
        debugPrint('Audio stop error: $e');
      }
    }
  
    void dispose() {
      try {
        _player.dispose();
      } catch (_) {}
    }
  }
  
  /// RecorderService: record plugin wrapper
  class RecorderService {
    final Record _rec = Record();
  
    Future<bool> hasPermission() async {
      final status = await Permission.microphone.status;
      if (!status.isGranted) {
        final res = await Permission.microphone.request();
        return res.isGranted;
      }
      return true;
    }
  
    Future<String?> startRecording(String filename) async {
      if (!await hasPermission()) return null;
      final dir = await getApplicationDocumentsDirectory();
      final path = '${dir.path}/$filename.m4a';
      try {
        await _rec.start(path: path, encoder: AudioEncoder.AAC);
        return path;
      } catch (e) {
        debugPrint('Start recording error: $e');
        return null;
      }
    }
  
    Future<String?> stopRecording() async {
      try {
        if (await _rec.isRecording()) return await _rec.stop();
      } catch (e) {
        debugPrint('Stop recording error: $e');
      }
      return null;
    }
  }
  
  /// -------------------- Providers --------------------
  class AlarmProvider extends ChangeNotifier {
    List<Alarm> alarms = [];
  
    AlarmProvider() {
      _load();
    }
  
    Future<void> _load() async {
      alarms = await StorageService.loadAlarms();
      // schedule enabled alarms
      for (final a in alarms) {
        if (a.enabled) {
          await NotificationService.scheduleAlarm(a);
        }
      }
      notifyListeners();
    }
  
    Future<void> addOrUpdate(Alarm a) async {
      await StorageService.saveAlarm(a);
      await NotificationService.cancelAlarm(a);
      if (a.enabled) await NotificationService.scheduleAlarm(a);
      await _load();
    }
  
    Future<void> remove(Alarm a) async {
      await NotificationService.cancelAlarm(a);
      await StorageService.deleteAlarm(a);
      await _load();
    }
  
    Future<void> toggleEnabled(Alarm a) async {
      a.enabled = !a.enabled;
      await addOrUpdate(a);
    }
  }
  
  /// -------------------- UI --------------------
  final navigatorKey = GlobalKey<NavigatorState>();
  
  void main() async {
    WidgetsFlutterBinding.ensureInitialized();
    await StorageService.init();
    await NotificationService.init();
    runApp(const MyApp());
  }
  
  class MyApp extends StatelessWidget {
    const MyApp({super.key});
    @override
    Widget build(BuildContext context) {
      return ChangeNotifierProvider(
        create: (_) => AlarmProvider(),
        child: MaterialApp(
          navigatorKey: navigatorKey,
          debugShowCheckedModeBanner: false,
          title: 'Smart Alarm',
          theme: ThemeData(primarySwatch: Colors.indigo, useMaterial3: true),
          home: const HomeScreen(),
        ),
      );
    }
  }
  
  class HomeScreen extends StatefulWidget {
    const HomeScreen({super.key});
    @override
    State<HomeScreen> createState() => _HomeScreenState();
  }
  
  class _HomeScreenState extends State<HomeScreen> {
    final audioService = AudioService();
    final recorder = RecorderService();
  
    @override
    void dispose() {
      audioService.dispose();
      super.dispose();
    }
  
    String fmtTime(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  
    @override
    Widget build(BuildContext context) {
      final prov = Provider.of<AlarmProvider>(context);
      return Scaffold(
        appBar: AppBar(
          title: const Text('Smart Alarm'),
          actions: [
            IconButton(
              icon: const Icon(Icons.mic),
              onPressed: () async {
                final ok = await recorder.hasPermission();
                if (!ok) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Microphone permission required')));
                  return;
                }
                final start = await recorder.startRecording('snore_test_${DateTime.now().millisecondsSinceEpoch}');
                if (start == null) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to start recording')));
                  return;
                }
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Recording started (10s)')));
                await Future.delayed(const Duration(seconds: 10));
                final file = await recorder.stopRecording();
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Saved: $file')));
              },
            )
          ],
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: SleepDial(
                onChanged: (sleep, wake) {
                  // optional: show hint
                },
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: prov.alarms.length,
                itemBuilder: (context, idx) {
                  final a = prov.alarms[idx];
                  return ListTile(
                    leading: const Icon(Icons.alarm),
                    title: Text(a.label.isEmpty ? fmtTime(a.time) : '${fmtTime(a.time)} — ${a.label}'),
                    subtitle: Text(a.weekdays.isEmpty ? 'One-time' : 'Repeats: ${_weekdaysToString(a.weekdays)}'),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      Switch(
                        value: a.enabled,
                        onChanged: (_) async {
                          await prov.toggleEnabled(a);
                        },
                      ),
                      PopupMenuButton<String>(
                        onSelected: (v) async {
                          if (v == 'edit') {
                            await Navigator.push(context, MaterialPageRoute(builder: (_) => EditAlarmScreen(existing: a)));
                          } else if (v == 'delete') {
                            await prov.remove(a);
                          } else if (v == 'play') {
                            await audioService.playFromAsset(a.soundAsset);
                          }
                        },
                        itemBuilder: (ctx) => const [
                          PopupMenuItem(value: 'play', child: Text('Play')),
                          PopupMenuItem(value: 'edit', child: Text('Edit')),
                          PopupMenuItem(value: 'delete', child: Text('Delete')),
                        ],
                      ),
                    ]),
                  );
                },
              ),
            )
          ],
        ),
        floatingActionButton: FloatingActionButton(
          onPressed: () async {
            await Navigator.push(context, MaterialPageRoute(builder: (_) => const EditAlarmScreen()));
          },
          child: const Icon(Icons.add),
        ),
      );
    }
  
    static String _weekdaysToString(List<int> days) {
      if (days.isEmpty) return 'One-time';
      const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      return days.map((d) => names[d - 1]).join(', ');
    }
  }
  
  /// SleepDial widget (simplified interactive)
  class SleepDial extends StatefulWidget {
    final void Function(TimeOfDay sleep, TimeOfDay wake)? onChanged;
    const SleepDial({this.onChanged, super.key});
  
    @override
    State<SleepDial> createState() => _SleepDialState();
  }
  
  class _SleepDialState extends State<SleepDial> {
    TimeOfDay sleep = const TimeOfDay(hour: 23, minute: 0);
    TimeOfDay wake = const TimeOfDay(hour: 7, minute: 0);
  
    @override
    Widget build(BuildContext context) {
      // Use safe dummy valid date
      final sleepDt = DateTime(2000, 1, 1, sleep.hour, sleep.minute);
      final wakeDt = DateTime(2000, 1, 1, wake.hour, wake.minute);
      Duration diff = wakeDt.difference(sleepDt);
      if (diff.isNegative) diff += const Duration(days: 1);
      final hours = diff.inMinutes / 60.0;
  
      return Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
          child: Column(
            children: [
              Text('Sleep — Wake', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    width: 220,
                    height: 220,
                    child: CustomPaint(painter: _DialPainter(progress: (hours / 12).clamp(0.0, 1.0))),
                  ),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Sleep: ${sleep.format(context)}', style: const TextStyle(fontSize: 16)),
                      Text('Wake: ${wake.format(context)}', style: const TextStyle(fontSize: 16)),
                      const SizedBox(height: 8),
                      Text('${hours.toStringAsFixed(1)} hrs', style: const TextStyle(fontSize: 14)),
                      const SizedBox(height: 12),
                      ElevatedButton(
                          onPressed: () async {
                            final t = await showTimePicker(context: context, initialTime: sleep);
                            if (t != null) setState(() => sleep = t);
                            widget.onChanged?.call(sleep, wake);
                          },
                          child: const Text('Set Sleep')),
                      const SizedBox(height: 6),
                      ElevatedButton(
                          onPressed: () async {
                            final t = await showTimePicker(context: context, initialTime: wake);
                            if (t != null) setState(() => wake = t);
                            widget.onChanged?.call(sleep, wake);
                          },
                          child: const Text('Set Wake')),
                    ],
                  )
                ],
              )
            ],
          ),
        ),
      );
    }
  }
  
  class _DialPainter extends CustomPainter {
    final double progress;
    _DialPainter({required this.progress});
    @override
    void paint(Canvas canvas, Size size) {
      final r = size.width / 2;
      final center = Offset(r, r);
      final bg = Paint()
        ..color = Colors.grey.shade300
        ..style = PaintingStyle.stroke
        ..strokeWidth = 18;
      final fg = Paint()
        ..color = Colors.indigo
        ..style = PaintingStyle.stroke
        ..strokeWidth = 18
        ..strokeCap = StrokeCap.round;
      canvas.drawCircle(center, r - 10, bg);
      final sweep = 2 * 3.1415926535 * progress;
      canvas.drawArc(Rect.fromCircle(center: center, radius: r - 10), -3.1415926535 / 2, sweep, false, fg);
    }
  
    @override
    bool shouldRepaint(covariant _DialPainter old) => old.progress != progress;
  }
  
  /// EditAlarmScreen: create / edit alarms
  class EditAlarmScreen extends StatefulWidget {
    final Alarm? existing;
    const EditAlarmScreen({this.existing, super.key});
  
    @override
    State<EditAlarmScreen> createState() => _EditAlarmScreenState();
  }
  
  class _EditAlarmScreenState extends State<EditAlarmScreen> {
    late TimeOfDay selected = TimeOfDay.now();
    final labelCtrl = TextEditingController();
    List<int> weekdays = [];
    String sound = 'assets/sounds/wake_tone_default.mp3';
    final AudioService _previewAudio = AudioService();
  
    static const List<Map<String, String>> soundOptions = [
      {'name': 'Default', 'asset': 'assets/sounds/wake_tone_default.mp3'},
      {'name': 'Digital', 'asset': 'assets/sounds/digital_alarm.mp3'},
      {'name': 'Soft Bell', 'asset': 'assets/sounds/soft_bell.mp3'},
    ];
  
    @override
    void initState() {
      super.initState();
      if (widget.existing != null) {
        final e = widget.existing!;
        selected = TimeOfDay(hour: e.time.hour, minute: e.time.minute);
        labelCtrl.text = e.label;
        weekdays = List<int>.from(e.weekdays);
        sound = e.soundAsset;
      } else {
        selected = TimeOfDay.now();
      }
    }
  
    @override
    void dispose() {
      labelCtrl.dispose();
      _previewAudio.dispose();
      super.dispose();
    }
  
    Future<DateTime> _nextOccurrenceForTime(TimeOfDay t, List<int> weekdaysList) async {
      final now = DateTime.now();
      DateTime candidate = DateTime(now.year, now.month, now.day, t.hour, t.minute);
      if (weekdaysList.isEmpty) {
        if (candidate.isBefore(now)) candidate = candidate.add(const Duration(days: 1));
        return candidate;
      } else {
        for (int offset = 0; offset <= 7; offset++) {
          final d = candidate.add(Duration(days: offset));
          if (weekdaysList.contains(d.weekday)) {
            if (offset == 0 && d.isBefore(now)) continue;
            return DateTime(d.year, d.month, d.day, t.hour, t.minute);
          }
        }
        return candidate.add(const Duration(days: 1));
      }
    }
  
    String _weekdaysLabel() {
      if (weekdays.isEmpty) return 'One-time';
      const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      return weekdays.map((d) => names[d - 1]).join(', ');
    }
  
    @override
    Widget build(BuildContext context) {
      final prov = Provider.of<AlarmProvider>(context, listen: false);
      return Scaffold(
        appBar: AppBar(
          title: Text(widget.existing == null ? 'New Alarm' : 'Edit Alarm'),
          actions: widget.existing != null
              ? [
            IconButton(
              icon: const Icon(Icons.delete),
              onPressed: () async {
                final e = widget.existing!;
                await prov.remove(e);
                if (mounted) Navigator.of(context).pop();
              },
            )
          ]
              : null,
        ),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.access_time),
                title: const Text('Time'),
                subtitle: Text(selected.format(context)),
                onTap: () async {
                  final t = await showTimePicker(context: context, initialTime: selected);
                  if (t != null) setState(() => selected = t);
                },
              ),
              const SizedBox(height: 8),
              TextField(
                controller: labelCtrl,
                decoration: const InputDecoration(labelText: 'Label (optional)'),
              ),
              const SizedBox(height: 12),
              Align(alignment: Alignment.centerLeft, child: Text('Repeat', style: Theme.of(context).textTheme.titleMedium)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: List.generate(7, (i) {
                  final day = i + 1;
                  final names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
                  final selectedFlag = weekdays.contains(day);
                  return ChoiceChip(
                    label: Text(names[i]),
                    selected: selectedFlag,
                    onSelected: (v) {
                      setState(() {
                        if (v) {
                          weekdays.add(day);
                        } else {
                          weekdays.remove(day);
                        }
                      });
                    },
                  );
                }),
              ),
              const SizedBox(height: 12),
              ListTile(
                leading: const Icon(Icons.music_note),
                title: const Text('Sound'),
                subtitle: Text(sound.split('/').last),
                trailing: ElevatedButton(
                  child: const Text('Preview'),
                  onPressed: () async {
                    await _previewAudio.playFromAsset(sound);
                    Future.delayed(const Duration(seconds: 6), () async {
                      await _previewAudio.stop();
                    });
                  },
                ),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: sound,
                items: soundOptions
                    .map((m) => DropdownMenuItem(value: m['asset'], child: Text(m['name'] ?? 'sound')))
                    .toList(),
                onChanged: (v) {
                  if (v != null) setState(() => sound = v);
                },
                decoration: const InputDecoration(labelText: 'Choose sound'),
              ),
              const SizedBox(height: 16),
              Align(alignment: Alignment.centerLeft, child: Text('Summary: ${_weekdaysLabel()}', style: const TextStyle(fontStyle: FontStyle.italic))),
              const Spacer(),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      child: const Text('Cancel'),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      child: Text(widget.existing == null ? 'Create' : 'Save'),
                      onPressed: () async {
                        final next = await _nextOccurrenceForTime(selected, weekdays);
                        final id = widget.existing?.id ?? DateTime.now().millisecondsSinceEpoch.toString();
                        final newAlarm = Alarm(id: id, time: next, weekdays: List<int>.from(weekdays), label: labelCtrl.text.trim(), soundAsset: sound, enabled: true);
                        await prov.addOrUpdate(newAlarm);
                        // ensure scheduled
                        await NotificationService.cancelAlarm(newAlarm);
                        if (newAlarm.enabled) await NotificationService.scheduleAlarm(newAlarm);
                        if (mounted) Navigator.of(context).pop();
                      },
                    ),
                  )
                ],
              )
            ],
          ),
        ),
      );
    }
  }
