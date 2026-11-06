package io.github.halc2.mobile;

import android.app.AlarmManager;
import android.app.PendingIntent;
import android.appwidget.AppWidgetManager;
import android.appwidget.AppWidgetProvider;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;
import android.view.View;
import android.widget.RemoteViews;

import java.text.DateFormat;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Date;
import java.util.List;

import org.json.JSONArray;
import org.json.JSONObject;

// The Subscription usage widget. It only draws the last snapshot the app gave
// it (src/SubscriptionWidget.h, usage_widget::snapshot), which the app keeps
// current while it is in front; a provider whose first shown window has reset
// since says to open the app instead. Tapping it opens the app on Limits.
public final class UsageWidget extends AppWidgetProvider {
    private static final String PREFERENCES = "hal_c2_usage_widget";
    private static final String EXPIRE = "io.github.halc2.mobile.UsageWidget.EXPIRE";
    private static final String LINK = "hal-c2://usage/limits";

    // How many of the widget are on the home screen (SubscriptionWidget.cpp).
    public static int placed(Context context) {
        return AppWidgetManager.getInstance(context).getAppWidgetIds(new ComponentName(context, UsageWidget.class)).length;
    }

    // What every widget draws from now on, kept for when the app is not running.
    public static void show(Context context, String snapshot) {
        context.getSharedPreferences(PREFERENCES, 0).edit().putString("snapshot", snapshot).apply();
        updateAll(context);
    }

    @Override
    public void onUpdate(Context context, AppWidgetManager manager, int[] ids) {
        for (int id : ids) update(context, manager, id);
    }

    @Override
    public void onReceive(Context context, Intent intent) {
        super.onReceive(context, intent);
        if (EXPIRE.equals(intent.getAction())) updateAll(context);
    }

    @Override
    public void onDisabled(Context context) {
        context.getSystemService(AlarmManager.class).cancel(expiryIntent(context));
    }

    @Override
    public void onAppWidgetOptionsChanged(Context context, AppWidgetManager manager, int id, Bundle options) {
        update(context, manager, id);
    }

    private static void updateAll(Context context) {
        AppWidgetManager manager = AppWidgetManager.getInstance(context);
        for (int id : manager.getAppWidgetIds(new ComponentName(context, UsageWidget.class))) update(context, manager, id);
    }

