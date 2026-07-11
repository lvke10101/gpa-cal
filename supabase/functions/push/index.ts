import { JWT } from 'npm:google-auth-library@9'

interface NotificationRow {
  id: string
  user_id: string
  type: string
  body_preview: string | null
}

interface WebhookPayload {
  type: 'INSERT'
  table: string
  record: NotificationRow
  schema: 'public'
}

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const FCM_PROJECT_ID = Deno.env.get('FCM_PROJECT_ID')!
const FCM_CLIENT_EMAIL = Deno.env.get('FCM_CLIENT_EMAIL')!
const FCM_PRIVATE_KEY = Deno.env.get('FCM_PRIVATE_KEY')!.replace(/\\n/g, '\n')

function buildTitleAndBody(row: NotificationRow): { title: string; body: string } {
  const preview = row.body_preview || '';
  switch (row.type) {
    case 'announcement': {
      const [title, body] = preview.split('|||');
      return { title: title || 'Announcement', body: body || '' };
    }
    case 'reply':
      return { title: 'New reply', body: preview };
    case 'credit_topup':
      return { title: 'Credit top-up', body: preview };
    case 'credit_bonus':
      return { title: 'Bonus credits', body: preview };
    case 'credit_signup_bonus':
      return { title: 'Welcome bonus', body: preview };
    default:
      return { title: 'GradeVault', body: preview };
  }
}

async function getAccessToken(): Promise<string> {
  return new Promise((resolve, reject) => {
    const jwtClient = new JWT({
      email: FCM_CLIENT_EMAIL,
      key: FCM_PRIVATE_KEY,
      scopes: ['https://www.googleapis.com/auth/firebase.messaging'],
    })
    jwtClient.authorize((err, tokens) => {
      if (err) { reject(err); return }
      resolve(tokens!.access_token!)
    })
  })
}

Deno.serve(async (req) => {
  try {
    const payload: WebhookPayload = await req.json()
    const row = payload.record

    // Fetch every token for this user — multi-device, not single().
    const tokensRes = await fetch(
      `${SUPABASE_URL}/rest/v1/device_tokens?user_id=eq.${row.user_id}&select=id,fcm_token`,
      { headers: { apikey: SERVICE_ROLE_KEY, Authorization: `Bearer ${SERVICE_ROLE_KEY}` } }
    )
    const tokenRows: { id: string; fcm_token: string }[] = await tokensRes.json()
    if (!tokenRows.length) return Response.json({ skipped: 'no tokens' })

    const { title, body } = buildTitleAndBody(row)
    const accessToken = await getAccessToken()
    const staleTokenIds: string[] = []

    await Promise.all(tokenRows.map(async ({ id, fcm_token }) => {
      const res = await fetch(
        `https://fcm.googleapis.com/v1/projects/${FCM_PROJECT_ID}/messages:send`,
        {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${accessToken}` },
          body: JSON.stringify({
            message: {
              token: fcm_token,
              notification: { title, body },
              android: { notification: { channel_id: 'default' } },
            },
          }),
        }
      )
      if (res.status === 404 || res.status === 400) {
        const errBody = await res.json().catch(() => ({}))
        if (errBody?.error?.status === 'UNREGISTERED' || errBody?.error?.status === 'INVALID_ARGUMENT') {
          staleTokenIds.push(id)
        }
      }
    }))

    // Prune dead tokens so they don't keep failing every future send.
    if (staleTokenIds.length) {
      await fetch(`${SUPABASE_URL}/rest/v1/device_tokens?id=in.(${staleTokenIds.join(',')})`, {
        method: 'DELETE',
        headers: { apikey: SERVICE_ROLE_KEY, Authorization: `Bearer ${SERVICE_ROLE_KEY}` },
      })
    }

    return Response.json({ sent: tokenRows.length - staleTokenIds.length, pruned: staleTokenIds.length })
  } catch (e) {
    console.error('push function error:', e)
    return new Response(JSON.stringify({ error: String(e) }), { status: 500 })
  }
})