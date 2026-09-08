import test from 'node:test';
import assert from 'node:assert/strict';
import * as H from '../src/classHashing';
import { scoreForClassName, scoreForAttr, SCORING } from '../src/scoring';
import { termToString } from '../src/selectorGen';

test('known framework patterns', () => {
    for (const c of ['r-qklmqi', 'r-1habvwh', 'x1a2b3c', 'css-1abc2d', 'sc-AbCdEf', 'jsx-1234', 'Button_root__a1B2c', '_abc123']) {
        assert.ok(H.matchesKnownHashPattern(c), c);
    }
    for (const c of ['btn-primary', 'nav', 'container', 'md-flex', 'col-12']) {
        assert.ok(!H.matchesKnownHashPattern(c), c);
    }
});

test('gibberish heuristic', () => {
    assert.ok(H.looksGibberish('qklmqi'));     // consonant run
    assert.ok(H.looksGibberish('1habvwh'));    // digit then letter
    assert.ok(H.looksGibberish('AbCdEf'));     // case alternation
    for (const w of ['primary', 'strong', 'strength', 'wrapper', 'html', 'col12', 'h1', 'iPhone', 'dropdown', 'timeline']) {
        assert.ok(!H.looksGibberish(w), w);
    }
});

test('shape keys', () => {
    assert.equal(H.shapeKey('r-qklmqi'), 'r-{6}');
    assert.equal(H.shapeKey('btn-primary'), 'btn-{7}');
    assert.equal(H.shapeKey('x1a2b3c'), 'x{6}');
    assert.equal(H.shapeKey('Button_root__a1B2c'), 'Button_root__{5}');
});

function fakeAtomicSoup(n: number): string[] {
    // deterministic pseudo-random base36 suffixes like Twitter's r-* classes
    const out: string[] = [];
    let seed = 12345;
    for (let i = 0; i < n; i++) {
        let s = '';
        for (let j = 0; j < 6; j++) { seed = (seed * 1103515245 + 12345) & 0x7fffffff; s += (seed % 36).toString(36); }
        out.push('q-' + s); // unknown prefix: not in the known-pattern list
    }
    return out;
}

test('document-level family detection catches innocent-looking members', () => {
    const soup = fakeAtomicSoup(60);
    const stats = H.buildClassStatsFromNames([...soup, 'q-bcqeeo', 'btn-primary', 'btn-success', 'btn-danger', 'nav-item', 'nav-link']);
    assert.ok(!H.looksGibberish('bcqeeo'), 'precondition: individually innocent');
    assert.ok(H.inHashedFamily('q-bcqeeo', stats), 'but its family is hashed');
    assert.ok(!H.inHashedFamily('btn-primary', stats));
    assert.ok(H.isHashedClassName('q-bcqeeo', stats));
    assert.ok(!H.isHashedClassName('btn-primary', stats));
});

test('small families of real words are not flagged', () => {
    const names: string[] = [];
    for (let i = 1; i <= 12; i++) names.push('col-' + i);
    names.push('container', 'dropdown', 'timeline', 'wrapper', 'sidebar', 'headline', 'subtitle', 'carousel', 'offcanvas', 'breadcrumb', 'pagination', 'accordion', 'collapsed', 'highlight');
    const stats = H.buildClassStatsFromNames(names);
    for (const n of names) assert.ok(!H.isHashedClassName(n, stats), n);
});

test('hashed classes score below a bare attribute', () => {
    assert.equal(scoreForClassName('r-qklmqi'), SCORING.HASH_CLASS);
    assert.ok(scoreForClassName('r-qklmqi') < scoreForAttr('aria-labelledby', false));
    assert.equal(scoreForClassName('nav-item'), SCORING.SEMANTIC_CLASS);
});

test('direct-child combinator gets a space', () => {
    assert.equal(termToString({ directChild: true, hasAttr: 'aria-label', attrVal: 'Timeline' }), '> [aria-label="Timeline"]');
});

test(':has terms render with inner combinator', () => {
    assert.equal(termToString({ tag: 'article', has: [{ tag: 'h2', directChild: true }] }), 'article:has(> h2)');
    assert.equal(termToString({ className: 'card', has: [{ hasAttr: 'role', attrVal: 'button' }] }), '.card:has([role="button"])');
});
