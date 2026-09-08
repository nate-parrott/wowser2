import { isStyleClassName } from "./styleSelectors";
import { ClassStats, isHashedClassName } from "./classHashing";

export const SCORING = {
    TERM_PENALITY: -2, // Discourage unnecessarily long selectors (which are unnecessarily fragile)

    SEMANTIC_CLASS: 4,
    RANDOM_CLASS: -2,
    // Generated/hashed classes (see classHashing.ts) will break on the next deploy:
    // rank them below even a bare attribute.
    HASH_CLASS: -4,

    ID: 10,

    // Synthetic computed-style classes (`.__sss__...`): strong signal, but below an ID.
    STYLE_CLASS: 7,

    SEMANTIC_ATTR: 6,
    RANDOM_ATTR: -1,

    NTH_CHILD: 0,

    // `:has(...)` adds structure the page author probably meant; slight penalty on
    // top of the child term's own score so it only wins when the child is semantic.
    HAS_PENALTY: -1,

    SEMANTIC_TAG: 1,
    RANDOM_TAG: -1,
};

const SEMANTIC_TAGS = new Set<string>([ 'a', 'button', 'input', 'select', 'textarea', 'label', 'form', 'nav', 'header', 'footer', 'main', 'section', 'article', 'aside', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6' ]);
export function scoreForTag(tag: string): number {
    return SEMANTIC_TAGS.has(tag.toLowerCase()) ? SCORING.SEMANTIC_TAG : SCORING.RANDOM_TAG;
}

export function scoreForAttr(name: string, hasValue: boolean): number {
    if (hasValue && (name === 'role' || name === 'aria-role' || name === 'aria-label')) {
        return SCORING.SEMANTIC_ATTR;
    }
    return SCORING.RANDOM_ATTR;
}

export function scoreForClassName(className: string, stats?: ClassStats): number {
    if (isStyleClassName(className)) {
        return SCORING.STYLE_CLASS;
    }

    if (isHashedClassName(className, stats)) {
        return SCORING.HASH_CLASS;
    }

    // gibberish classes detract from score; non-gibberish classes increase it

    // If the class name is too short, it's probably not meaningful
    if (className.length < 2) {
        return SCORING.RANDOM_CLASS;
    }

    // Check for common meaningful class name patterns
    if (/^(btn|button|nav|menu|header|footer|main|content|container|wrapper|row|col|column|title|heading|label|input|form|card|panel|section|item|list|link|icon|img|image|bg|background|text|font|color|size|flex|grid|layout|margin|padding|border|active|disabled|hidden|visible|selected|hover|focus)/.test(className)) {
        return SCORING.SEMANTIC_CLASS;
    }

    // Check for semantic classes (good)
    if (/^[a-z]+(-[a-z]+)*$/.test(className)) { // kebab-case
        return SCORING.SEMANTIC_CLASS;
    }

    if (/^[a-z][a-zA-Z0-9]*$/.test(className)) { // camelCase
        return SCORING.SEMANTIC_CLASS;
    }

    // Check for common patterns that indicate generated/gibberish classes
    if (/^[a-zA-Z0-9]{5,}$/.test(className)) { // Long single strings without separators
        return SCORING.RANDOM_CLASS;
    }

    if (/^_[a-zA-Z0-9]+_[a-zA-Z0-9]+/.test(className)) { // CSS modules pattern
        return SCORING.RANDOM_CLASS;
    }

    if (/[0-9a-f]{4,}/.test(className)) { // Contains long hex-like substrings (likely hashes)
        return SCORING.RANDOM_CLASS;
    }

    // Default
    return 0;
}
