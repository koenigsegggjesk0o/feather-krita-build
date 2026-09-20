// FkrSmoke — app_process boot class for the on-device real-engine smoke
// (loop-43). app_process boots the ART VM, then this class loads the
// engine chain in an order that registers the VM with Qt's android glue
// (JNI_OnLoad of the REAL core runs when ART loads it via System.load)
// and finally runs the C++ gate set through the JNI wrapper.
//
// Loaded from /data/local/tmp/fkr (see android-emulator-smoke.yml).
public class FkrSmoke {
    static {
        // 1. masquerade Core (1-symbol QStandardPaths shim, carries the
        //    libQt5Core_x86_64.so name every consumer NEEDs)
        System.load("/data/local/tmp/fkr/libQt5Core_x86_64.so");
        // 2. REAL core under its renamed soname — ART calls its
        //    JNI_OnLoad, which registers the JavaVM with Qt's android
        //    private glue (QJNIEnvironmentPrivate attach path)
        System.load("/data/local/tmp/fkr/libQt5Core_real_x86_64.so");
        // 3. AndroidExtras (QAndroidJniObject/Environment used by KF5I18n)
        System.load("/data/local/tmp/fkr/libQt5AndroidExtras_x86_64.so");
        // 4. the JNI smoke (pulls the real bridge + engine closure)
        System.load("/data/local/tmp/fkr/libsmoke_jni.so");
    }

    public static native int run(String[] args);

    public static void main(String[] args) {
        final int rc = run(args);
        System.out.println("fkr smoke rc=" + rc);
        System.exit(rc);
    }
}
