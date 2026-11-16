#!/usr/bin/env bash
# Rebuilds test/artifacts/*.apk from sources written for this project (manifests and resources below),
# using only `aapt2` (Android SDK build-tools) and an android.jar platform file as link input.
# The APKs contain only: AndroidManifest.xml, resources.arsc and the XML resources defined here.
# No dex, no AndroidX / Flutter libraries, no third-party resources.
#
# Usage: ANDROID_JAR=/path/to/android.jar [AAPT2=/path/to/aapt2] test/tool/make_apk_fixtures.sh [out dir, default test/artifacts]
# Release variants additionally run `aapt2 optimize --shorten-resource-paths` (res/ paths become short names,
# as in shrunk release builds); debug variants keep the readable paths.
set -euo pipefail
AAPT2="${AAPT2:-aapt2}"; ANDROID_JAR="${ANDROID_JAR:?set ANDROID_JAR to an android.jar}"
OUT="$(mkdir -p "${1:-test/artifacts}" && cd "${1:-test/artifacts}" && pwd)"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
PKG=dev.acme.wfreal

layout() { printf '<?xml version="1.0" encoding="utf-8"?>\n<FrameLayout xmlns:android="http://schemas.android.com/apk/res/android"\n    android:layout_width="match_parent" android:layout_height="match_parent">\n    <TextView android:layout_width="wrap_content" android:layout_height="wrap_content" android:text="%s"/>\n</FrameLayout>\n' "$1"; }
provider() { # initialLayout (empty = omit)
  printf '<?xml version="1.0" encoding="utf-8"?>\n<appwidget-provider xmlns:android="http://schemas.android.com/apk/res/android"\n    android:minWidth="110dp" android:minHeight="40dp"%s/>\n' "${1:+ android:initialLayout=\"@layout/$1\"}"; }
receiver() { # name, provider xml name (empty = no meta-data)
  printf '        <receiver android:name="%s.%s" android:exported="true">\n            <intent-filter><action android:name="android.appwidget.action.APPWIDGET_UPDATE"/></intent-filter>\n' "$PKG" "$1"
  [ -n "$2" ] && printf '            <meta-data android:name="android.appwidget.provider" android:resource="@xml/%s"/>\n' "$2"
  printf '        </receiver>\n'; }
manifest() { # receivers text
  printf '<?xml version="1.0" encoding="utf-8"?>\n<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="%s">\n    <application android:label="wfreal">\n        <activity android:name="%s.MainActivity" android:exported="true">\n            <intent-filter><action android:name="android.intent.action.MAIN"/><category android:name="android.intent.category.LAUNCHER"/></intent-filter>\n        </activity>\n%s    </application>\n</manifest>\n' "$PKG" "$PKG" "$1"; }

# name | shorten(1/0) | receivers: "Class:providerXml" separated by space | resources: "xml:Name:layout" and "layout:Name"
build() { # name shorten "receivers" "xml specs" "layouts"
  local name=$1 shorten=$2 recv=$3 xmls=$4 layouts=$5 d="$W/$1"; mkdir -p "$d/res/xml" "$d/res/layout"
  local rtext=""; for r in $recv; do rtext+="$(receiver "${r%%:*}" "${r#*:}")"$'\n'; done
  manifest "$rtext" > "$d/AndroidManifest.xml"
  for x in $xmls; do provider "${x#*:}" > "$d/res/xml/${x%%:*}.xml"; done   # "<file>:<initialLayout or empty>"
  for l in $layouts; do layout "$l" > "$d/res/layout/$l.xml"; done
  "$AAPT2" compile --dir "$d/res" -o "$d/compiled.zip"
  "$AAPT2" link -I "$ANDROID_JAR" --manifest "$d/AndroidManifest.xml" --min-sdk-version 21 --target-sdk-version 35 -o "$d/base.apk" "$d/compiled.zip"
  if [ "$shorten" = 1 ]; then "$AAPT2" optimize --shorten-resource-paths -o "$OUT/$name.apk" "$d/base.apk"; else cp "$d/base.apk" "$OUT/$name.apk"; fi
}

# a release app with one widget
build real_release_widget 1 "DemoWidgetProvider:demo_widget_info" "demo_widget_info:demo_widget" "demo_widget"
# a debug app: Demo's provider XML lacks initialLayout (WF6004); OtherWidgetProvider has no provider meta-data (WF6002)
build real_debug_widget_missing_meta 0 "DemoWidgetProvider:demo_widget_info OtherWidgetProvider:" "demo_widget_info:" "demo_widget"
# release: two widgets; debug: the same two plus a receiver that exists only in the debug manifest
build real_release_multi_widget 1 "DemoWidgetProvider:demo_widget_info SecondWidgetProvider:second_widget_info" "demo_widget_info:demo_widget second_widget_info:second_widget" "demo_widget second_widget"
build real_debug_multi_widget 0 "DemoWidgetProvider:demo_widget_info SecondWidgetProvider:second_widget_info DebugOnlyProvider:demo_widget_info" "demo_widget_info:demo_widget second_widget_info:second_widget" "demo_widget second_widget"
# an app without any widget
build real_release_no_widget 1 "" "" "demo_widget"
ls -l "$OUT"/real_*.apk
