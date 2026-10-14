"""Render _jemdoc/*.jemdoc into the site root.

  python _jemdoc/build.py          rebuild every page
  python _jemdoc/build.py --check  fail if any committed page differs from its source

Edit the .jemdoc source, never the generated .html.
"""
import os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

PAGES = {
    "index": "ga.conf",
    "pubs": "ga-mathjax.conf",
    "talks": "base.conf",
}


def render(page, outdir):
    out = os.path.join(outdir, page + ".html")
    subprocess.run([sys.executable, "jemdoc", "-c", PAGES[page], "-o", out, page + ".jemdoc"],
                   cwd=HERE, check=True, capture_output=True)
    return out


def main():
    check = "--check" in sys.argv
    stale = []
    with tempfile.TemporaryDirectory() as tmp:
        for page in PAGES:
            built = open(render(page, tmp), "rb").read()
            target = os.path.join(ROOT, page + ".html")
            current = open(target, "rb").read() if os.path.exists(target) else None
            if built == current:
                continue
            stale.append(page)
            if not check:
                open(target, "wb").write(built)
    if check and stale:
        sys.exit("out of sync with _jemdoc sources: " + ", ".join(p + ".html" for p in stale)
                 + "\nrun: python _jemdoc/build.py")
    print(("stale: " if check else "rebuilt: ") + (", ".join(stale) or "none"))


if __name__ == "__main__":
    main()
