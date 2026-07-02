# Push Notifications Setup

Everything's coded — this is the checklist to wire it to a real Firebase project and deploy it.

## 1. Create the Firebase project

1. Go to https://console.firebase.google.com → **Add project** → name it (e.g. `gradevault`) → finish the wizard.
2. In the project, click **Add app → Android**.
   - Android package name: `com.lvke10101.gradevault` (must match exactly)
   - App nickname: anything
   - You can skip the SHA-1 cert field.
3. Download the generated **`google-services.json`**.
4. Place it at `android/app/google-services.json` in the project (that's the exact path your `build.gradle` already checks for).

## 2. Get a service account key (for the server to send pushes)

1. In Firebase console: **Project settings (gear icon) → Service accounts**.
2. Click **Generate new private key** → downloads a JSON file. Keep it secret, don't commit it.
3. From that JSON you'll need three fields for step 4: `project_id`, `client_email`, `private_key`.

## 3. Install the plugin and sync

```bash
npm install
npx cap sync android
```
This pulls in `@capacitor/push-notifications` and registers it natively.

## 4. Apply the database migration

```bash
supabase link --project-ref <your-project-ref>   # if not already linked
supabase db push
```
This creates the `push_tokens` table (`supabase/migrations/20260702_push_tokens.sql`).

## 5. Deploy the Edge Function and set its secrets

```bash
supabase functions deploy send-push

supabase secrets set FIREBASE_PROJECT_ID="<project_id from service account JSON>"
supabase secrets set FIREBASE_CLIENT_EMAIL="<client_email from service account JSON>"
supabase secrets set FIREBASE_PRIVATE_KEY="<private_key from service account JSON, keep the \n's as-is>"
```
Tip: wrap `FIREBASE_PRIVATE_KEY` in double quotes so the shell doesn't mangle the newlines.

## 6. Wire the trigger: Database Webhook → Edge Function

In the Supabase dashboard: **Database → Webhooks → Create a new webhook**
- Table: `notifications`
- Events: `Insert`
- Type: `Supabase Edge Function`
- Function: `send-push`

That's it — no manual SQL trigger needed. Supabase's built-in webhook system POSTs `{ type, table, record, ... }` to your function on every insert, which is exactly what `send-push/index.ts` expects.

## 7. Build and test

```bash
npx cap sync android
npx cap open android
```
Build/run on a real device (FCM push doesn't reliably reach emulators without Google Play services). Log in, background the app, then trigger a notification (like a post, reply to a comment, or send an announcement) from another account — a push should appear.

## How it works end-to-end

1. On login, the app calls `PushNotifications.register()` and gets an FCM token.
2. The token is upserted into `push_tokens` (one row per device, keyed by user + token).
3. Any insert into `notifications` (likes, replies, announcements — anything, since it's not tied to a specific RPC) fires the `send-push` webhook.
4. `send-push` looks up the recipient's device tokens, builds a title/body based on the notification `type`, and sends via FCM's HTTP v1 API using your service account credentials.
5. Stale/uninstalled device tokens are automatically pruned from `push_tokens` when FCM reports them as invalid.
6. On logout, the device's token is deleted so that device stops receiving pushes for that account.

## Notes

- This covers **Android only** (matches your current project — there's no `ios/` folder yet).
- Tapping a push notification currently just opens the notifications panel (`pushNotificationActionPerformed` listener in `www/index.html`). Let me know if you want it to deep-link to the specific post/comment instead.
- No custom small-icon was set for the status bar notification (Android requires a special white/transparent silhouette icon); it'll fall back to your app icon. I can generate a proper monochrome status-bar icon if you want a polished look.
