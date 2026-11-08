#!/usr/bin/env python3
"""Convert Markdown files to PDF.

Two rendering paths are supported, neither of which drives a browser:

  pandoc      pandoc + a LaTeX engine (xelatex/lualatex/tectonic/pdflatex).
  weasyprint  the WeasyPrint library rendering an HTML version of the document.

Both paths pin a CJK font so the Chinese documents under docs/ render
without missing glyphs.

WeasyPrint needs its native text stack:
  pip install weasyprint && brew install pango

By default the PDF is written to the project root (the parent of scripts/)
and opened with the system viewer once created.

Usage:
  ./md2pdf.py docs/issues.md              # -> <root>/issues_20260815_161230.pdf, then opens it
  ./md2pdf.py docs/issues.md --no-timestamp   # -> <root>/issues.pdf
  ./md2pdf.py docs/*.md -o docs/all-docs.pdf --toc
  ./md2pdf.py README.md --engine weasyprint --no-open
"""

import argparse
import contextlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

# Font families that cover Chinese, in the order we prefer them. Availability is
# resolved through fontconfig, since macOS keeps fonts such as PingFang outside
# /System/Library/Fonts these days.
CJK_FONTS = [
    "PingFang SC",
    "Hiragino Sans GB",
    "Songti SC",
    "Noto Sans CJK SC",
    "Source Han Sans SC",
]

LATEX_ENGINES = ["xelatex", "lualatex", "tectonic", "pdflatex"]

# Default output directory: the project root, i.e. the parent of scripts/.
PROJECT_ROOT = Path(__file__).resolve().parent.parent

# LaTeX package each engine needs before pandoc's template can set a CJK font.
CJK_LATEX_PACKAGES = {"xelatex": "xeCJK.sty", "lualatex": "luatexja-fontspec.sty"}

# CJK ideographs plus the compatibility block, enough to spot Chinese text.
CJK_PATTERN = re.compile(r"[⺀-鿿豈-﫿]")

# WeasyPrint dlopens pango/glib by leaf name. Homebrew installs them outside
# dyld's default search path, and macOS only reads DYLD_* at process start, so
# the script re-executes itself once with these directories added.
NATIVE_LIB_DIRS = ["/opt/homebrew/lib", "/usr/local/lib"]
REEXEC_ENV_FLAG = "MD2PDF_NATIVE_LIB_RETRY"

HTML_CSS = """
@page {{ size: {paper}; margin: {margin}; }}
body {{
  /* The symbol faces cover arrows and emoji the text faces lack, and they must
     precede the generic family: WeasyPrint stops falling back once it hits one,
     which is how U+2194 ended up as tofu. */
  font-family: "{cjk}", -apple-system, "Helvetica Neue", Arial,
               "Apple Symbols", "Arial Unicode MS", "Apple Color Emoji", sans-serif;
  font-size: 11pt;
  line-height: 1.6;
  color: #111;
  margin: 0;
}}
h1, h2, h3, h4 {{ line-height: 1.3; page-break-after: avoid; }}
h1 {{ font-size: 20pt; border-bottom: 1px solid #ddd; padding-bottom: .2em; }}
h2 {{ font-size: 16pt; }}
h3 {{ font-size: 13pt; }}
code, pre {{ font-family: "SFMono-Regular", Menlo, Consolas, monospace; font-size: 9.5pt; }}
pre {{
  background: #f6f8fa; padding: .8em; border-radius: 4px;
  white-space: pre-wrap; word-wrap: break-word; page-break-inside: avoid;
}}
code {{ background: #f6f8fa; padding: .1em .3em; border-radius: 3px; }}
pre code {{ background: none; padding: 0; }}
table {{ border-collapse: collapse; width: 100%; page-break-inside: avoid; }}
th, td {{ border: 1px solid #ccc; padding: .4em .6em; text-align: left; }}
th {{ background: #f2f2f2; }}
blockquote {{ margin: 0 0 0 1em; padding-left: .8em; border-left: 3px solid #ddd; color: #555; }}
img {{ max-width: 100%; }}
a {{ color: #0366d6; text-decoration: none; }}
hr {{ border: none; border-top: 1px solid #ddd; }}
"""


class ConversionError(RuntimeError):
    pass


