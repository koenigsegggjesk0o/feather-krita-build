package org.qtproject.qt5.android

/**
 * Stub QtNative class.
 *
 * Qt5Core's JNI_OnLoad (in the merged engine) calls FindClass for
 * "org/qtproject/qt5/android/QtNative". Without this class, FindClass
 * returns null, JNI_OnLoad returns JNI_ERR, and System.loadLibrary
 * throws UnsatisfiedLinkError — crashing the app at Activity creation.
 *
 * In a real Qt Android app, QtNative handles the Qt lifecycle (surface
 * creation, input events, etc.). This Flutter app manages its own
 * lifecycle via FlutterActivity, so QtNative is a no-op stub: its only
 * purpose is to make FindClass succeed so JNI_OnLoad completes
 * successfully and calls QtAndroidPrivate::setJavaVM(vm), which sets
 * Qt's internal g_javaVm pointer. Once g_javaVm is set, every
 * QJNIEnvironmentPrivate path works at runtime, eliminating the
 * fault 0x0 crash in the krita_brush_set_size → KLocalizedString::toString()
 * → QJNIEnvironmentPrivate chain.
 *
 * Qt5Core's JNI_OnLoad also calls RegisterNatives on this class to
 * register C++ callback methods. Those methods will never be invoked
 * (the Qt Android bootstrap never runs in a Flutter app), so the
 * registrations are harmless no-ops.
 */
class QtNative
