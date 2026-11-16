import 'dart:io';

import 'package:xml/xml.dart';

import '../models.dart';
import '../project.dart';

const checkRemoteViews = 'remoteviews-supported-views';

/// Classes RemoteViews may inflate, as simple names in `android.widget`.
///
/// Source of truth: every class in android.jar (API 34, 35 and 36 compared)
/// annotated `@RemoteViews.RemoteView` -- 23 classes, identical on all three
/// levels. The RemoteViews reference documents 21 of them ("limited to the
/// following layouts / widgets", plus CheckBox, RadioButton, RadioGroup and
/// Switch "as of API 31"); it does not list AbsoluteLayout (deprecated since
/// API 3) although the framework annotation allows it. Allowed != recommended:
/// no diagnostic is emitted for AbsoluteLayout. Per-API-level availability of
/// the four API 31 compound buttons is NOT checked here (the layout's
/// resource qualifier is not interpreted).
const supportedWidgets = {
  // layouts
  'FrameLayout', 'LinearLayout', 'RelativeLayout', 'GridLayout', 'AbsoluteLayout',
  // widgets
  'AnalogClock', 'Button', 'Chronometer', 'ImageButton', 'ImageView',
  'ProgressBar', 'TextClock', 'TextView',
  // collections
  'AdapterViewFlipper', 'GridView', 'ListView', 'StackView', 'ViewFlipper',
  // API 31+ compound buttons
  'CheckBox', 'RadioButton', 'RadioGroup', 'Switch',
};

/// Tags handled by the layout inflater itself, not views. `requestFocus` and
/// `tag` are special tags of the platform LayoutInflater; that RemoteViews
/// accepts them was NOT verified on a device, so they are neither reported
/// nor treated as proof of anything. `ViewStub` is a RemoteView-annotated
/// class in android.view.
const inflaterTags = {'include', 'merge', 'requestFocus', 'tag'};

/// True when [tag] (as written in the layout) names an allowed class.
/// Dotless names are resolved like the platform inflater does (android.widget
/// first, then android.view); qualified names must be exactly allowed.
bool isSupportedViewTag(String tag) {
  if (!tag.contains('.')) return supportedWidgets.contains(tag) || tag == 'ViewStub';
  if (tag == 'android.view.ViewStub') return true;
  if (tag.startsWith('android.widget.')) {
    return supportedWidgets.contains(tag.substring('android.widget.'.length));
  }
  return false;
}

/// Replaces XML comments and CDATA by spaces (newlines kept) so that
/// element lookups cannot match text inside them.
String _blankComments(String text) => text.replaceAllMapped(
    RegExp(r'<!--.*?-->|<!\[CDATA\[.*?\]\]>', dotAll: true),
    (m) => m.group(0)!.replaceAll(RegExp(r'[^\n]'), ' '));

/// WF1001: layouts used by widgets may only contain RemoteViews-safe views.
/// Starts from layouts referenced by provider XML and follows `<include>`.
List<Diagnostic> checkRemoteViewsLayouts(AndroidProject p, List<String> roots) {
  final out = <Diagnostic>[];
  final seen = <String>{};
  final queue = [...roots];
  while (queue.isNotEmpty) {
    final name = queue.removeLast();
    if (!seen.add(name)) continue;
    for (final f in p.resolveResource('layout', name)) {
      out.addAll(_checkFile(p, f, queue));
    }
  }
  return out;
}

List<Diagnostic> _checkFile(AndroidProject p, File f, List<String> queue) {
  final text = f.readAsStringSync();
  XmlDocument doc;
  try {
    doc = XmlDocument.parse(text);
  } on XmlException catch (e) {
    return [
      Diagnostic(
        code: 'WF1001',
        severity: Severity.error,
        title: 'Widget layout is not well-formed XML',
        message: e.message,
        file: p.rel(f),
        line: null,
        evidence: e.message,
        fix: 'Fix the XML syntax error.',
      )
    ];
  }
  final out = <Diagnostic>[];
  final blanked = _blankComments(text);
  var cursor = 0;
  for (final el in doc.rootElement.descendantElements.toList()
    ..insert(0, doc.rootElement)) {
    final written = el.name.qualified;
    // locate this element's start tag after the previous one
    final found = RegExp('<${RegExp.escape(written)}(?=[\\s/>])').firstMatch(blanked.substring(cursor));
    final idx = found == null ? -1 : cursor + found.start;
    if (idx >= 0) cursor = idx + 1;
    final line = idx >= 0 ? '\n'.allMatches(text.substring(0, idx)).length + 1 : null;
    if (written == 'include') {
      final ref = parseResourceRef(el.getAttribute('layout'));
      if (ref != null && ref.type == 'layout') queue.add(ref.name);
      continue;
    }
    if (inflaterTags.contains(written)) continue;
    // `<view class="...">` names its class in an attribute.
    var tag = written;
    if (written == 'view') {
      final cls = el.getAttribute('class');
      if (cls == null) continue;
      tag = cls;
    }
    if (tag == 'ViewStub' || tag == 'android.view.ViewStub') {
      final ref = parseResourceRef(el.getAttribute('android:layout'));
      if (ref != null && ref.type == 'layout') queue.add(ref.name);
    }
    if (isSupportedViewTag(tag)) continue;
    out.add(Diagnostic(
      code: 'WF1001',
      severity: Severity.error,
      title: 'View not supported by RemoteViews',
      message:
          '<$written> is not one of the classes RemoteViews can inflate (documented list; '
          'android.jar @RemoteView annotations on API 34-36). Subclasses of supported views and custom views '
          'are not supported either. This check is static: it was not run on a device or emulator, '
          'and inflation success cannot be inferred from a successful build.',
      file: p.rel(f),
      line: line,
      evidence: written == 'view' ? '<view class="$tag"' : '<$written',
      fix: _fixFor(tag),
    ));
  }
  return out;
}

String _fixFor(String qualified) {
  final tag = qualified;
  const alt = {
    'ConstraintLayout': 'Replace with RelativeLayout, LinearLayout or FrameLayout.',
    'ScrollView': 'Replace with ListView/StackView backed by a RemoteViewsService, or remove scrolling.',
    'RecyclerView': 'Replace with ListView/GridView backed by a RemoteViewsService.',
    'EditText': 'Input is impossible in widgets; use TextView plus a PendingIntent that opens an Activity.',
    'CardView': 'Replace with FrameLayout and a shape drawable background (rounded corners via android:background).',
    'Space': 'Not annotated @RemoteView in android.jar; use margins/padding, or an empty FrameLayout with a fixed size.',
    'View': 'Not annotated @RemoteView in android.jar; use a FrameLayout with android:background (e.g. for a divider).',
    'WebView': 'Not allowed; render to an image in Dart and show it with ImageView.',
  };
  final key = tag.split('.').last;
  return alt[key] ??
      'Replace <$tag> with a supported view (FrameLayout, LinearLayout, RelativeLayout, GridLayout, TextView, ImageView, Button, ImageButton, ProgressBar, Chronometer, TextClock, AnalogClock, ListView, GridView, StackView, ViewFlipper, AdapterViewFlipper).';
}