def which(candidates):
    """Return the first candidate that exists as a file or is on PATH."""
    for candidate in candidates:
        if os.path.sep in candidate:
            if Path(candidate).exists():
                return candidate
        else:
            found = shutil.which(candidate)
            if found:
                return found
    return None


def font_available(family):
    """True when fontconfig resolves this exact family rather than a substitute."""
    fc_match = shutil.which("fc-match")
    if not fc_match:
        return None  # unknown; the caller keeps its preferred family
    result = subprocess.run(
        [fc_match, "-f", "%{family}", family], capture_output=True, text=True
    )
    return family.casefold() in (
        name.strip().casefold() for name in result.stdout.split(",")
    )


def pick_cjk_font():
    override = os.environ.get("MD2PDF_CJK_FONT")
    if override:
        return override
    for family in CJK_FONTS:
        available = font_available(family)
        if available or available is None:
            return family
    return CJK_FONTS[0]


# Inserted between documents when several are merged into one PDF. Each raw
# block only reaches the output format it is tagged for.
PAGE_BREAK_MD = (
    "```{=latex}\n"
    "\\newpage\n"
    "```\n\n"
    "```{=html}\n"
    "<div style=\"page-break-after: always\"></div>\n"
    "```\n"
)


@contextlib.contextmanager
def pandoc_inputs(inputs, args):
    """Yield (input arguments, source format), page-breaking between documents."""
    if len(inputs) < 2:
        yield [str(path) for path in inputs], args.md_format
        return
    with tempfile.TemporaryDirectory() as tmp:
        separator = Path(tmp) / "page-break.md"
        separator.write_text(PAGE_BREAK_MD, encoding="utf-8")
        merged = []
        for index, path in enumerate(inputs):
            if index:
                merged.append(str(separator))
            merged.append(str(path))
        yield merged, f"{args.md_format}+raw_attribute"


# Table cells cannot hold a newline in GFM, so docs/issues.md separates the PRs
# in one cell with `<br>`. pandoc's HTML writer passes that through, but its
# LaTeX writer drops raw HTML, which would glue the PRs back onto one line.
# This filter turns `<br>` into a real line break for every output format.
BR_LUA_FILTER = """
function RawInline(el)
  if el.format:match("html") and el.text:match("^<br%s*/?>$") then
    return pandoc.LineBreak()
  end
end
"""


@contextlib.contextmanager
def br_filter():
    """Yield pandoc arguments enabling the `<br>` -> line-break filter."""
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "br.lua"
        path.write_text(BR_LUA_FILTER, encoding="utf-8")
        yield ["--lua-filter", str(path)]


def run(cmd):
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        sys.stderr.write(result.stdout)
        sys.stderr.write(result.stderr)
        raise ConversionError(f"command failed: {cmd[0]} (exit {result.returncode})")
    return result


def has_cjk(inputs):
    """True when any input contains CJK characters, which need a CJK font."""
    return any(
        CJK_PATTERN.search(path.read_text(encoding="utf-8", errors="replace"))
        for path in inputs
    )


def latex_can_do_cjk(engine):
    """True when the LaTeX engine can typeset CJK with pandoc's template."""
    name = Path(engine).name
    if name.startswith("tectonic"):
        return True  # tectonic downloads missing packages on demand
    package = CJK_LATEX_PACKAGES.get(name)
    if not package:
        return False  # pdflatex cannot typeset CJK at all
    kpsewhich = shutil.which("kpsewhich")
    if not kpsewhich:
        return False
    return subprocess.run([kpsewhich, package], capture_output=True).returncode == 0


def pandoc_can_render(inputs, args):
    """Whether the pandoc path can handle these inputs; reason when it cannot."""
    engine = args.pdf_engine or which(LATEX_ENGINES)
    if not engine:
        return False, "no LaTeX engine found (tried: %s)" % ", ".join(LATEX_ENGINES)
    if has_cjk(inputs) and not latex_can_do_cjk(engine):
        package = CJK_LATEX_PACKAGES.get(Path(engine).name)
        missing = f" ({package} is missing)" if package else ""
        return False, f"{Path(engine).name} cannot typeset the CJK text in this document{missing}"
    return True, ""


