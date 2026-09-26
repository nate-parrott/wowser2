# Autofill field-detection benchmark

`AutofillFieldClassifier` (Core/Autofill) decides what each form field is for
from its markup. `AutofillClassifierTests` runs it over
`Core/Tests/CoreTests/Fixtures/autofill/*.json` and asserts zero false fills
(never offer an address in a search box) and ≥97% overall accuracy.

The fixtures were built like this:

1. Fetch sign-in / sign-up / checkout pages as served (curl with a Safari UA)
   into a folder of `.html` files. Many big-name logins are JS-rendered and
   come back empty; those are covered by `reconstructed.py` instead.
2. `python3 extract_fields.py <html-dir> raw_fields.json` — pulls every
   `input`/`textarea`/`select` with the same attributes the in-browser query
   (`AutofillFieldQuery`) collects: name, id, type, autocomplete, placeholder,
   aria-label, `<label>` text, nearby text, and form context (does the form
   have a password field, how many, position). Needs `beautifulsoup4` + `lxml`.
3. `python3 annotate.py raw_fields.json fetched_sites.json` — attaches the
   hand-annotated expected kinds (edit the table in the script). `expected`
   is a list; several entries mark genuinely ambiguous fields ("Email or
   username"). `"none"` means "must not autofill".
4. `python3 reconstructed.py reconstructed_sites.json` — forms written down
   from well-known markup (Shopify / Stripe / Amazon address forms, Google,
   Apple, Microsoft, X, GitHub logins, French / Spanish / German forms, and a
   set of tricky negatives).

Copy both JSON files into `Core/Tests/CoreTests/Fixtures/autofill/` and run
the Core tests. Current score: 411/411 (289 fetched + 122 reconstructed).
