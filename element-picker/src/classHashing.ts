// Detection of generated / hashed class names (atomic CSS, CSS modules, emotion,
// styled-components, Twitter `r-xxxxxx`, Facebook `x1a2b3c`, ...). These change on
// every deploy, so selectors built on them are worthless. Three layers:
//
// 1. Known-framework patterns (cheap, precise, brittle).
// 2. A per-segment gibberish heuristic (digits mixed into letters, long consonant
//    runs, rapid case alternation).
// 3. Document-level shape statistics: hashed systems produce many distinct classes
//    sharing a prefix and a same-length random suffix (`r-{6}`, `x{7}`, `css-{7}`).
//    A family with many members, most of which look gibberish, is hashed — this
//    catches members that individually look innocent (`r-bcqeeo`).

const KNOWN_HASH_PATTERNS: RegExp[] = [
    /^r-[a-z0-9]{5,}$/,                 // Twitter / X
    /^x[a-z0-9]{5,}$/,                  // Facebook / Meta stylex
    /^css-[a-z0-9]{5,}$/,               // emotion
    /^sc-[A-Za-z0-9]{5,}$/,             // styled-components
    /^jsx-\d+$/,                        // styled-jsx
    /^[A-Za-z0-9]+_[A-Za-z0-9]+__[A-Za-z0-9]{5,}$/, // CSS modules `Button_root__a1B2c`
    /^_[a-z0-9]{5,}$/,                  // CSS modules (hash-only)
    /^[a-z]+-[a-z0-9]*[0-9][a-z0-9]*-[a-z0-9]+$/, // `foo-1a2b-3c4d` style
];

export function matchesKnownHashPattern(className: string): boolean {
    return KNOWN_HASH_PATTERNS.some(re => re.test(className));
}

/** Split on `-` / `_` boundaries into the segments a human would read. */
export function segments(className: string): string[] {
    return className.split(/[-_]+/).filter(s => s.length > 0);
}

/** Does a single segment look like a random token rather than a word? */
export function looksGibberish(segment: string): boolean {
    if (segment.length < 4) return false;
    // Digit immediately followed by a letter: `1habvwh`, `x1a2b3c`. (`col12`, `h1` are fine.)
    if (/[0-9][a-z]/i.test(segment)) return true;
    // Five or more consonants in a row (y counts as a vowel): `qklmqi`, `dnmrzs`.
    if (/[bcdfghjklmnpqrstvwxz]{5}/i.test(segment)) return true;
    // Rapid case alternation: `AbCdE`, `fGhIj`.
    const switches = (segment.match(/[a-z][A-Z]|[A-Z][a-z]/g) || []).length;
    if (switches >= 3) return true;
    return false;
}

/** Any segment gibberish ⇒ the class is. */
export function classLooksGibberish(className: string): boolean {
    return segments(className).some(looksGibberish);
}

/**
 * Shape key: the class with its final segment replaced by `{length}`.
 * `r-qklmqi` → `r-{6}`, `btn-primary` → `btn-{7}`, `x1a2b3c` → `x{7}`.
 * Classes without a separator keep their first character as the "prefix".
 */
export function shapeKey(className: string): string {
    const m = /^(.*?)([A-Za-z0-9]+)$/.exec(className);
    if (!m) return className;
    const prefix = m[1], last = m[2];
    if (prefix.length === 0) {
        return last.charAt(0) + '{' + (last.length - 1) + '}';
    }
    return prefix + '{' + last.length + '}';
}

export interface ClassStats {
    /** shape → number of distinct class names with that shape */
    members: Map<string, number>;
    /** shape → how many of those members look gibberish */
    gibberish: Map<string, number>;
}

export const HASH_FAMILY_MIN_MEMBERS = 12;
export const HASH_FAMILY_MIN_GIBBERISH_FRACTION = 0.4;

export function buildClassStatsFromNames(classNames: Iterable<string>): ClassStats {
    const seen = new Set<string>();
    const members = new Map<string, number>();
    const gibberish = new Map<string, number>();
    for (const name of classNames) {
        if (seen.has(name)) continue;
        seen.add(name);
        const key = shapeKey(name);
        members.set(key, (members.get(key) || 0) + 1);
        if (classLooksGibberish(name)) {
            gibberish.set(key, (gibberish.get(key) || 0) + 1);
        }
    }
    return { members, gibberish };
}

export function buildClassStats(root: ParentNode): ClassStats {
    const names: string[] = [];
    const els = root.querySelectorAll('[class]');
    for (let i = 0; i < els.length; i++) {
        const list = els[i].classList;
        for (let j = 0; j < list.length; j++) names.push(list[j]);
    }
    return buildClassStatsFromNames(names);
}

export function inHashedFamily(className: string, stats: ClassStats): boolean {
    const key = shapeKey(className);
    const n = stats.members.get(key) || 0;
    if (n < HASH_FAMILY_MIN_MEMBERS) return false;
    return (stats.gibberish.get(key) || 0) / n >= HASH_FAMILY_MIN_GIBBERISH_FRACTION;
}

/** Combined verdict: is this class name likely to change on the next deploy? */
export function isHashedClassName(className: string, stats?: ClassStats): boolean {
    if (matchesKnownHashPattern(className)) return true;
    if (classLooksGibberish(className)) return true;
    if (stats && inHashedFamily(className, stats)) return true;
    return false;
}
