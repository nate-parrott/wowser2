// CSS.escape per https://drafts.csswg.org/cssom/#serialize-an-identifier.
// Implemented locally (rather than calling window.CSS.escape) so the selector
// generator's pure functions can run under node for unit tests.
export function cssEscape(value: string): string {
    const length = value.length;
    let result = '';
    const firstCodeUnit = value.charCodeAt(0);

    if (length === 1 && firstCodeUnit === 0x002d) { // lone "-"
        return '\\' + value;
    }

    for (let index = 0; index < length; index++) {
        const codeUnit = value.charCodeAt(index);

        if (codeUnit === 0x0000) {
            result += '�';
            continue;
        }

        if (
            (codeUnit >= 0x0001 && codeUnit <= 0x001f) || codeUnit === 0x007f ||
            (index === 0 && codeUnit >= 0x0030 && codeUnit <= 0x0039) ||
            (index === 1 && codeUnit >= 0x0030 && codeUnit <= 0x0039 && firstCodeUnit === 0x002d)
        ) {
            result += '\\' + codeUnit.toString(16) + ' ';
            continue;
        }

        if (
            codeUnit >= 0x0080 || codeUnit === 0x002d || codeUnit === 0x005f ||
            (codeUnit >= 0x0030 && codeUnit <= 0x0039) ||
            (codeUnit >= 0x0041 && codeUnit <= 0x005a) ||
            (codeUnit >= 0x0061 && codeUnit <= 0x007a)
        ) {
            result += value.charAt(index);
            continue;
        }

        result += '\\' + value.charAt(index);
    }
    return result;
}

/** Escape a string for use inside a double-quoted attribute selector value. */
export function escapeAttrValue(value: string): string {
    return value
        .replace(/\\/g, '\\\\')
        .replace(/"/g, '\\"')
        .replace(/\n/g, '\\a ')
        .replace(/\r/g, '\\d ');
}
