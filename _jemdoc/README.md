# Site sources

The pages listed in `build.py` are generated from the `.jemdoc` files here. Edit the source, then rebuild:

```
python _jemdoc/build.py           # regenerate the .html files in the site root
python _jemdoc/build.py --check   # what CI runs: fails if any .html was edited by hand
```

Commit the `.jemdoc` change and the regenerated `.html` together.

- `ga.conf` adds the GA4 tag; `ga-mathjax.conf` adds GA4 plus MathJax; `base.conf` adds neither. The page-to-conf mapping is `PAGES` in `build.py`.
- `jemdoc` is jemdoc+MathJax 0.7.3, patched to always write LF line endings so builds are identical on Windows and Linux.
- The homepage hero layout is a raw HTML block inside `index.jemdoc`; its styles live in `../jemdoc.css`.
