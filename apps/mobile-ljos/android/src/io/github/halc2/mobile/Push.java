package io.github.halc2.mobile;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.ActivityInfo;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.net.Uri;
import android.os.Build;
import android.provider.Settings;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.File;
import java.util.List;
import java.util.UUID;

// The phone's side of notifications that is Android's own (the app's is
// src/push/PushSystem.cpp): UnifiedPush's broadcasts to a distributor, and
// putting up what the push inbox (src/push/PushInbox.h) says to, from the
// app or from PushReceiver while the app may not be running.
public final class Push {
    static final int CARD_ID = 73001;
    static final String ACTIVITY = "org.qtproject.qt.android.bindings.QtActivity";
    private static final String PREFERENCES = "hal-c2-push";
    private static final String REGISTER = "org.unifiedpush.android.distributor.REGISTER";
    private static final String UNREGISTER = "org.unifiedpush.android.distributor.UNREGISTER";
    static final String MESSAGE_ACK = "org.unifiedpush.android.distributor.MESSAGE_ACK";

    private static boolean loaded;

    private Push() {}

    // The app's library, which has the inbox's JNI functions: already loaded
    // while the app runs, and loaded here for a receiver the system started.
    static synchronized void load(Context context) {
        if (loaded) return;
        String name = null;
        try {
            ActivityInfo info = context.getPackageManager()
                .getActivityInfo(new ComponentName(context, ACTIVITY), PackageManager.GET_META_DATA);
            if (info.metaData != null) name = info.metaData.getString("android.app.lib_name");
        } catch (PackageManager.NameNotFoundException ignored) {
        }
        if (name == null || name.isEmpty()) name = "hal-c2-mobile_" + Build.SUPPORTED_ABIS[0];
        System.loadLibrary(name);
        loaded = true;
    }

    // Where the app keeps its data (<AppDataLocation>/data), the inbox's file with it.
    static String dataDir(Context context) {
        return new File(context.getFilesDir(), "data").getAbsolutePath();
    }

