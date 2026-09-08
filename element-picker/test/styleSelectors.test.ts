import test from 'node:test';
import assert from 'node:assert/strict';
import { cssEscape, escapeAttrValue } from '../src/cssEscape';
import { termToString } from '../src/selectorGen';
import { scoreForClassName, SCORING } from '../src/scoring';
import * as S from '../src/styleSelectors';

test('ids starting with a digit are escaped', () => {
    assert.equal(termToString({ id: '49487341' }), '#\\34 9487341');
    assert.equal(cssEscape('-1'), '-\\31 ');
    assert.equal(cssEscape('a b'), 'a\\ b');
});

test('class names and attribute names/values are escaped', () => {
    assert.equal(termToString({ className: 'md:flex' }), '.md\\:flex');
    assert.equal(termToString({ hasAttr: '@click' }), '[\\@click]');
    assert.equal(termToString({ hasAttr: 'title', attrVal: 'say "hi"' }), '[title="say \\"hi\\""]');
    assert.equal(escapeAttrValue('a\\b'), 'a\\\\b');
});

test('style class names are emitted verbatim', () => {
    const tok = S.makeToken('text', ['#00f', '500', '72', 'Comic_Sans_MS']);
    assert.equal(tok, '__sss__text__#00f__500__72__Comic_Sans_MS');
    assert.equal(termToString({ className: tok }), '.' + tok);
    assert.equal(termToString({ tag: 'span', className: tok, directChild: true }), '> span.' + tok);
});

test('style classes score highly but below IDs', () => {
    const score = scoreForClassName('__sss__bg__#fff');
    assert.equal(score, SCORING.STYLE_CLASS);
    assert.ok(score > SCORING.SEMANTIC_CLASS);
    assert.ok(score < SCORING.ID);
});

test('parseStyleSelector extracts tokens and produces queryable CSS', () => {
    const sel = 'div.card > .__sss__text__#00f__500__72__Comic_Sans_MS, .__sss__bg__#fff:nth-child(2)';
    const { tokens, queryable } = S.parseStyleSelector(sel);
    assert.deepEqual(tokens, ['__sss__text__#00f__500__72__Comic_Sans_MS', '__sss__bg__#fff']);
    assert.equal(queryable, 'div.card > .__sss__text__\\#00f__500__72__Comic_Sans_MS, .__sss__bg__\\#fff:nth-child(2)');
    assert.equal(S.tokenKind(tokens[0]), 'text');
    assert.equal(S.tokenKind(tokens[1]), 'bg');
    assert.equal(S.tokenKind('__sss__nope__x'), null);
});

test('plain selectors are untouched', () => {
    assert.equal(S.hasStyleSelectors('div#a > .b'), false);
    assert.equal(S.toQueryable('div#a > .b'), 'div#a > .b');
    assert.deepEqual(S.parseStyleSelector('.b').tokens, []);
});

test('color encoding', () => {
    assert.equal(S.colorToHex('rgb(0, 0, 255)'), '#00f');
    assert.equal(S.colorToHex('rgb(18, 52, 86)'), '#123456');
    assert.equal(S.colorToHex('rgba(0, 0, 0, 0.5)'), '#00000080');
    assert.equal(S.colorToHex('rgb(0 0 0 / 50%)'), '#00000080');
    assert.equal(S.colorToHex('color(srgb 1 0 0)'), null);
    assert.equal(S.colorField('color(srgb 1 0 0)'), 'color_srgb_1_0_0');
    assert.equal(S.isTransparent('rgba(0, 0, 0, 0)'), true);
    assert.equal(S.isTransparent('transparent'), true);
    assert.equal(S.isTransparent('rgb(255, 255, 255)'), false);
    // Regression: a trailing 0 channel must not be mistaken for alpha 0.
    assert.equal(S.isTransparent('rgb(255, 0, 0)'), false);
    assert.equal(S.isTransparent('rgb(0, 0, 0)'), false);
    assert.equal(S.isTransparent('rgb(0 0 0 / 0)'), true);
});

test('field encoding stays inside the token alphabet', () => {
    assert.equal(S.lengthField('72px'), '72');
    assert.equal(S.lengthField('13.333px'), '13_33');
    assert.equal(S.fontFamilyField('"Comic Sans MS", cursive'), 'Comic_Sans_MS');
    assert.equal(S.fontFamilyField('-apple-system, sans-serif'), '-apple-system');
    assert.equal(S.shadowField('rgba(0, 0, 0, 0.2) 0px 2px 4px 0px'), '#00000033_0_2_4_0');
    assert.equal(S.sanitizeField('   '), 'none');
    for (const f of [S.lengthField('1.5px'), S.fontFamilyField('"A  B__C"'), S.shadowField('rgb(1,2,3) -1px 2px')]) {
        assert.match(f, /^[A-Za-z0-9#-]+(_[A-Za-z0-9#-]+)*$/, f);
    }
});

test('token round-trip through parse', () => {
    const tok = S.makeToken('border', ['#000', '1', S.shadowField('rgba(0, 0, 0, 0.2) 0px 2px 4px 0px')]);
    const { tokens } = S.parseStyleSelector('.' + tok + ' > a');
    assert.deepEqual(tokens, [tok]);
});