def convert_with_pandoc(pandoc, inputs, output, args):
    engine = args.pdf_engine or which(LATEX_ENGINES)
    if not engine:
        raise ConversionError(
            "no LaTeX engine found (tried: %s); install one or use --engine weasyprint"
            % ", ".join(LATEX_ENGINES)
        )
    with pandoc_inputs(inputs, args) as (sources, md_format), br_filter() as filter_args:
        # Pandoc resolves relative media paths from its working directory by
        # default, not from each Markdown file. Include every source directory
        # so links such as `user_guide/01-home.png` in docs/user_guide.md are
        # embedded instead of being silently omitted from the PDF.
        resource_dirs = list(dict.fromkeys(
            [str(path.parent.resolve()) for path in inputs] + [str(PROJECT_ROOT)]
        ))
        cmd = [
            pandoc,
            *sources,
            *filter_args,
            "-o", str(output),
            "--from", md_format,
            "--pdf-engine", engine,
            "--resource-path", os.pathsep.join(resource_dirs),
            "-V", f"geometry:margin={args.margin}",
            "-V", f"papersize={args.paper.lower()}",
            "-V", "colorlinks=true",
            "-V", "linkcolor=blue",
        ]
        if has_cjk(inputs):
            cmd += ["-V", f"CJKmainfont={pick_cjk_font()}"]
        if args.toc:
            cmd += ["--toc", "--toc-depth", "3"]
        if args.title:
            cmd += ["-M", f"title={args.title}"]
        run(cmd)


def strip_text_presentation_selectors(html):
    """Drop U+FE0E, which pandoc appends to symbols such as U+2194.

    No installed font carries those variation sequences, so WeasyPrint falls all
    the way through to LastResort and draws a tofu box. Without the selector the
    symbol still gets its text (monochrome) form, which is what FE0E asked for.
    U+FE0F is left alone so emoji keep their color presentation.
    """
    return html.replace("︎", "")


def markdown_to_html(pandoc, inputs, args):
    """Render the inputs to a standalone HTML string."""
    css = HTML_CSS.format(paper=args.paper, margin=args.margin, cjk=pick_cjk_font())
    if pandoc:
        with pandoc_inputs(inputs, args) as (sources, md_format), br_filter() as filter_args:
            cmd = [
                pandoc,
                *sources,
                *filter_args,
                "--from", md_format,
                "--to", "html5",
                "--standalone",
            ]
            # `pagetitle` fills the <title> tag without printing a header the
            # document usually already has as its first heading.
            if args.title:
                cmd += ["--metadata", f"title={args.title}"]
            else:
                cmd += ["--metadata", f"pagetitle={inputs[0].stem}"]
            if args.toc:
                cmd += ["--toc", "--toc-depth", "3"]
            html = run(cmd).stdout
        html = strip_text_presentation_selectors(html)
        return html.replace("</head>", f"<style>{css}</style></head>", 1)

    try:
        from markdown_it import MarkdownIt
    except ImportError:
        raise ConversionError(
            "neither pandoc nor the markdown-it-py module is available; "
            "install pandoc (brew install pandoc) or run: pip install markdown-it-py"
        )
    md = MarkdownIt("commonmark", {"html": True, "linkify": True}).enable("table")
    body = "\n<hr style='page-break-after: always; border: none'>\n".join(
        md.render(path.read_text(encoding="utf-8")) for path in inputs
    )
    title = args.title or inputs[0].stem
    return (
        "<!doctype html><html><head><meta charset='utf-8'>"
        f"<title>{title}</title><style>{css}</style></head><body>{body}</body></html>"
    )


def load_weasyprint():
    """Import WeasyPrint, re-executing once if its native libraries are hidden."""
    try:
        import weasyprint
    except ImportError:
        raise ConversionError(
            "the weasyprint module is not installed; run: pip install weasyprint"
        )
    except OSError as error:
        # cffi could not dlopen pango/glib.
        dirs = [d for d in NATIVE_LIB_DIRS if Path(d).is_dir()]
        if os.environ.get(REEXEC_ENV_FLAG) or not dirs:
            raise ConversionError(
                f"weasyprint cannot load its native libraries ({error}); "
                "install them with: brew install pango"
            )
        sys.stderr.write(
            "note: restarting with %s on DYLD_FALLBACK_LIBRARY_PATH so weasyprint "
            "can load pango\n" % os.pathsep.join(dirs)
        )
        env = dict(os.environ)
        env[REEXEC_ENV_FLAG] = "1"
        env["DYLD_FALLBACK_LIBRARY_PATH"] = os.pathsep.join(
            dirs + [str(Path.home() / "lib"), "/usr/local/lib", "/usr/lib"]
        )
        os.execve(sys.executable, [sys.executable, str(Path(__file__).resolve()), *sys.argv[1:]], env)
    return weasyprint


