// FkrSmoke — app_process boot class for the on-device real-engine smoke
// (loop-43; load-order redesign loop-44).
// app_process boots the ART VM, then this class loads libsmoke_jni.so,
// whose DT_NEEDED closure (bridge -> core shim -> real core -> extras ->
// KF5 -> quazip) is pulled in by PLAIN bionic dlopen — the linker never
// calls JNI_OnLoad for dependency loads, so no Qt library ever reaches
// the ART path that demands Qt's Java classes.
//
// WHY NOT System.load the real core first (loop-43 design): ART calls
// JNI_OnLoad on every top-level System.load. libQt5Core_real exports
// JNI_OnLoad, and it returns JNI_ERR in this environment (it registers
// natives on org.qtproject.qt5.android.QtNative — absent from a minimal
// dex). UnsatisfiedLinkError escapes main -> RuntimeInit's
// KillApplicationHandler runs Process.killProcess(myPid()) — the shell
// reports a bare "Killed" (exit 137) and the actual error is invisible.
// That masked the root cause for 18 bring-up runs until the unfiltered
// crash-buffer capture nailed it (run 35519554306:
// "UnsatisfiedLinkError: JNI_ERR returned from JNI_OnLoad in
// /data/local/tmp/fkr/libQt5Core_real_x86_64.so").
//
// The JNI-dependent statics that motivated VM-first loading were since
// shimmed at load level (AndroidExtras null-context masquerade, kcatalog
// + KisAndroidCrashHandler null-safe paths), so nothing in the closure
// requires Qt's registered VM global anymore.
//
// "bootcheck" mode (first arg): verifies the app_process/CLASSPATH boot
// itself, with NO native loads — isolates harness boot vs library-chain
// failures.
//
// main() never lets a Throwable escape: an uncaught exception in an
// app_process process self-SIGKILLs via KillApplicationHandler and the
// real error never reaches the captured stdout. All failures are
// printed to STDOUT (what adb shell tee captures), not stderr.
//
// Loaded from /data/local/tmp/fkr (see android-emulator-smoke.yml).
public class FkrSmoke {
    static boolean sLoaded = false;

    static void ensureLoaded() {
        if (sLoaded) return;
        // Single load: bionic resolves the whole engine closure from
        // libsmoke_jni.so's DT_NEEDED chain (see header). No Qt library
        // is ever loaded through ART's JNI_OnLoad path.
        System.out.println("load: smoke_jni (bridge chain, transitive)...");
        System.load("/data/local/tmp/fkr/libsmoke_jni.so");
        System.out.println("load: smoke_jni OK");
        sLoaded = true;
    }

    public static native int run(String[] args);

    public static void main(String[] args) {
        if (args.length > 0 && "bootcheck".equals(args[0])) {
            System.out.println("BOOTCHECK OK — app_process boot healthy");
            System.exit(0);
        }
        try {
            ensureLoaded();
            final int rc = run(args);
            System.out.println("fkr smoke rc=" + rc);
            System.exit(rc);
        } catch (Throwable t) {
            // readable failure instead of the masking self-SIGKILL
            System.out.println("FKR-FAIL: " + t);
            t.printStackTrace(System.out);
            System.exit(3);
        }
    }
}
