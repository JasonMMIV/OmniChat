# Markdown Preview Vendor Assets

These files are loaded by `assets/html/mark.html` from a temporary directory so
Markdown preview works offline on Windows, Android, and macOS (iOS still needs
device verification). All scripts are classic (UMD/IIFE) scripts; no ES modules
or CDN imports are used.

| File | Package / version | Source | License |
|:--|:--|:--|:--|
| `markdown-it.min.js` | markdown-it 14.0.0 | `https://cdn.jsdelivr.net/npm/markdown-it@14.0.0/dist/markdown-it.min.js` | MIT |
| `markdown-it-task-lists.min.js` | markdown-it-task-lists 2.1.1 | `https://cdn.jsdelivr.net/npm/markdown-it-task-lists@2.1.1/dist/markdown-it-task-lists.min.js` | ISC |
| `markdown-it-katex.min.js` | @vscode/markdown-it-katex 1.1.2 | CJS plugin, bundled to IIFE with esbuild; `katex` external | MIT |
| `katex.min.js` | KaTeX 0.16.8 | `https://cdn.jsdelivr.net/npm/katex@0.16.8/dist/katex.min.js` | MIT |
| `katex.min.css` | KaTeX 0.16.8 | `https://cdn.jsdelivr.net/npm/katex@0.16.8/dist/katex.min.css` | MIT |
| `fonts/*.woff2` | KaTeX 0.16.8 | `https://cdn.jsdelivr.net/npm/katex@0.16.8/dist/fonts/` | MIT |
| `highlight.min.js` | highlight.js 11.9.0 | `https://cdn.jsdelivr.net/npm/@highlightjs/cdn-assets@11.9.0/highlight.min.js` | BSD-3-Clause |
| `atom-one-dark.min.css` | highlight.js 11.9.0 | `https://cdn.jsdelivr.net/npm/highlight.js@11.9.0/styles/atom-one-dark.min.css` | BSD-3-Clause |
| `purify.min.js` | DOMPurify 3.2.4 | `https://cdn.jsdelivr.net/npm/dompurify@3.2.4/dist/purify.min.js` | Apache-2.0 / MPL-2.0 |
| `base64.min.js` | js-base64 3.7.5 | `https://cdn.jsdelivr.net/npm/js-base64@3.7.5/base64.min.js` | BSD-3-Clause |
| `mermaid.min.js` | Mermaid (existing app asset) | copied at runtime from `assets/mermaid.min.js` | MIT |

`markdown-it-katex.min.js` was generated with (KaTeX is external, so it is
not shipped twice; `mark.html` loads `katex.min.js` before this plugin):

```bash
curl -sL "https://cdn.jsdelivr.net/npm/@vscode/markdown-it-katex@1.1.2/dist/index.js" -o /tmp/plugin.cjs
printf "module.exports = window.katex;\n" > /tmp/katex-shim.cjs
printf "const mod = require('/tmp/plugin.cjs');\nwindow.markdownItKatex = mod.default || mod;\n" > /tmp/entry.cjs
npx --yes esbuild /tmp/entry.cjs --bundle --minify --format=iife \
  --alias:katex=/tmp/katex-shim.cjs \
  --outfile=assets/html/vendor/markdown-it-katex.min.js
```

`mermaid.min.js` is not duplicated in this directory in the repository; the
runtime asset extractor copies `assets/mermaid.min.js` into the preview
directory as `vendor/mermaid.min.js`.