def convert_with_weasyprint(pandoc, inputs, output, args):
    weasyprint = load_weasyprint()
    html = markdown_to_html(pandoc, inputs, args)
    # base_url makes relative image paths in the Markdown resolve.
    document = weasyprint.HTML(string=html, base_url=str(inputs[0].parent.resolve()))
    document.write_pdf(str(output))


def open_file(path):
    """Open the file with the platform's default viewer; never fatal."""
    if sys.platform == "darwin":
        cmd = ["open", str(path)]
    elif os.name == "nt":
        os.startfile(str(path))  # type: ignore[attr-defined]
        return
    else:
        cmd = ["xdg-open", str(path)]
    try:
        subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError as error:
        sys.stderr.write(f"note: could not open {path}: {error}\n")


def parse_args(argv):
    parser = argparse.ArgumentParser(
        description="Convert Markdown files to PDF.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__.split("Usage:")[1].strip() if "Usage:" in __doc__ else None,
    )
    parser.add_argument("inputs", nargs="+", type=Path, help="Markdown files to convert")
    parser.add_argument(
        "-o", "--output", type=Path,
        help="output PDF, used verbatim; with several inputs they are merged into "
             f"this one file (default: <input>_<timestamp>.pdf in {PROJECT_ROOT})",
    )
    parser.add_argument(
        "--no-timestamp", action="store_true",
        help="name default outputs <input>.pdf instead of <input>_<timestamp>.pdf",
    )
    parser.add_argument(
        "--no-open", action="store_true",
        help="do not open the generated PDF with the system viewer",
    )
    parser.add_argument(
        "--engine", choices=["auto", "pandoc", "weasyprint"], default="auto",
        help="renderer to use (default: auto - pandoc when it can typeset the "
             "document, else weasyprint)",
    )
    parser.add_argument(
        "--pdf-engine", help=f"LaTeX engine for the pandoc path (default: first of {', '.join(LATEX_ENGINES)})"
    )
    parser.add_argument("--md-format", default="gfm", help="pandoc input format (default: gfm)")
    parser.add_argument("--paper", default="A4", help="paper size (default: A4)")
    parser.add_argument("--margin", default="20mm", help="page margin (default: 20mm)")
    parser.add_argument("--toc", action="store_true", help="add a table of contents")
    parser.add_argument("--title", help="document title (default: taken from the file)")
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)

    for path in args.inputs:
        if not path.is_file():
            raise SystemExit(f"error: no such file: {path}")

    pandoc = shutil.which("pandoc")
    if args.engine == "pandoc" and not pandoc:
        raise SystemExit(
            "error: pandoc not found (brew install pandoc), or use --engine weasyprint"
        )

    if args.output:
        batches = [(args.inputs, args.output)]
    else:
        stamp = "" if args.no_timestamp else time.strftime("_%Y%m%d_%H%M%S")
        batches = [
            ([path], PROJECT_ROOT / f"{path.stem}{stamp}.pdf") for path in args.inputs
        ]

    for inputs, output in batches:
        engine = args.engine
        if engine == "auto":
            engine = "weasyprint"
            if pandoc:
                usable, reason = pandoc_can_render(inputs, args)
                if usable:
                    engine = "pandoc"
                else:
                    sys.stderr.write(f"note: falling back to weasyprint ({reason})\n")
        output.parent.mkdir(parents=True, exist_ok=True)
        try:
            if engine == "pandoc":
                convert_with_pandoc(pandoc, inputs, output, args)
            else:
                convert_with_weasyprint(pandoc, inputs, output, args)
        except ConversionError as error:
            if args.engine != "auto" or engine == "weasyprint":
                raise SystemExit(f"error: {error}")
            sys.stderr.write(f"note: pandoc failed ({error}); retrying with weasyprint\n")
            try:
                convert_with_weasyprint(pandoc, inputs, output, args)
            except ConversionError as fallback_error:
                raise SystemExit(f"error: {fallback_error}")
        size = output.stat().st_size
        print(f"{', '.join(str(p) for p in inputs)} -> {output} ({size / 1024:.0f} KB)")
        if not args.no_open:
            open_file(output)


if __name__ == "__main__":
    main()
