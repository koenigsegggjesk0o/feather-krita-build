// FkrSmoke — app_process boot class for the on-device real-engine smoke
// (loop-43). app_process boots the ART VM, then this class loads the
// engine chain in an order that registers the VM with Qt's android glue
// (JNI_OnLoad of the REAL core runs when ART loads it via System.load)
// and finally runs the C++ gate set through the JNI wrapper.
//
// "bootcheck" mode (first arg): verifies the app_process/CLASSPATH boot
// itself, with NO native loads — isolates harness boot vs library-chain
// failures (run 35515046839: instant SIGKILL, cause unidentified).
//
// Loaded from /data/local/tmp/fkr (see android-emulator-smoke.yml).
public class FkrSmoke {
    static boolean sLoaded = false;

    static void ensureLoaded() {
        if (sLoaded) return;
        // 1. REAL core FIRST, explicitly: its JNI_OnLoad (called by ART on
        //    top-level System.load) registers the JavaVM with Qt's android
        //    glue. If it loaded transitively (via the shim's DT_NEEDED)
        //    the explicit load below would be a no-op and JNI_OnLoad would
        //    never run -> VM never registered (run 35514055979).
        System.out.println("load: real core...");
        System.load("/data/local/tmp/fkr/libQt5Core_real_x86_64.so");
        System.out.println("load: real core OK");
        // 2. masquerade Core (1-symbol QStandardPaths shim carrying the
        //    libQt5Core_x86_64.so name every consumer NEEDs); the real
        //    core is already in the solist, so its NEEDED is satisfied
        System.out.println("load: core shim...");
        System.load("/data/local/tmp/fkr/libQt5Core_x86_64.so");
        System.out.println("load: core shim OK");
        // 3. AndroidExtras (QAndroidJniObject/Environment used by KF5I18n)
        System.out.println("load: androidextras shim...");
        System.load("/data/local/tmp/fkr/libQt5AndroidExtras_x86_64.so");
        System.out.println("load: androidextras shim OK");
        // 4. the JNI smoke (pulls the real bridge + engine closure)
        System.out.println("load: smoke_jni (bridge chain)...");
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
        ensureLoaded();
        final int rc = run(args);
        System.out.println("fkr smoke rc=" + rc);
        System.exit(rc);
    }
}
