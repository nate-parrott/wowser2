#!/usr/bin/env python3
"""Extract form-field descriptors from fetched HTML pages into a JSON fixture.

Mirrors the attributes the in-browser query collects (see AutofillFieldQuery
in Core), so the Swift classifier can be benchmarked offline against real
sites' markup.
"""
import glob, json, os, re, sys
from bs4 import BeautifulSoup, NavigableString, Tag

SITES_DIR = sys.argv[1]
OUT = sys.argv[2]

TEXT_TYPES = {"", "text", "email", "password", "tel", "search", "url", "number"}
SKIP_TYPES = {"hidden", "submit", "button", "checkbox", "radio", "file", "image", "reset", "range", "color", "date", "datetime-local", "month", "week", "time"}


def norm_ws(s):
    return re.sub(r"\s+", " ", s or "").strip()


def label_for(inp, soup):
    parts = []
    iid = inp.get("id")
    if iid:
        for lab in soup.find_all("label", attrs={"for": iid}):
            t = norm_ws(lab.get_text(" "))
            if t:
                parts.append(t)
    anc = inp.find_parent("label")
    if anc is not None:
        t = norm_ws(anc.get_text(" "))
        if t:
            parts.append(t)
    lb = inp.get("aria-labelledby")
    if lb:
        for ref in lb.split():
            el = soup.find(id=ref)
            if el is not None:
                t = norm_ws(el.get_text(" "))
                if t:
                    parts.append(t)
    return norm_ws(" ".join(dict.fromkeys(parts)))[:120]


def previous_text(inp):
    """Nearest short text before the input (walking back through siblings, then up)."""
    node = inp
    for _ in range(6):
        sib = node.previous_sibling
        while sib is not None:
            if isinstance(sib, NavigableString):
                t = norm_ws(str(sib))
                if t:
                    return t[:80]
            elif isinstance(sib, Tag):
                if sib.name in ("script", "style", "input", "select", "textarea", "button"):
                    sib = sib.previous_sibling
                    continue
                t = norm_ws(sib.get_text(" "))
                if t:
                    return t[-80:]
            sib = sib.previous_sibling
        node = node.parent
        if node is None or node.name in ("form", "body", "html"):
            break
    return ""


def describe(el, soup, form_index, field_index):
    tag = el.name
    typ = (el.get("type") or ("select" if tag == "select" else "text")).lower() if tag != "textarea" else "textarea"
    d = {
        "fieldIndex": field_index,
        "tag": tag,
        "type": typ,
        "name": el.get("name") or "",
        "id": el.get("id") or "",
        "autocomplete": (el.get("autocomplete") or "").lower(),
        "placeholder": norm_ws(el.get("placeholder")),
        "ariaLabel": norm_ws(el.get("aria-label")),
        "title": norm_ws(el.get("title")),
        "className": norm_ws(" ".join(el.get("class") or []))[:120],
        "label": label_for(el, soup),
        "previousText": previous_text(el),
        "maxLength": int(el.get("maxlength")) if (el.get("maxlength") or "").isdigit() else None,
        "readOnly": el.has_attr("readonly"),
        "disabled": el.has_attr("disabled"),
        "formIndex": form_index,
    }
    if tag == "select":
        opts = [norm_ws(o.get_text(" ")) for o in el.find_all("option")]
        d["optionCount"] = len(opts)
        d["optionSample"] = [o for o in opts if o][:6]
    return d


def main():
    fixtures = []
    for path in sorted(glob.glob(os.path.join(SITES_DIR, "*.html"))):
        try:
            html = open(path, "rb").read().decode("utf-8", "replace")
        except Exception:
            continue
        soup = BeautifulSoup(html, "lxml")
        for s in soup.find_all(["script", "style", "noscript", "template"]):
            s.decompose()
        all_fields = soup.find_all(["input", "textarea", "select"])
        fields = []
        forms = soup.find_all("form")
        form_ids = {id(f): i for i, f in enumerate(forms)}
        for idx, el in enumerate(all_fields):
            typ = (el.get("type") or "text").lower() if el.name == "input" else el.name
            if el.name == "input" and typ in SKIP_TYPES:
                continue
            form = el.find_parent("form")
            fi = form_ids.get(id(form)) if form is not None else None
            fields.append(describe(el, soup, fi, idx))
        if not fields:
            continue
        # form context
        by_form = {}
        for f in fields:
            by_form.setdefault(f["formIndex"], []).append(f)
        for fi, fs in by_form.items():
            pw = [f for f in fs if f["type"] == "password"]
            textish = [f for f in fs if f["tag"] == "input" and f["type"] in TEXT_TYPES]
            for i, f in enumerate(fs):
                f["formHasPassword"] = len(pw) > 0
                f["passwordFieldCount"] = len(pw)
                f["indexInForm"] = i
                f["textFieldCountInForm"] = len(textish)
        name = os.path.basename(path)[:-5]
        fixtures.append({"site": name, "fields": fields})
    json.dump(fixtures, open(OUT, "w"), indent=1)
    print(f"{len(fixtures)} pages, {sum(len(f['fields']) for f in fixtures)} fields -> {OUT}")


main()
