# AK Assistant website

A static landing page: plain HTML, CSS and JavaScript, with no build step.

```
landing-page-website/
├── index.html     the page
├── styles.css     all styles (light and dark mode)
├── script.js      the popup animation and the writing-tools tabs
└── assets/
    └── icon.png   app icon, favicon and social image
```

## Preview locally

```bash
cd landing-page-website
python3 -m http.server 8000   # then open http://localhost:8000
```

## Deploy

Upload the whole folder to any static host:

- **Netlify:** drag the folder onto app.netlify.com/drop, or set *Base directory* to `landing-page-website` and leave the build command empty.
- **Vercel:** `vercel deploy landing-page-website`, or set *Root Directory* to `landing-page-website` with the *Other* framework preset.
- **Cloudflare Pages:** set the build output directory to `landing-page-website` and leave the build command empty.
- **GitHub Pages:** Pages only serves the repo root or `/docs`; `docs/index.html` already holds the same page for that.

The Download buttons point to `https://github.com/kanakapalli/AK-Assistant/releases/latest`, so publish a GitHub Release with the DMG attached for them to work.
