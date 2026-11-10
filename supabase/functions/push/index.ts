// Cadence push function. The database calls it when someone nudges,
// cheers, reacts, comments or posts, and once a minute to send habit
// reminders. It needs three secrets: VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY
// and PUSH_SECRET (the same value as in notifications.sql).
// Deploy with "Verify JWT" turned off; the secret header guards it instead.
import webpush from 'npm:web-push@3.6.7';
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';

const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
webpush.setVapidDetails('https://tayneoh.github.io/Cadence/',
  Deno.env.get('VAPID_PUBLIC_KEY')!, Deno.env.get('VAPID_PRIVATE_KEY')!);

type Note = { title: string; body: string; tag?: string; url?: string };
const EMOJI: Record<string, string> = { heart: '❤️', fire: '🔥', clap: '👏', muscle: '💪', party: '🎉' };

async function nameOf(id: string) {
  const { data } = await sb.from('profiles').select('name').eq('id', id).maybeSingle();
  return ((data?.name || 'Someone') as string).split(/\s+/)[0];
}

// send to every phone this person turned notifications on for,
// unless they switched this kind off
async function sendTo(userId: string, kind: string, note: Note) {
  const { data: subs } = await sb.from('push_subscriptions').select('*').eq('user_id', userId);
  for (const s of subs || []) {
    if (s.prefs && s.prefs[kind] === false) continue;
    try {
      await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
        JSON.stringify({ ...note, url: note.url || './' }), { TTL: 3600 });
    } catch (e) {
      const code = (e as { statusCode?: number }).statusCode;
      if (code === 404 || code === 410) await sb.from('push_subscriptions').delete().eq('endpoint', s.endpoint);
    }
  }
}

async function blocked(a: string, b: string) {
  const { data } = await sb.from('blocks').select('blocker')
    .or(`and(blocker.eq.${a},blocked.eq.${b}),and(blocker.eq.${b},blocked.eq.${a})`).limit(1);
  return !!(data && data.length);
}

async function onEvent(table: string, r: Record<string, any>) {
  if (table === 'nudges') {
    const { data: g } = await sb.from('groups').select('name,habit').eq('id', r.group_id).maybeSingle();
    return sendTo(r.receiver, 'nudges', { title: `${await nameOf(r.sender)} nudged you`,
      body: g ? `Time for ${g.habit} with ${g.name}.` : 'Time to check in.', tag: 'nudge', url: './' });
  }
  if (table === 'cheers') {
    return sendTo(r.receiver, 'cheers', { title: `${await nameOf(r.sender)} cheered you on`,
      body: 'Keep it going today.', tag: 'cheer', url: './' });
  }
  if (table === 'reactions' || table === 'comments') {
    const { data: p } = await sb.from('posts').select('user_id').eq('id', r.post_id).maybeSingle();
    if (!p || p.user_id === r.user_id || await blocked(p.user_id, r.user_id)) return;
    const who = await nameOf(r.user_id);
    if (table === 'reactions') {
      return sendTo(p.user_id, 'likes', { title: `${who} reacted ${EMOJI[r.emoji] || r.emoji} to your post`,
        body: 'Open Cadence to see it.', tag: 'like-' + r.post_id, url: './' });
    }
    return sendTo(p.user_id, 'comments', { title: `${who} commented on your post`,
      body: String(r.body || '').slice(0, 120), tag: 'comment-' + r.post_id, url: './' });
  }
  if (table === 'posts') {
    const { data: owner } = await sb.from('profiles').select('name,visibility').eq('id', r.user_id).maybeSingle();
    if (!owner || owner.visibility === 'private') return;
    const who = ((owner.name || 'A friend') as string).split(/\s+/)[0];
    const body = r.kind === 'checkin' ? `Finished ${r.habit_title} today.`
      : r.kind === 'streak' ? `Hit a ${r.streak}-day streak on ${r.habit_title}.`
      : String(r.body || '').slice(0, 120);
    const { data: fr } = await sb.from('friendships').select('requester,addressee')
      .eq('status', 'accepted').or(`requester.eq.${r.user_id},addressee.eq.${r.user_id}`);
    for (const f of fr || []) {
      const friend = f.requester === r.user_id ? f.addressee : f.requester;
      if (await blocked(friend, r.user_id)) continue;
      await sendTo(friend, 'posts', { title: `${who} posted`, body, tag: 'post-' + r.id, url: './' });
    }
  }
}

// the time, weekday and date somewhere, e.g. { hm: '08:30', dow: 2, day: '2026-11-10' }
function localNow(tz: string) {
  let parts: Intl.DateTimeFormatPart[];
  try {
    parts = new Intl.DateTimeFormat('en-US', { timeZone: tz, hourCycle: 'h23', year: 'numeric', month: '2-digit',
      day: '2-digit', hour: '2-digit', minute: '2-digit', weekday: 'short' }).formatToParts(new Date());
  } catch { return localNow('UTC'); }
  const get = (t: string) => parts.find(p => p.type === t)?.value || '';
  const dow = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'].indexOf(get('weekday'));
  return { hm: `${get('hour')}:${get('minute')}`, dow, day: `${get('year')}-${get('month')}-${get('day')}` };
}
const mins = (hm: string) => Number(hm.slice(0, 2)) * 60 + Number(hm.slice(3, 5));

async function sendReminders() {
  const { data } = await sb.from('reminders').select('*');
  for (const r of data || []) {
    const now = localNow(r.tz || 'UTC');
    const late = mins(now.hm) - mins(r.remind_at);
    // due within the last 10 minutes (covers a skipped minute), not sent or done today
    if (late < 0 || late >= 10 || !r.days.includes(now.dow)) continue;
    if (r.last_sent === now.day || r.done_on === now.day) continue;
    await sb.from('reminders').update({ last_sent: now.day }).eq('user_id', r.user_id).eq('habit_id', r.habit_id);
    await sendTo(r.user_id, 'reminders', { title: r.title, body: 'Time for this habit.', tag: 'remind-' + r.habit_id, url: './' });
  }
}

Deno.serve(async req => {
  if (req.headers.get('x-push-secret') !== Deno.env.get('PUSH_SECRET')) return new Response('no', { status: 401 });
  try {
    const { table, record } = await req.json();
    if (table === 'tick') await sendReminders();
    else await onEvent(table, record || {});
    return new Response('ok');
  } catch (e) {
    return new Response(String(e), { status: 500 });
  }
});
