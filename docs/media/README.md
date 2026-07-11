# README media

The README hero embeds `docs/media/demo.gif`. Drop the file here and it renders
automatically — no README change needed.

## What to capture (~20–30s)

The one-take "aha" flow, phone screen-recorded:

1. Server already running on the Mac (QR visible in the terminal).
2. Open the app → tap **Scan QR** → point at the terminal.
3. App connects and lands on Home.
4. Open a session, send a message, watch the agent stream a reply + a tool call.
5. (Bonus) Approve a tool call / show a push notification.

Keep it tight. Trim dead air. Portrait phone framing reads well at 720px wide.

## Recording tips

- **iPhone:** Control Center → screen record. Trim in Photos.
- **Convert to GIF** (keeps the repo light — aim for < 8 MB):

  ```sh
  # from a .mov/.mp4, 720px wide, 12fps
  ffmpeg -i demo.mov -vf "fps=12,scale=720:-1:flags=lanczos" -loop 0 demo.gif

  # or higher-quality with a palette
  ffmpeg -i demo.mov -vf "fps=12,scale=720:-1:flags=lanczos,palettegen" palette.png
  ffmpeg -i demo.mov -i palette.png -lavfi "fps=12,scale=720:-1:flags=lanczos[x];[x][1:v]paletteuse" demo.gif
  ```

- If the GIF is too large, prefer an **MP4** and link it, or host on the
  eventual getmakit.dev site and embed the URL.

Also consider dropping a couple of static screenshots (`home.png`,
`session.png`) here for the App Store / landing page later.
