import 'package:flutter/widgets.dart';
import 'package:home_widget/home_widget.dart';

Future<void> main() async {
  await HomeWidget.setAppGroupId('group.com.example.demo');
  runApp(const Placeholder());
}
