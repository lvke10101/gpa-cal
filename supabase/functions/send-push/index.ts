// supabase/functions/send-push/index.ts
//
// Triggered by a Supabase Database Webhook on INSERT into `notifications`.
// Looks up the recipient's registered devices in `push_tokens` and sends
// each one a push notification via Firebase Cloud Messaging (HTTP v1 API).
//
// Required secrets (set with `supabase secrets set NAME=value`):
//   FIREBASE_PROJECT_ID   - Firebase project id
//   FIREBASE_CLIENT_EMAIL - service account "client_email"
//   FIREBASE_PRIVATE_KEY  - service account "private_key" (keep the \n's)
//
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are injected automatically.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const FIREBASE_PROJECT_ID = Deno.env.get("FIREBASE_PROJECT_ID")!;
const FIREBASE_CLIENT_EMAIL = Deno.env.get("FIREBASE_CLIENT_EMAIL")!;
const FIREBASE_PRIVATE_KEY = (Deno.env.get("FIREBASE_PRIVATE_KEY") || "").replace(/\\n/g, "\n");

const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

// ── Google OAuth2 access token from the service account (RS256 JWT) ──────
let cachedToken: { value: string; expiresAt: number } | null = null;

function pemToArrayBuffer(pem: string): ArrayBuffer {
  const b64 = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s+/g, "");
  const raw = atob(b64);
  const buf = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) buf[i] = raw.charCodeAt(i);
  return buf.buffer;
}

function base64url(input: ArrayBuffer | string): string {
  const bytes = typeof input === "string" ? new TextEncoder().encode(input) : new Uint8Array(input);
  let str = "";
  bytes.forEach((b) => (str += String.fromCharCode(b)));
  return btoa(str).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function getAccessToken(): Promise<string> {
  if (cachedToken && cachedToken.expiresAt > Date.now() + 60_000) {
    return cachedToken.value;
  }

  const header = { alg: "RS256", typ: "JWT" };
  const now = Math.floor(Date.now() / 1000);
  const claims = {
    iss: FIREBASE_CLIENT_EMAIL,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  };
  const unsigned = `${base64url(JSON.stringify(header))}.${base64url(JSON.stringify(claims))}`;

  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToArrayBuffer(FIREBASE_PRIVATE_KEY),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(unsigned));
  const jwt = `${unsigned}.${base64url(signature)}`;

  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: jwt,
    }),
  });
  if (!res.ok) throw new Error(`Failed to get access token: ${await res.text()}`);

  const data = await res.json();
  cachedToken = { value: data.access_token, expiresAt: Date.now() + data.expires_in * 1000 };
  return cachedToken.value;
}

// ── Human-readable title/body for each notification type ─────────────────
async function buildMessage(record: any) {
  let actorName = "Someone";
  if (record.actor_id) {
    const { data: actor } = await supabase
      .from("gpa_data")
      .select("username, full_name")
      .eq("id", record.actor_id)
      .maybeSingle();
    if (actor) actorName = actor.full_name || actor.username || actorName;
  }

  if (record.type === "announcement") {
    const raw = record.body_preview || "";
    const idx = raw.indexOf("|||");
    const title = idx === -1 ? "Announcement" : raw.slice(0, idx);
    const body = idx === -1 ? raw : raw.slice(idx + 3);
    return { title: title || "Announcement", body: body || "New announcement" };
  }
  if (record.type === "reply") {
    return { title: "New reply", body: `${actorName} replied to your comment` };
  }
  if (record.type === "like") {
    return { title: "New like", body: `${actorName} liked your post` };
  }
  return { title: "GradeVault", body: `${actorName} sent you a notification` };
}

Deno.serve(async (req) => {
  try {
    const payload = await req.json();
    const record = payload.record ?? payload;
    if (!record?.user_id) {
      return new Response(JSON.stringify({ skipped: "no user_id" }), { status: 200 });
    }

    const { data: tokens, error: tokErr } = await supabase
      .from("push_tokens")
      .select("id, token")
      .eq("user_id", record.user_id);
    if (tokErr) throw tokErr;
    if (!tokens || tokens.length === 0) {
      return new Response(JSON.stringify({ skipped: "no devices registered" }), { status: 200 });
    }

    const { title, body } = await buildMessage(record);
    const accessToken = await getAccessToken();

    const results = await Promise.all(
      tokens.map(async (t) => {
        const res = await fetch(
          `https://fcm.googleapis.com/v1/projects/${FIREBASE_PROJECT_ID}/messages:send`,
          {
            method: "POST",
            headers: {
              Authorization: `Bearer ${accessToken}`,
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              message: {
                token: t.token,
                notification: { title, body },
                data: {
                  notification_id: String(record.id ?? ""),
                  type: String(record.type ?? ""),
                  post_id: String(record.post_id ?? ""),
                },
                android: { priority: "high" },
              },
            }),
          }
        );

        if (!res.ok) {
          const errText = await res.text();
          // Stale/uninstalled device — stop trying to push to it.
          if (res.status === 404 || errText.includes("UNREGISTERED") || errText.includes("NOT_FOUND")) {
            await supabase.from("push_tokens").delete().eq("id", t.id);
          }
          return { tokenId: t.id, ok: false, error: errText };
        }
        return { tokenId: t.id, ok: true };
      })
    );

    return new Response(JSON.stringify({ results }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  } catch (err) {
    console.error(err);
    return new Response(JSON.stringify({ error: String(err) }), { status: 500 });
  }
});
