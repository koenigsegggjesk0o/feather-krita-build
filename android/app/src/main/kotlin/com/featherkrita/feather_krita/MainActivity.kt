package com.featherkrita.feather_krita

import io.flutter.embedding.android.FlutterActivity

class MainActivity: FlutterActivity() {
    companion object {
        init {
            // Load krita_bridge via System.loadLibrary so Android's ART
            // calls JNI_OnLoad, which captures the process JavaVM and
            // injects it into Qt's internal g_javaVm slot. Without this,
            // Flutter FFI's DynamicLibrary.open (dlopen) would load the
            // .so WITHOUT calling JNI_OnLoad, leaving g_javaVm null and
            // crashing every Qt/KF5 JNI path at runtime (fault 0x0 in
            // QJNIEnvironmentPrivate ctor, triggered by
            // krita_brush_set_size → KLocalizedString::toString()).
            // Must run BEFORE Flutter's FFI first touches the bridge:
            // companion init = Activity creation, which precedes the
            // Flutter engine's Dart-side DynamicLibrary.open call.
            System.loadLibrary("krita_bridge")
        }
    }
}
