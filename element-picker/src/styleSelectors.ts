// "Style selectors" (SSS): synthetic class-like selectors that target elements by
// computed text / border / background style instead of DOM attributes.
//
// Syntax: `.__sss__<kind>__<field>__<field>...`, e.g.
//   .__sss__text__#00f__500__72__Comic_Sans_MS     (color, weight, size, family)
//   .__sss__font__500__72__Comic_Sans_MS           (weight, size, family)
//   .__sss__border__#000__1__none                  (border color, border width, box shadow)
//   .__sss__bg__#fff                               (background color)
//
// Fields are opaque tokens drawn from [A-Za-z0-9#-] plus single underscores; `__`
// separates fields. Tokens are compared only for equality, never decoded.
//
// These are NOT valid CSS. To resolve a selector containing them, compute the token
// for each candidate element, temporarily add the token as a class to elements whose
// token matches, rewrite the selector so the token is a properly escaped class, run
// querySelectorAll, then remove the temporary classes.
import { cssEscape } from './cssEscape';

export const SSS_PREFIX = '__sss__';
export type StyleKind = 'text' | 'font' | 'border' | 'bg';
export const STYLE_KINDS: StyleKind[] = ['text', 'font', 'border', 'bg'];

const TOKEN_RE = /\.__sss__[A-Za-z0-9_#-]+/g;

export function isStyleClassName(className: string): boolean {
    return className.startsWith(SSS_PREFIX);
}

export function hasStyleSelectors(selector: string): boolean {
    return selector.indexOf('.' + SSS_PREFIX) !== -1;
}

/** Kind encoded in a token (class name form, without leading dot), or null. */
export function tokenKind(token: string): StyleKind | null {
    if (!isStyleClassName(token)) return null;
    const kind = token.slice(SSS_PREFIX.length).split('__')[0];
    return (STYLE_KINDS as string[]).indexOf(kind) !== -1 ? (kind as StyleKind) : null;
}

export interface ParsedStyleSelector {
    /** Unique SSS class names (no leading dot) present in the selector. */
    tokens: string[];
    /** The selector with each SSS token rewritten as an escaped class, valid for querySelectorAll once temp classes are applied. */
    queryable: string;
}

export function parseStyleSelector(selector: string): ParsedStyleSelector {
    const tokens: string[] = [];
    const queryable = selector.replace(TOKEN_RE, (match) => {
        const token = match.slice(1);
        if (tokens.indexOf(token) === -1) tokens.push(token);
        return '.' + cssEscape(token);
    });
    return { tokens, queryable };
}

/** Rewrite for querySelectorAll. Identity for plain CSS selectors. */
export function toQueryable(selector: string): string {
    return hasStyleSelectors(selector) ? parseStyleSelector(selector).queryable : selector;
}

// MARK: - Field encoding

const RGB_RE = /^rgba?\(\s*([\d.]+)\s*,?\s*([\d.]+)\s*,?\s*([\d.]+)\s*(?:[,/]\s*([\d.]+%?)\s*)?\)$/;

/** Parse `rgb()` / `rgba()` (comma or space syntax) into 0-255 channels + 0-1 alpha. */
export function parseRGB(css: string): { r: number; g: number; b: number; a: number } | null {
    const m = RGB_RE.exec(css.trim());
    if (!m) return null;
    let a = 1;
    if (m[4] !== undefined) {
        a = m[4].endsWith('%') ? parseFloat(m[4]) / 100 : parseFloat(m[4]);
    }
    return { r: parseFloat(m[1]), g: parseFloat(m[2]), b: parseFloat(m[3]), a };
}

/** `rgb(r, g, b)` / `rgba(r, g, b, a)` → `#rgb` / `#rrggbb` / `#rrggbbaa`; null if unparseable. */
export function colorToHex(css: string): string | null {
    const c = parseRGB(css);
    if (!c) return null;
    const ch = (n: number) => Math.max(0, Math.min(255, Math.round(n))).toString(16).padStart(2, '0');
    let hex = ch(c.r) + ch(c.g) + ch(c.b);
    if (c.a < 1) {
        hex += ch(c.a * 255);
    } else if (hex[0] === hex[1] && hex[2] === hex[3] && hex[4] === hex[5]) {
        hex = hex[0] + hex[2] + hex[4];
    }
    return '#' + hex;
}

export function isTransparent(css: string): boolean {
    const c = css.trim();
    if (!c || c === 'transparent' || c === 'none') return true;
    const rgb = parseRGB(c);
    return rgb !== null && rgb.a === 0;
}

/** Collapse any CSS value into the token alphabet. Never empty. */
export function sanitizeField(value: string): string {
    const s = value
        .trim()
        .replace(/[^A-Za-z0-9#-]+/g, '_')
        .replace(/_+/g, '_')
        .replace(/^_|_$/g, '');
    return s || 'none';
}

export function colorField(css: string): string {
    return colorToHex(css) || sanitizeField(css);
}

/** `72px` → `72`, `13.33px` → `13_33`. */
export function lengthField(css: string): string {
    const n = parseFloat(css);
    if (isNaN(n)) return sanitizeField(css);
    return sanitizeField(String(Math.round(n * 100) / 100));
}

/** First family of a font-family list, unquoted. */
export function fontFamilyField(css: string): string {
    const first = css.split(',')[0] || '';
    return sanitizeField(first.replace(/^\s*["']|["']\s*$/g, ''));
}

/** Box shadow with colors hex-encoded and `px` units dropped. */
export function shadowField(css: string): string {
    const s = css
        .replace(/rgba?\([^)]*\)/g, (m) => colorToHex(m) || m)
        .replace(/(\d)px\b/g, '$1');
    return sanitizeField(s);
}

export function makeToken(kind: StyleKind, fields: string[]): string {
    return SSS_PREFIX + kind + '__' + fields.join('__');
}

// MARK: - DOM

export function hasDirectText(el: Element): boolean {
    const nodes = el.childNodes;
    for (let i = 0; i < nodes.length; i++) {
        const n = nodes[i];
        if (n.nodeType === 3 && (n.textContent || '').trim().length > 0) return true;
    }
    return false;
}

export type StyleTokens = Partial<Record<StyleKind, string>>;

/** Style tokens this element would carry, restricted to `kinds`. */
export function styleTokensForElement(el: Element, kinds: StyleKind[], computed?: CSSStyleDeclaration): StyleTokens {
    const cs = computed || getComputedStyle(el);
    const out: StyleTokens = {};
    const wantsText = kinds.indexOf('text') !== -1 || kinds.indexOf('font') !== -1;

    if (wantsText && hasDirectText(el)) {
        const weight = sanitizeField(cs.fontWeight);
        const size = lengthField(cs.fontSize);
        const family = fontFamilyField(cs.fontFamily);
        if (kinds.indexOf('text') !== -1) {
            out.text = makeToken('text', [colorField(cs.color), weight, size, family]);
        }
        if (kinds.indexOf('font') !== -1) {
            out.font = makeToken('font', [weight, size, family]);
        }
    }

    if (kinds.indexOf('border') !== -1) {
        const width = parseFloat(cs.borderTopWidth) || 0;
        const hasBorder = width > 0 && !isTransparent(cs.borderTopColor);
        const hasShadow = !!cs.boxShadow && cs.boxShadow !== 'none';
        if (hasBorder || hasShadow) {
            out.border = makeToken('border', [
                hasBorder ? colorField(cs.borderTopColor) : 'none',
                hasBorder ? lengthField(cs.borderTopWidth) : '0',
                hasShadow ? shadowField(cs.boxShadow) : 'none',
            ]);
        }
    }

    if (kinds.indexOf('bg') !== -1 && !isTransparent(cs.backgroundColor)) {
        out.bg = makeToken('bg', [colorField(cs.backgroundColor)]);
    }

    return out;
}

function kindsOf(tokens: string[]): StyleKind[] {
    const kinds: StyleKind[] = [];
    for (const t of tokens) {
        const k = tokenKind(t);
        if (k && kinds.indexOf(k) === -1) kinds.push(k);
    }
    return kinds;
}

/**
 * Temporarily add each of `tokens` as a class to every element in `scope` whose
 * computed style produces that token, run `fn`, then remove the classes.
 * Reads are batched before writes so we don't thrash style recalculation.
 */
export function withStyleClassesApplied<T>(tokens: string[], scope: Iterable<Element> | ArrayLike<Element>, fn: () => T): T {
    const kinds = kindsOf(tokens);
    if (kinds.length === 0) return fn();
    const wanted = new Set(tokens);
    const additions: [Element, string][] = [];

    const elements = Array.from(scope as ArrayLike<Element>);
    for (const el of elements) {
        const toks = styleTokensForElement(el, kinds);
        for (const k of kinds) {
            const tok = toks[k];
            if (tok && wanted.has(tok) && !el.classList.contains(tok)) {
                additions.push([el, tok]);
            }
        }
    }
    for (const [el, tok] of additions) el.classList.add(tok);
    try {
        return fn();
    } finally {
        for (const [el, tok] of additions) el.classList.remove(tok);
    }
}

/** Elements with a nonzero box intersecting the viewport. */
export function onscreenElements(root: ParentNode = document): Element[] {
    const vw = window.innerWidth, vh = window.innerHeight;
    const result: Element[] = [];
    const all = root.querySelectorAll('*');
    for (let i = 0; i < all.length; i++) {
        const el = all[i];
        const r = el.getBoundingClientRect();
        if (r.width > 0 && r.height > 0 && r.bottom > 0 && r.right > 0 && r.top < vh && r.left < vw) {
            result.push(el);
        }
    }
    return result;
}

/**
 * Resolve a (possibly augmented) selector to matching elements.
 * Plain CSS takes the hot path; style selectors are matched against onscreen elements only.
 */
export function resolveAugmentedSelector(selector: string): Element[] {
    if (!hasStyleSelectors(selector)) {
        return Array.from(document.querySelectorAll(selector));
    }
    const { tokens, queryable } = parseStyleSelector(selector);
    return withStyleClassesApplied(tokens, onscreenElements(), () => Array.from(document.querySelectorAll(queryable)));
}
