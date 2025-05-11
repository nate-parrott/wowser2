export function scoreForClassName(className: string): number {
    // gibberish classes detract from score; non-gibberish classes increase it

    // If the class name is too short, it's probably not meaningful
    if (className.length < 2) {
        return -1;
    }

    // Check for common meaningful class name patterns
    if (/^(btn|button|nav|menu|header|footer|main|content|container|wrapper|row|col|column|title|heading|label|input|form|card|panel|section|item|list|link|icon|img|image|bg|background|text|font|color|size|flex|grid|layout|margin|padding|border|active|disabled|hidden|visible|selected|hover|focus)/.test(className)) {
        return 5;
    }

    // Check for semantic classes (good)
    if (/^[a-z]+(-[a-z]+)*$/.test(className)) { // kebab-case
        return 3;
    }

    if (/^[a-z][a-zA-Z0-9]*$/.test(className)) { // camelCase
        return 2;
    }

    // Check for common patterns that indicate generated/gibberish classes
    if (/^[a-zA-Z0-9]{5,}$/.test(className)) { // Long single strings without separators
        return -3;
    }

    if (/^_[a-zA-Z0-9]+_[a-zA-Z0-9]+/.test(className)) { // CSS modules pattern
        return -2;
    }

    if (/[0-9a-f]{4,}/.test(className)) { // Contains long hex-like substrings (likely hashes)
        return -4;
    }

    // Default
    return 0;
}
