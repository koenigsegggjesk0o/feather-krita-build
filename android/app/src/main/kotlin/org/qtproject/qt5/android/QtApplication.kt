package org.qtproject.qt5.android

/**
 * Stub QtApplication class.
 *
 * Qt5Core's JNI_OnLoad (in the merged engine) may call FindClass for
 * "org/qtproject/qt5/android/QtApplication". Same rationale as QtNative:
 * a no-op stub so JNI_OnLoad succeeds. The real QtApplication in a Qt
 * Android app registers activity lifecycle callbacks; this Flutter app
 * uses FlutterActivity's lifecycle, so the stub is sufficient.
 */
class QtApplication
