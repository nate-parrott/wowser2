import { scoreForClassName } from "./gibberish";

// Our candidates have at most 3 terms
interface Candidate {
    terms: Term[]; // first is highest in the tree, bottom is original
    // hasTerms: Term[]; // for :has selectors; Do not implement yet

    topMatch: HTMLElement // the element corresponding to the highest parent we've traversed (or self)

    score: number; // higher is better. Bump the score for good terms; reduce it for bad terms
    matchCount: number;
}

interface Term {
    tag?: string;
    className?: string;
    id?: string;
    
    hasAttr?: string;
    attrVal?: string;

    lastChild?: boolean;
    nthChild?: number;

    directChild?: boolean; // do we prepend > before this term?
} 

function termToString(term: Term): string {
    let selectors: string[] = [];

    if (term.directChild) {
        selectors.push('>');
    }

    if (term.tag) {
        selectors.push(term.tag);
    } else if (!term.className && !term.id && !term.hasAttr) {
        selectors.push('*');
    }

    if (term.id) {
        selectors.push(`#${term.id}`);
    }

    if (term.className) {
        selectors.push(`.${term.className}`);
    }

    if (term.hasAttr) {
        if (term.attrVal) {
            selectors.push(`[${term.hasAttr}="${term.attrVal}"]`);
        } else {
            selectors.push(`[${term.hasAttr}]`);
        }
    }

    if (term.nthChild) {
        selectors.push(`:nth-child(${term.nthChild})`);
    } else if (term.lastChild) {
        selectors.push(':last-child');
    }

    return selectors.join('');
}

function candidateToString(cand: Candidate): string {
    return cand.terms.map(term => termToString(term)).join(' ');
}

function matchCount(terms: Term[]): number {
    let sel = terms.map(t => termToString(t)).join(' ');
    return document.querySelectorAll(sel).length;
}

function scoreForAttr(name: string): number {
    if (name === 'role' || name === 'aria-role' || name === 'aria-label') {
        return 5;
    }
    return 1;
}

const TERM_PENALTY = -1; // subtract 1 from score per additional term

function baseCandidates(element: HTMLElement): Candidate[] {
    const candidates: Candidate[] = [];

    function addCandidate(terms: Term[], score: number): void {
        candidates.push({
            terms,
            topMatch: element,
            score,
            matchCount: matchCount(terms),
        });
    }

    if (element.tagName === 'BODY') {
        // Only one candidate for body
        const bodyTerm: Term = {
            tag: 'body'
        };
        addCandidate([bodyTerm], 1);
        return candidates;
    }

    // Tag candidate
    if (element.tagName) {
        const tagTerm: Term = {
            tag: element.tagName.toLowerCase()
        };
        addCandidate([tagTerm], 1);

        const siblingCount = element.parentElement?.children.length || 0;
        const nth = Array.from(element.parentElement?.children || []).indexOf(element);
        if (nth !== -1) {
            // Push a nth-child option
            addCandidate([{...tagTerm, nthChild: nth + 1}], 2);
            if (nth === siblingCount - 1) {
                // Push a last-child option
                const lastChildTerm: Term = {
                    ...tagTerm,
                    lastChild: true
                };
                addCandidate([lastChildTerm], 3);
            }
        }
    }

    // ID candidate (usually unique and preferred)
    if (element.id) {
        const idTerm: Term = {
            id: element.id
        };
        addCandidate([idTerm], 10);
    }

    // Class candidates (add one candidate per class)
    if (element.classList && element.classList.length > 0) {
        Array.from(element.classList).forEach(className => {
            const classTerm: Term = {
                className: className
            };
            addCandidate([classTerm], 2 + scoreForClassName(className));
        });
    }

    // Attribute candidates
    if (element.attributes && element.attributes.length > 0) {
        Array.from(element.attributes)
            .filter(attr => attr.name !== 'id' && attr.name !== 'class') // Skip id and class as they're handled above
            .forEach(attr => {
                // Create a term with just the attribute presence
                const attrTerm: Term = {
                    hasAttr: attr.name
                };
                addCandidate([attrTerm], scoreForAttr(attr.name));

                // Create a term with specific attribute value if it exists
                if (attr.value) {
                    const attrValTerm: Term = {
                        hasAttr: attr.name,
                        attrVal: attr.value
                    };
                    addCandidate([attrValTerm], scoreForAttr(attr.name) + 1); // Extra point for value specificity
                }
            });
    }

    return candidates;
}