    static SharedPreferences preferences(Context context) {
        return context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE);
    }

    public static boolean enabled(Context context) {
        return manager(context).areNotificationsEnabled();
    }

    public static void openSettings(Context context) {
        Intent intent = new Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
            .putExtra(Settings.EXTRA_APP_PACKAGE, context.getPackageName())
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        context.startActivity(intent);
    }

    public static void openLiveUpdateSettings(Context context) {
        if (Build.VERSION.SDK_INT < 36) {
            openSettings(context);
            return;
        }
        Intent intent = new Intent(Settings.ACTION_APP_NOTIFICATION_PROMOTION_SETTINGS)
            .putExtra(Settings.EXTRA_APP_PACKAGE, context.getPackageName())
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        try {
            context.startActivity(intent);
        } catch (RuntimeException e) {
            openSettings(context);
        }
    }

    // The distributors installed, "package\tlabel" a line.
    public static String distributors(Context context) {
        PackageManager packages = context.getPackageManager();
        List<ResolveInfo> found = packages.queryBroadcastReceivers(new Intent(REGISTER), PackageManager.GET_RESOLVED_FILTER);
        StringBuilder listed = new StringBuilder();
        for (ResolveInfo info : found) {
            String id = info.activityInfo.packageName;
            if (id.equals(context.getPackageName()) || listed.indexOf(id + "\t") >= 0) continue;
            CharSequence label = info.activityInfo.applicationInfo.loadLabel(packages);
            listed.append(id).append('\t').append(label).append('\n');
        }
        return listed.toString();
    }

    // Asks `distributor` for an endpoint, which comes to PushReceiver as
    // NEW_ENDPOINT. The token names this registration to both.
    public static void subscribe(Context context, String distributor) {
        SharedPreferences preferences = preferences(context);
        String token = preferences.getString("token", null);
        if (token == null || !distributor.equals(preferences.getString("distributor", null))) {
            token = UUID.randomUUID().toString();
        }
        preferences.edit().putString("token", token).putString("distributor", distributor).apply();
        Intent intent = new Intent(REGISTER)
            .setPackage(distributor)
            .putExtra("token", token)
            .putExtra("application", context.getPackageName())
            .putExtra("pi", PendingIntent.getBroadcast(context, 0, new Intent("org.unifiedpush.android.connector.PI"),
                PendingIntent.FLAG_IMMUTABLE));
        context.sendBroadcast(intent);
    }

    public static void unsubscribe(Context context) {
        SharedPreferences preferences = preferences(context);
        String token = preferences.getString("token", null);
        String distributor = preferences.getString("distributor", null);
        preferences.edit().remove("token").remove("distributor").apply();
        if (token == null || distributor == null) return;
        context.sendBroadcast(new Intent(UNREGISTER).setPackage(distributor).putExtra("token", token));
    }

    // Renders the inbox's effects (PushInbox.h names them).
    public static void show(Context context, String json) {
        try {
            JSONObject effects = new JSONObject(json);
            NotificationManager manager = manager(context);
            JSONArray channels = effects.optJSONArray("channels");
            for (int i = 0; channels != null && i < channels.length(); i++) {
                JSONObject channel = channels.getJSONObject(i);
                int importance = "high".equals(channel.optString("importance"))
                    ? NotificationManager.IMPORTANCE_HIGH : NotificationManager.IMPORTANCE_LOW;
                manager.createNotificationChannel(new NotificationChannel(channel.getString("id"), channel.getString("name"), importance));
            }
            if (effects.optBoolean("cancelCard")) manager.cancel(CARD_ID);
            JSONObject alert = effects.optJSONObject("alert");
            if (alert != null) manager.notify(alert.optString("tag"), alert.getInt("id"), alert(context, alert));
            JSONObject card = effects.optJSONObject("card");
            if (card != null) manager.notify(card.optInt("id", CARD_ID), card(context, card));
        } catch (Exception e) {
            android.util.Log.w("HalC2Push", "could not show a notification", e);
        }
    }

    private static Notification alert(Context context, JSONObject alert) {
        String channel = alert.optString("channel");
        Notification.Builder builder = new Notification.Builder(context, channel)
            .setSmallIcon(icon(context))
            .setContentTitle(alert.optString("title"))
            .setContentText(alert.optString("body"))
            .setStyle(new Notification.BigTextStyle().bigText(alert.optString("body")))
            .setAutoCancel(true)
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setPublicVersion(publicVersion(context, channel, alert));
        PendingIntent open = open(context, alert.optString("link"));
        if (open != null) builder.setContentIntent(open);
        return builder.build();
    }

    // A string field, "" when it is missing or null (optString says "null").
    private static String string(JSONObject object, String key) {
        return object.isNull(key) ? "" : object.optString(key);
    }

    private static Notification card(Context context, JSONObject card) {
        String channel = card.optString("channel");
        StringBuilder lines = new StringBuilder();
        JSONArray rows = card.optJSONArray("lines");
        for (int i = 0; rows != null && i < rows.length(); i++) {
            if (lines.length() > 0) lines.append('\n');
            lines.append(rows.optString(i));
        }
        // Big text, not the inbox style, which keeps it from being promoted.
        Notification.Builder builder = new Notification.Builder(context, channel)
            .setSmallIcon(icon(context))
            .setContentTitle(card.optString("title"))
            .setContentText(card.optString("text"))
            .setStyle(new Notification.BigTextStyle().bigText(lines.length() > 0 ? lines : card.optString("text")))
            .setSubText(card.optString("subtext", null))
            .setOngoing(card.optBoolean("ongoing"))
            .setOnlyAlertOnce(card.optBoolean("silent", true))
            .setShowWhen(card.optBoolean("showWhen"))
            .setCategory(Notification.CATEGORY_PROGRESS)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setPublicVersion(publicVersion(context, channel, card))
            .setDeleteIntent(dismiss(context));
        long timeout = card.optLong("timeoutMs", 0);
        if (timeout > 0) builder.setTimeoutAfter(timeout);
        PendingIntent open = open(context, card.optString("link"));
        if (open != null) {
            builder.setContentIntent(open);
            String action = string(card, "action");
            if (!action.isEmpty()) builder.addAction(new Notification.Action.Builder(null, action, open).build());
        }
        String dismissAction = string(card, "dismissAction");
        if (!dismissAction.isEmpty()) builder.addAction(new Notification.Action.Builder(null, dismissAction, dismiss(context)).build());
        if (Build.VERSION.SDK_INT >= 36) {
            String chip = string(card, "chip");
            if (!chip.isEmpty()) builder.setShortCriticalText(chip);
            if (card.optBoolean("promoted")) {
                // Notification.EXTRA_REQUEST_PROMOTED_ONGOING, which the
                // android-36 stubs do not have yet.
                android.os.Bundle extras = new android.os.Bundle();
                extras.putBoolean("android.requestPromotedOngoing", true);
                builder.addExtras(extras);
            }
        }
        return builder.build();
    }

    // What the lock screen shows when it hides what notifications say.
    private static Notification publicVersion(Context context, String channel, JSONObject item) {
        return new Notification.Builder(context, channel)
            .setSmallIcon(icon(context))
            .setContentTitle(item.optString("publicTitle", "HAL-C2"))
            .setContentText(item.optString("publicText"))
            .build();
    }

    // The app's activity with the thread link, which Qt hands the app's
    // `hal-c2` URL handler as it would a link from outside.
    private static PendingIntent open(Context context, String link) {
        if (link == null || link.isEmpty()) return null;
        Intent intent = new Intent(Intent.ACTION_VIEW, Uri.parse(link))
            .setComponent(new ComponentName(context, ACTIVITY))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        return PendingIntent.getActivity(context, link.hashCode(), intent,
            PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
    }

    private static PendingIntent dismiss(Context context) {
        Intent intent = new Intent(context, DismissReceiver.class);
        return PendingIntent.getBroadcast(context, CARD_ID, intent, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
    }

    private static int icon(Context context) {
        int id = context.getResources().getIdentifier("ic_launcher_monochrome", "mipmap", context.getPackageName());
        return id != 0 ? id : android.R.drawable.stat_notify_chat;
    }

    private static NotificationManager manager(Context context) {
        return (NotificationManager) context.getSystemService(Context.NOTIFICATION_SERVICE);
    }
}
