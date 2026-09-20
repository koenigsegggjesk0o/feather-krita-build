// SPDX-FileCopyrightText: 2026 Feather-Krita App Contributors
// SPDX-License-Identifier: GPL-2.0-or-later
//
// smoke_jni.cpp — JNI wrapper that runs the real-engine smoke gates
// INSIDE an Android process that has a JavaVM (app_process boot; loop-43).
//
// Why: Krita's (unmodified) android glue and KF5I18n run JNI-dependent
// static initializers at library-load time (KisAndroidCrashHandler's
// QStandardPaths path, kcatalog's QAndroidJniEnvironment). In a bare
// adb-shell executable there is no JVM, so those statics crash before
// main(). app_process boots ART; with the VM attached the same statics
// degrade gracefully (no Qt activity -> null contexts -> null-safe paths)
// and the engine gates run for real.
//
// Krita source is NEVER modified — this wrapper only re-enters the smoke.

#include <jni.h>
#include <cstdlib>
#include <cstring>

extern "C" int smoke_main(int argc, char** argv);

extern "C" JNIEXPORT jint JNICALL
Java_FkrSmoke_run(JNIEnv* env, jclass, jobjectArray args) {
    const jsize n = env->GetArrayLength(args);
    char** argv = static_cast<char**>(std::calloc(size_t(n) + 2, sizeof(char*)));
    if (!argv) return 2;
    argv[0] = const_cast<char*>("smoke_test_real_android");
    for (jsize i = 0; i < n; ++i) {
        jstring js = static_cast<jstring>(env->GetObjectArrayElement(args, i));
        const char* s = env->GetStringUTFChars(js, nullptr);
        argv[i + 1] = strdup(s ? s : "");
        if (s) env->ReleaseStringUTFChars(js, s);
        env->DeleteLocalRef(js);
    }
    const int rc = smoke_main(n + 1, argv);
    for (jsize i = 1; i <= n; ++i) std::free(argv[i]);
    std::free(argv);
    return rc;
}
