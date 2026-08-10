"""Render the scope-and-integration HTML into a Word document.

Generated FROM the HTML rather than authored twice, so the two cannot drift: the
HTML stays the source of truth and this walks its DOM. Word gets real headings,
real tables and real lists, so it is navigable and editable rather than a picture
of a web page.

Only the subset of markup the document actually uses is handled; anything
unexpected raises rather than being silently dropped, because a silently missing
paragraph in a document being circulated for review is worse than a failure here.
"""
from __future__ import annotations

import io
import re
import sys
from html.parser import HTMLParser

from docx import Document
from docx.enum.table import WD_TABLE_ALIGNMENT
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Pt, RGBColor, Inches

SRC = sys.argv[1]
OUT = sys.argv[2]


def refuse_if_annotated(path):
    """Never overwrite a Word file somebody has commented on.

    This exists because it already happened once: the target was regenerated
    over a copy carrying the user's highlighted comments, and comments live only
    in the .docx - the HTML this is generated from has no idea they exist, so
    nothing here could reconstruct them. A generated artefact must never be able
    to destroy hand-authored review feedback.
    """
    import os
    import zipfile

    if not os.path.exists(path):
        return
    try:
        with zipfile.ZipFile(path) as z:
            names = z.namelist()
            annotated = any("comment" in n.lower() for n in names)
            if not annotated and "word/document.xml" in names:
                annotated = b"<w:highlight" in z.read("word/document.xml")
    except zipfile.BadZipFile:
        return

    if annotated:
        alt = path.replace(".docx", "_regenerated.docx")
        sys.exit(
            "REFUSED: " + path + " carries comments or highlighting. "
            "Generated output would destroy them - they exist only in the "
            ".docx, so nothing here could rebuild them. "
            "Write to " + alt + " instead, or move the annotated copy aside."
        )


refuse_if_annotated(OUT)

ACCENT = RGBColor(0xA8, 0x5F, 0x13)
INK_SOFT = RGBColor(0x55, 0x65, 0x7A)
RULE = "DDE3EA"
CHANGE = RGBColor(0xC0, 0x39, 0x2B)   # review changes, 06-Aug-2026


# ── a tiny DOM, because html.parser is a stream and tables need structure ──
class Node:
    def __init__(self, tag, attrs=None):
        self.tag = tag
        self.attrs = dict(attrs or {})
        self.kids = []
        self.text = ""

    def add(self, n):
        self.kids.append(n)
        return n


