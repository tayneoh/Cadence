# Cadence — Habit Tracker

A free, minimalist habit tracker. It runs entirely in the browser, stores
data locally on each person's device, and installs as an app on phones and
desktops. No accounts, no server, no cost.

## What's in this folder

- `index.html` — the whole app
- `manifest.json` — makes the app installable (name, icon, colors)
- `sw.js` — service worker; lets the app work offline
- `icon-180.png`, `icon-192.png`, `icon-512.png` — app icons
- `icon.svg` — the icon source, if you want to edit it

Keep all of these files together in the same folder. The app references
them by relative path.

## Running it locally

You can open `index.html` directly in a browser and the tracker works.
However, the "install as an app" and offline features need a real web
server (service workers do not run on `file://`). To test those locally:

    cd path/to/this/folder
    python -m http.server 8000

Then visit `http://localhost:8000` in your browser.

## Putting it online for free

### Option A — GitHub Pages

1. Create a free account at github.com and make a new public repository
   (for example, `cadence`).
2. Upload all the files in this folder to the repository (drag-and-drop
   works in the GitHub web interface — use "Add file" then "Upload files").
3. In the repository, go to Settings -> Pages.
4. Under "Build and deployment", set Source to "Deploy from a branch",
   pick the `main` branch and the `/ (root)` folder, then Save.
5. Wait a minute, then refresh. GitHub shows your public URL, which looks
   like `https://your-username.github.io/cadence/`.

Anyone with that link can use it. To update the app later, upload the
changed files again and bump `CACHE_VERSION` in `sw.js` (see below).

### Option B — Netlify

1. Create a free account at netlify.com.
2. On the "Sites" page, drag this entire folder onto the upload area.
3. Netlify gives you a public URL immediately (you can rename it in
   Site settings -> Change site name).

Vercel works the same way if you prefer it.

## Installing it as an app

Once the site is online, anyone can install it:

- **iPhone / iPad (Safari):** open the site, tap the Share button, then
  "Add to Home Screen". It appears with the Cadence icon and opens
  full-screen like a native app.
- **Android (Chrome):** open the site; Chrome shows an "Install app"
  prompt, or use the menu -> "Install app" / "Add to Home Screen".
- **Desktop (Chrome / Edge):** an install icon appears in the address
  bar.

This is a Progressive Web App (PWA). It is a genuine installable app and
costs nothing. A native iOS App Store listing is the only thing that
would cost money — Apple's Developer Program is $99/year — and it is not
required for people to install and use Cadence.

## Updating the app later

Because the service worker caches files for offline use, returning users
can see a stale version after you change `index.html`. When you deploy an
update, open `sw.js` and change the version string:

    const CACHE_VERSION = 'cadence-v1';   ->   'cadence-v2'

That tells every installed copy to fetch the fresh files.

## A note on data

Each person's habits are saved with their browser's LocalStorage, on
their own device. Nothing is uploaded anywhere. That keeps the app free
and private, but it also means data does not sync between devices and is
lost if a user clears their browser data. The "Export Widget Data" button
in the app produces a JSON snapshot anyone can copy out.