function reduceCandidateCount(cands: Candidate[]): Candidate[] {
    const maxMatchCount = 4000;
    const keepCandidates = 40;
    const buckets = 10;

    // Step 1: Filter out candidates with too many matches
    cands = cands.filter(x => x.matchCount <= maxMatchCount);
    if (cands.length <= keepCandidates) {
        return cands;
    }

    // Step 2: Find the max log value
    const maxLogValue = Math.log2(Math.max(...cands.map(c => Math.max(1, c.matchCount))));
    const bucketInterval = maxLogValue / buckets;

    // Step 3: Create buckets
    const bucketsArray: Candidate[][] = Array(buckets).fill(null).map(() => []);

    // Step 4: Assign candidates to buckets based on log2 of match count
    cands.forEach(candidate => {
        const logValue = Math.log2(Math.max(1, candidate.matchCount));
        const bucketIndex = Math.min(buckets - 1, Math.floor(logValue / bucketInterval));
        bucketsArray[bucketIndex].push(candidate);
    });

    // Step 5: Sort each bucket by score
    bucketsArray.forEach(bucket => {
        bucket.sort((a, b) => b.score - a.score);
    });

    // Step 6: Take an equal number from each non-empty bucket
    const itemsPerBucket = Math.ceil(keepCandidates / buckets);

    const result: Candidate[] = [];
    bucketsArray.forEach(bucket => {
        result.push(...bucket.slice(0, itemsPerBucket));
    });

    // Step 7: If we have too many, sort by score and trim
    if (result.length > keepCandidates) {
        result.sort((a, b) => b.score - a.score);
        return result.slice(0, keepCandidates);
    }

    return result;
}

const DEBUG = true;

function expandCandidate(candidate: Candidate, seenSelectorsToSkip: {[id: string]: true}, origElement: HTMLElement): Candidate[] {
    const result: Candidate[] = [];
    const currentElement = candidate.topMatch as HTMLElement;

    // 1. Walk up parent chain (up to 3 levels)
    const parents: HTMLElement[] = [];
    let parent = currentElement.parentElement;

    for (let i = 0; i < 3; i++) {
        if (!parent) break;
        parents.push(parent);
        if (parent.tagName === 'BODY') { break; }
        parent = parent.parentElement;
    }

    // Process each parent level
    for (let i = 0; i < parents.length; i++) {
        const currentParent = parents[i];
        const parentCandidates = baseCandidates(currentParent);

        // Create new candidates by combining parent with current candidate
        for (const parentCandidate of parentCandidates) {
            // Mark as a direct child if it's the immediate parent
            const newCandidate: Candidate = {
                terms: [...parentCandidate.terms, ...candidate.terms],
                topMatch: currentParent,
                score: (candidate.score + parentCandidate.score + TERM_PENALTY) / 2, // penalty for additional term
                matchCount: -1,
            };
            if (i === 0) {
                // only the first parent is a direct child
                newCandidate.terms[1] = {...newCandidate.terms[1], directChild: true};
            }
            newCandidate.matchCount = matchCount(newCandidate.terms);

            const selector = candidateToString(newCandidate);
            if (!seenSelectorsToSkip[selector]) {
                seenSelectorsToSkip[selector] = true;
                result.push(newCandidate);
            }

            if (DEBUG) {
                assertCandidateMatches(selector, origElement);
            }
        }
    }

    return result;
}

function printCandidates(candidates: Candidate[]): void {
    // print count and selector, in order of count
    const sortedCandidates = candidates.sort((a, b) => a.matchCount - b.matchCount);
    sortedCandidates.forEach(candidate => {
        const selector = candidateToString(candidate);
        console.log(`[${candidate.matchCount}] ${selector}`);
    });
}

export function generateSelectorList(element: HTMLElement): string[] {
    const iterationCount = 3;
    
    let pool = reduceCandidateCount(baseCandidates(element));
    if (DEBUG) {
        console.log("BASE CANDIDATES:");
        printCandidates(pool);
    }
    const seen: {[id: string]: true} = {};
    pool.forEach(c => {
        const sel = candidateToString(c);
        seen[sel] = true;
    });

    const expandedIds: {[id: string]: true} = {};

    for (let i = 0; i < iterationCount; i++) {
        let nextPool: Candidate[] = [...pool];
        for (const candidate of pool) {
            const id = candidateToString(candidate);
            if (expandedIds[id]) { continue; }
            expandedIds[id] = true;
            const expansions = expandCandidate(candidate, seen, element); // will be unseen
            nextPool.push(...expansions);
        }
        const isFinal = i === iterationCount - 1;
        if (isFinal) {
            nextPool = nextPool.filter(c => c.matchCount <= 100);
        }
        pool = reduceCandidateCount(nextPool);
        if (DEBUG) {
            console.log(`EXPANDED CANDIDATES (iteration ${i + 1}):`);
            printCandidates(pool);
        }
    }
    return pool.map(x => candidateToString(x));
}

function assertCandidateMatches(selector: string, origElement: HTMLElement): void {
    const matches = document.querySelectorAll(selector);
    const found = Array.from(matches).some((el: Element) => el === origElement);
    if (!found) {
        // throw
        throw new Error(`Selector ${selector} does not match the original element.`);
    }
}