class Build(HTMLParser):
    VOID = {"br", "hr", "meta", "img", "input", "link"}
    SKIP = {"script", "style", "head", "button"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.root = Node("root")
        self.stack = [self.root]
        self.skipping = 0

    def handle_starttag(self, tag, attrs):
        if tag in self.SKIP:
            self.skipping += 1
            return
        if self.skipping:
            return
        n = Node(tag, attrs)
        self.stack[-1].add(n)
        if tag not in self.VOID:
            self.stack.append(n)

    def handle_endtag(self, tag):
        if tag in self.SKIP:
            self.skipping = max(0, self.skipping - 1)
            return
        if self.skipping or tag in self.VOID:
            return
        for i in range(len(self.stack) - 1, 0, -1):
            if self.stack[i].tag == tag:
                del self.stack[i:]
                return

    def handle_data(self, data):
        if self.skipping:
            return
        if data.strip():
            t = Node("#text")
            t.text = data
            self.stack[-1].add(t)


def flat(node):
    """Inline text of a node, with runs of whitespace collapsed."""
    out = []

    def walk(n):
        if n.tag == "#text":
            out.append(n.text)
        elif n.tag == "br":
            out.append(" ")
        else:
            for k in n.kids:
                walk(k)

    walk(node)
    return re.sub(r"\s+", " ", "".join(out)).strip()


def runs(node, para, bold=False, italic=False, mono=False):
    """Emit inline runs, preserving strong / em / code emphasis."""
    for k in node.kids:
        if k.tag == "#text":
            txt = re.sub(r"\s+", " ", k.text)
            if not txt:
                continue
            r = para.add_run(txt)
            r.bold = bold
            r.italic = italic
            if mono:
                r.font.name = "Consolas"
                r.font.size = Pt(9)
        elif k.tag == "br":
            para.add_run().add_break()
        elif k.tag in ("strong", "b"):
            runs(k, para, True, italic, mono)
        elif k.tag in ("em", "i"):
            runs(k, para, bold, True, mono)
        elif k.tag == "code":
            runs(k, para, bold, italic, True)
        elif k.tag == "span" and "chg" in (k.attrs.get("class") or ""):
            # Marked as changed in this revision. Coloured rather than
            # highlighted: highlighting is what a reviewer uses, and taking it
            # over would make their marks and ours indistinguishable.
            before = len(para.runs)
            runs(k, para, bold, italic, mono)
            for r in para.runs[before:]:
                r.font.color.rgb = CHANGE
        else:
            runs(k, para, bold, italic, mono)


def shade(cell, hexfill):
    el = OxmlElement("w:shd")
    el.set(qn("w:val"), "clear")
    el.set(qn("w:fill"), hexfill)
    cell._tc.get_or_add_tcPr().append(el)


def find(node, pred):
    if pred(node):
        yield node
    for k in node.kids:
        yield from find(k, pred)


def cls(node):
    return node.attrs.get("class", "")


# ── build ────────────────────────────────────────────────────────────────
dom = Build()
dom.feed(open(SRC, encoding="utf-8").read())

sheet = next(find(dom.root, lambda n: n.tag == "div" and "sheet" in cls(n)))

doc = Document()
st = doc.styles["Normal"]
st.font.name = "Calibri"
st.font.size = Pt(10.5)
for sec in doc.sections:
    sec.left_margin = sec.right_margin = Inches(0.85)
    sec.top_margin = sec.bottom_margin = Inches(0.8)


def add_table(tnode):
    trs = [r for r in find(tnode, lambda n: n.tag == "tr")]
    if not trs:
        return
    ncol = max(
        sum(int(c.attrs.get("colspan", 1)) for c in tr.kids if c.tag in ("td", "th"))
        for tr in trs
    )
    t = doc.add_table(rows=0, cols=ncol)
    t.style = "Table Grid"
    t.alignment = WD_TABLE_ALIGNMENT.CENTER
    for tr in trs:
        cells = [c for c in tr.kids if c.tag in ("td", "th")]
        if not cells:
            continue
        row = t.add_row().cells
        i = 0
        for c in cells:
            span = int(c.attrs.get("colspan", 1))
            target = row[i]
            if span > 1 and i + span - 1 < len(row):
                target = target.merge(row[i + span - 1])
            target.text = ""
            p = target.paragraphs[0]
            p.paragraph_format.space_after = Pt(2)
            runs(c, p, bold=(c.tag == "th"))
            if c.tag == "th":
                shade(target, "F1F3F6")
            i += span
    doc.add_paragraph()


def add_image(node):
    """Place a diagram. The src is a data: URI so the HTML stays self-contained.

    Sized to the text column rather than natural size - these are rendered at
    1740px so they stay sharp when Word scales them down, and inserting at
    natural size would put a 24-inch image on a 6.5-inch page.
    """
    import base64

    src = node.attrs.get("src", "")
    if not src.startswith("data:image"):
        return
    raw = base64.b64decode(src.split(",", 1)[1])
    doc.add_picture(io.BytesIO(raw), width=Inches(6.3))
    doc.paragraphs[-1].alignment = WD_ALIGN_PARAGRAPH.CENTER


def add_note(node):
    p = doc.add_paragraph()
    p.paragraph_format.left_indent = Inches(0.2)
    p.paragraph_format.space_before = Pt(6)
    p.paragraph_format.space_after = Pt(8)
    runs(node, p)
    for r in p.runs:
        r.font.size = Pt(9.5)
    pPr = p._p.get_or_add_pPr()
    bdr = OxmlElement("w:pBdr")
    left = OxmlElement("w:left")
    left.set(qn("w:val"), "single")
    left.set(qn("w:sz"), "18")
    left.set(qn("w:space"), "8")
    left.set(qn("w:color"), "D9A53C")
    bdr.append(left)
    pPr.append(bdr)


def raw_text(node):
    """Text with whitespace PRESERVED, for <pre>.

    flat() collapses runs of whitespace, which is right for prose and destroys
    SQL - indentation and line breaks are the only thing making a 90-line query
    readable.
    """
    out = []

    def walk(n):
        if n.tag == "#text":
            out.append(n.text)
        elif n.tag == "br":
            out.append("\n")
        else:
            for k in n.kids:
                walk(k)

    walk(node)
    return "".join(out).strip("\n")


def add_pre(node):
    """A preformatted block - SQL, payloads - as one shaded monospace paragraph.

    Without this the converter silently DROPPED <pre>: it matched none of the
    branches in walk_block and fell off the end. A missing paragraph in a
    document being circulated for review is the worst kind of bug, because
    nothing announces it.

    One paragraph with explicit line breaks rather than one per line, so Word
    keeps it together and the shading reads as a single block.
    """
    text = raw_text(node)
    if not text:
        return
    p = doc.add_paragraph()
    pf = p.paragraph_format
    pf.left_indent = Inches(0.15)
    pf.space_before = Pt(6)
    pf.space_after = Pt(10)
    pf.line_spacing = 1.0
    lines = text.split("\n")
    for i, ln in enumerate(lines):
        if i:
            p.add_run().add_break()
        r = p.add_run(ln)
        r.font.name = "Consolas"
        r.font.size = Pt(7.5)
    # Shade the paragraph so it reads as a block, the same way the HTML does.
    pPr = p._p.get_or_add_pPr()
    shd = OxmlElement("w:shd")
    shd.set(qn("w:val"), "clear")
    shd.set(qn("w:fill"), "F4F6F8")
    pPr.append(shd)


def walk_block(node):
    for n in node.kids:
        tag, c = n.tag, cls(n)

        if tag == "header":
            eyebrow = next(find(n, lambda x: "eyebrow" in cls(x)), None)
            if eyebrow is not None:
                p = doc.add_paragraph()
                r = p.add_run(flat(eyebrow).upper())
                r.font.size = Pt(8)
                r.font.color.rgb = ACCENT
                r.bold = True
            h1 = next(find(n, lambda x: x.tag == "h1"), None)
            if h1 is not None:
                doc.add_heading(flat(h1), level=0)
            sf = next(find(n, lambda x: "standfirst" in cls(x)), None)
            if sf is not None:
                p = doc.add_paragraph()
                runs(sf, p)
                for r in p.runs:
                    r.font.size = Pt(11)
                    r.font.color.rgb = INK_SOFT
            meta = next(find(n, lambda x: "meta" in cls(x)), None)
            if meta is not None:
                bits = [flat(s) for s in meta.kids if s.tag == "span"]
                p = doc.add_paragraph()
                r = p.add_run("  |  ".join(bits))
                r.font.size = Pt(8.5)
                r.font.color.rgb = INK_SOFT
            continue

        if tag == "h2":
            doc.add_heading(re.sub(r"^\d+\s*", "", flat(n)), level=1)
        elif tag == "h3":
            doc.add_heading(flat(n), level=2)
        elif tag == "h4":
            doc.add_heading(flat(n), level=3)
        elif tag == "p":
            p = doc.add_paragraph()
            runs(n, p)
            if "why" in c or "lede" in c:
                for r in p.runs:
                    r.font.color.rgb = INK_SOFT
        elif tag in ("ul", "ol"):
            style = "List Bullet" if tag == "ul" else "List Number"
            for li in [k for k in n.kids if k.tag == "li"]:
                p = doc.add_paragraph(style=style)
                runs(li, p)
        elif tag == "img":
            add_image(n)
        elif tag == "figcaption":
            p = doc.add_paragraph()
            p.alignment = WD_ALIGN_PARAGRAPH.CENTER
            runs(n, p)
            for r in p.runs:
                r.font.size = Pt(8.5)
                r.italic = True
                r.font.color.rgb = INK_SOFT
        elif tag == "pre":
            add_pre(n)
        elif tag == "table":
            add_table(n)
        elif tag == "hr":
            doc.add_paragraph()
        elif tag == "div" and "note" in c:
            add_note(n)
        elif tag == "div" and "card" in c:
            walk_block(n)
        elif tag in ("div", "section", "figure"):
            walk_block(n)


walk_block(sheet)
doc.save(OUT)
print("wrote", OUT)
