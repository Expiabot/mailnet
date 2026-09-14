# enough_mail is pure Dart, but flutter_secure_storage and url_launcher reach
# into platform classes that R8 cannot see being used.
-keep class androidx.security.crypto.** { *; }
-dontwarn androidx.security.crypto.**
