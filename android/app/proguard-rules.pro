# Shizuku starts the carrier reader from inside the shell process:
# `moe.shizuku.starter.ServiceStarter` reads the class name the app passed in
# UserServiceArgs and instantiates it with Class.newInstance(). R8 may neither
# rename that class nor strip its no-argument constructor, or the start fails
# with `InstantiationException: Class<kh> cannot be instantiated` and Settings
# sits on "starting" until Shizuku's 30 s start timeout gives up.
-keep class com.celltower.cell_tower_monitor.PrivilegedRadioService { *; }
-keep interface com.celltower.cell_tower_monitor.IPrivilegedRadio { *; }
-keep class com.celltower.cell_tower_monitor.IPrivilegedRadio$Stub { *; }
