package com.featherkrita.feather_krita

import io.flutter.embedding.android.FlutterActivity

class MainActivity: FlutterActivity() {
    companion object {
        init {
            // Load krita_bridge via System.loadLibrary so Android's ART
            // calls JNI_OnLoad, which (in the merged engine) is Qt5Core's
            // version. Qt5Core's JNI_OnLoad calls QtAndroidPrivate::setJavaVM(vm)
            // which sets Qt's internal g_javaVm pointer — the critical step
            // that makes every QJNIEnvironmentPrivate path work at runtime.
            //
            // Without this, Flutter FFI's DynamicLibrary.open (dlopen) would
            // load the .so WITHOUT calling JNI_OnLoad, leaving g_javaVm null
            // and crashing every Qt/KF5 JNI path at runtime (fault 0x0 in
            // QJNIEnvironmentPrivate ctor, triggered by
            // krita_brush_set_size -> KLocalizedString::toString()).
            //
            // Stub Qt Java classes (QtNative, QtApplication) are provided in
            // org.qtproject.qt5.android so Qt5Core's JNI_OnLoad FindClass
            // calls succeed. The try-catch is a safety net: if JNI_OnLoad
            // still fails (e.g., missing class/method), the .so remains
            // loaded (dlopen succeeded) and FFI can still access it; the
            // app boots and we can iterate on the remaining issues.
            try {
                System.loadLibrary("krita_bridge")
            } catch (e: UnsatisfiedLinkError) {
                android.util.Log.w(
                    "krita_bridge",
                    "System.loadLibrary JNI_OnLoad failed: ${e.message}. " +
                    "The .so is still loaded (dlopen succeeded); FFI access unaffected."
                )
            }
        }
    }
}
