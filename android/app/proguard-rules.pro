-keep class com.umeng.** { *; }
-keep class org.repackage.** { *; }
-keepclassmembers class * {
    public <init>(org.json.JSONObject);
}
-keepclassmembers enum * {
    public static **[] values();
    public static ** valueOf(java.lang.String);
}
-keep public class com.asterlink.app.R$* {
    public static final int *;
}
