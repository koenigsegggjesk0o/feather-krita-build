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
#include <dlfcn.h>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

extern "C" int smoke_main(int argc, char** argv);

// Own-scope JNI_OnLoad: ART validates every System.load target with
// dlsym(handle, "JNI_OnLoad"), and bionic resolves a handle-dlsym
// against the object's OWN symbol scope first, then its dependency
// closure (BFS). Without this function the lookup walks through the
// bridge chain and lands on libQt5Core_real's JNI_OnLoad — which
// registers natives on Qt's Java classes (absent from a minimal dex)
// and returns JNI_ERR, failing the whole load as
// "JNI_ERR returned from JNI_OnLoad in libsmoke_jni.so" (run
// 35520875707). Returning the version from our own scope is
// deterministic: ART never reaches the core's hook, which is exactly
// what we want — the engine statics are shimmed VM-free and nothing in
// the smoke needs Qt's loader path.
extern "C" JNIEXPORT jint JNICALL
JNI_OnLoad(JavaVM* vm, void* /*reserved*/) {
    // The engine's i18n path (krita_brush_set_size -> i18n() -> KCatalog
    // -> QAndroidJniEnvironment) reads Qt's g_javaVm global through the
    // exported reader QtAndroidPrivate::javaVM() and derefs it WITHOUT a
    // null check — a null VM segfaults at fault addr 0x0 (run
    // 35521285894 backtrace: QJNIEnvironmentPrivate ctor +36). Qt's own
    // setter (setJavaVM) is hidden and only reachable through the
    // core's JNI_OnLoad, which we deliberately shield. The reader is a
    // two-instruction thunk (mov X(%rip),%rax; ret), so the global's
    // address is recoverable from the prologue and writable directly.
    // Pattern-verified; any mismatch logs and leaves the process to the
    // readable tombstone path instead of guessing.
    void* sym = dlsym(RTLD_DEFAULT, "_ZN16QtAndroidPrivate6javaVMEv");
    if (sym != nullptr) {
        unsigned char* p = static_cast<unsigned char*>(sym);
        unsigned char prologue[8] = {0x48, 0x8b, 0x05, 0, 0, 0, 0, 0xc3};
        bool match = true;
        for (int i = 0; i < 8; ++i) {
            if ((i == 3 || i == 4 || i == 5 || i == 6)) continue;
            if (p[i] != prologue[i]) { match = false; break; }
        }
        if (match) {
            int32_t disp = 0;
            std::memcpy(&disp, p + 3, 4);
            void** g_java_vm = reinterpret_cast<void**>(p + 7 + disp);
            *g_java_vm = vm;
            std::printf("vminject: g_javaVm set at %p\n", static_cast<void*>(g_java_vm));
        } else {
            std::printf("vminject: unexpected javaVM() prologue at %p — global write skipped\n", sym);
        }
    } else {
        std::printf("vminject: QtAndroidPrivate::javaVM not found — global write skipped\n");
    }
    return JNI_VERSION_1_6;
}

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