    private static PendingIntent expiryIntent(Context context) {
        return PendingIntent.getBroadcast(context, 0, new Intent(context, UsageWidget.class).setAction(EXPIRE),
                                          PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
    }

    private static long millis(String iso) {
        if (iso == null || iso.isEmpty()) return 0;
        try {
            return Instant.parse(iso).toEpochMilli();
        } catch (RuntimeException e) {
            return 0;
        }
    }

    private static JSONObject snapshot(Context context) {
        String saved = context.getSharedPreferences(PREFERENCES, 0).getString("snapshot", null);
        if (saved == null) return null;
        try {
            return new JSONObject(saved);
        } catch (Exception e) {
            return null;
        }
    }

    private static void update(Context context, AppWidgetManager manager, int id) {
        JSONObject snapshot = snapshot(context);
        RemoteViews views = new RemoteViews(context.getPackageName(), R.layout.hal_c2_usage_widget);
        PendingIntent open = openApp(context, id, snapshot);
        if (open != null) views.setOnClickPendingIntent(R.id.hal_c2_widget_root, open);
        JSONArray providers = snapshot == null ? null : snapshot.optJSONArray("providers");
        long now = System.currentTimeMillis();
        long nextExpiry = Long.MAX_VALUE;
        // Each provider's rows: its windows while they hold, else one that says to open the app.
        List<List<Object[]>> groups = new ArrayList<>();
        int longest = 0;
        for (int i = 0; providers != null && i < providers.length(); ++i) {
            JSONObject provider = providers.optJSONObject(i);
            if (provider == null) continue;
            JSONArray windows = provider.optJSONArray("windows");
            long expiresAt = millis(provider.optString("expiresAt"));
            List<Object[]> rows = new ArrayList<>();
            if (expiresAt > now && windows != null && windows.length() > 0) {
                nextExpiry = Math.min(nextExpiry, expiresAt);
                for (int w = 0; w < windows.length(); ++w) rows.add(new Object[] {provider, windows.optJSONObject(w)});
            } else {
                rows.add(new Object[] {provider, null});
            }
            groups.add(rows);
            longest = Math.max(longest, rows.size());
        }
        // Every provider first, then their other windows in what room is left.
        List<Object[]> rows = new ArrayList<>();
        for (int index = 0; index < longest; ++index) {
            for (List<Object[]> group : groups) {
                if (index < group.size()) rows.add(group.get(index));
            }
        }
        if (!rows.isEmpty()) {
            views.removeAllViews(R.id.hal_c2_widget_rows);
            int height = manager.getAppWidgetOptions(id).getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 180);
            int count = Math.min(Math.max((height - 64) / 66, 1), Math.min(12, rows.size()));
            for (int i = 0; i < count; ++i) {
                views.addView(R.id.hal_c2_widget_rows, row(context, (JSONObject) rows.get(i)[0], (JSONObject) rows.get(i)[1]));
            }
            long checkedAt = millis(snapshot.optString("checkedAt"));
            String checked = checkedAt > 0
                ? context.getString(R.string.hal_c2_usage_widget_as_of,
                                    DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT).format(new Date(checkedAt)))
                : context.getString(R.string.hal_c2_usage_widget_unknown_check);
            int more = rows.size() - count;
            views.setTextViewText(R.id.hal_c2_widget_footer, more > 0 ? checked + context.getString(R.string.hal_c2_usage_widget_more, more) : checked);
        }
        AlarmManager alarms = context.getSystemService(AlarmManager.class);
        alarms.cancel(expiryIntent(context));
        // Inexact and not waking the device: the time it was checked stays on show if Android is late.
        if (nextExpiry != Long.MAX_VALUE) alarms.set(AlarmManager.RTC, nextExpiry, expiryIntent(context));
        manager.updateAppWidget(id, views);
    }

    // The app's own launcher, so another build installed beside it cannot take the tap.
    private static PendingIntent openApp(Context context, int id, JSONObject snapshot) {
        Intent intent = context.getPackageManager().getLaunchIntentForPackage(context.getPackageName());
        if (intent == null) return null;
        String link = snapshot == null ? "" : snapshot.optString("url");
        intent.setAction(Intent.ACTION_VIEW);
        intent.setData(Uri.parse(link.isEmpty() ? LINK : link));
        intent.setFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP);
        return PendingIntent.getActivity(context, id, intent, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
    }

    private static RemoteViews row(Context context, JSONObject provider, JSONObject window) {
        RemoteViews child = new RemoteViews(context.getPackageName(), R.layout.hal_c2_usage_widget_row);
        String label = provider.optString("label");
        String detail = provider.optString("detail");
        String windowLabel = window == null ? detail : window.optString("label");
        child.setTextViewText(R.id.hal_c2_widget_label, label);
        child.setTextViewText(R.id.hal_c2_widget_window, windowLabel);
        String percent = "—";
        if (window != null) {
            int remaining = Math.max(0, Math.min(100, window.optInt("remainingPercent")));
            percent = context.getString(R.string.hal_c2_usage_widget_remaining, remaining);
            child.setProgressBar(R.id.hal_c2_widget_progress, 100, remaining, false);
        }
        child.setViewVisibility(R.id.hal_c2_widget_progress, window == null ? View.GONE : View.VISIBLE);
        child.setTextViewText(R.id.hal_c2_widget_percent, percent);
        String reset = context.getString(R.string.hal_c2_usage_widget_refresh);
        long resetsAt = window == null ? 0 : millis(window.optString("resetsAt"));
        if (resetsAt > 0) {
            reset = context.getString(R.string.hal_c2_usage_widget_resets,
                                      DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT).format(new Date(resetsAt)));
        }
        child.setTextViewText(R.id.hal_c2_widget_reset, reset);
        child.setContentDescription(R.id.hal_c2_widget_row, label + ". " + windowLabel + ". " + percent + ". " + reset + ". " + detail);
        return child;
    }
}
